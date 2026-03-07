# PRD: Import System

## Overview

The import system is iidy-hs's mechanism for injecting external data into a YAML preprocessing
pipeline before template resolution. Imports appear under the top-level `$imports` key of any
preprocessed YAML document. Each entry maps a variable name to an import location string. The
system resolves every import location, parses the result into a typed value, and injects it as
an environment variable available to Handlebars expressions and `$defs` throughout the document.

Eleven import types are supported, covering local files, environment variables, git metadata,
random values, file hashing, S3 objects, HTTP endpoints, CloudFormation stack data, and SSM
Parameter Store parameters. A security model distinguishes between trusted local templates and
untrusted remote templates (loaded from S3 or HTTP/HTTPS), blocking local-resource access from
the remote context. Cycle detection prevents infinite recursion in nested imports.

Behavioral parity with the Rust iidy binary is the acceptance standard. Where this document says
"matches Rust oracle," byte-for-byte output equivalence on the same input is the target, with
documented divergences as the only permitted exceptions.

## Technical Context

**Parallelism:** Individual loaders are independent. `$imports` entries are resolved sequentially
in declaration order. Parallel resolution is a permitted optimization but not required.

**Resource limits:** Both HTTP and S3 loaders enforce a 10 MB maximum response body size
(`httpMaxResponseBytes = 10 * 1024 * 1024`), enforced during streaming before the full body is
buffered. HTTP also enforces a 30-second response timeout (`httpTimeoutSeconds = 30`).

**Known divergences from the Rust oracle** (see also `DIVERGENCES.md`):

- **cfn sub-types:** JS does not support legacy dot syntax (`cfn:stackName.key`); this was a
  Rust-only addition and is not ported.

---

## Import Dispatch Architecture

The import system has a layered dispatch architecture with security and credential gates.

### Type Classification (`parseImportType`)

```
parseImportType :: Text -> Text -> Either ImportError ImportType
parseImportType location baseLocation =
  (typeStr, rest) <- parseTypePrefix location
  importType <- classify typeStr    -- "file" -> ImportFile, "env" -> ImportEnv, etc.
  if isRemoteBase baseLocation && isLocalOnly importType
    then Left "Import type <typeStr> is not allowed from remote templates"
    else Right importType
```

`parseTypePrefix` rules:
- Locations starting with `./`, `../`, `/` are always classified as `file` (no prefix needed)
- Known prefixes (`file:`, `env:`, `git:`, `random:`, `filehash:`, `filehash-base64:`, `cfn:`,
  `ssm:`, `ssm-path:`, `s3:`, `http:`, `https:`) are stripped and return `(prefix, rest)`
- No colon in location: returns `("", location)` which defaults to `ImportFile`
- Unknown prefix: returns `Left "Unknown import type '<prefix>' in <location>"`

### Dispatch and Security Gates (`mkFullDispatcher`)

```
mkFullDispatcher :: ImportConfig -> LoadImportFn
mkFullDispatcher cfg location baseLocation =
  case parseImportType location baseLocation of   -- GATE 1: remote template security
    Left err  -> err
    Right typ -> dispatch cfg typ location baseLocation

dispatch cfg typ location baseLocation = case typ of
  ImportFile          -> loadFileImport location baseLocation
  ImportEnv           -> loadEnvImport location
  ImportGit           -> loadGitImport location baseLocation
  ImportRandom        -> loadRandomImport location
  ImportFilehash      -> loadFilehashImport location baseLocation False
  ImportFilehashBase64-> loadFilehashImport location baseLocation True
  ImportHttp          -> withRemote cfg $          -- GATE 2: --no-remote-imports
                           loadHttpImport location
  ImportS3            -> withRemote cfg $           -- GATE 2: --no-remote-imports
                           withAwsEnv cfg $ \env -> -- GATE 3: AWS credentials
                             loadS3Import env location
  ImportCfn           -> withAwsEnv cfg $ \env ->   -- GATE 3 only (NOT gated by --no-remote-imports)
                           loadCfnImport env location
  ImportSsm           -> withAwsEnv cfg $ \env ->   -- GATE 3 only
                           loadSsmImport env location
  ImportSsmPath       -> withAwsEnv cfg $ \env ->   -- GATE 3 only
                           loadSsmPathImport env location
```

Three security gates:
1. **Remote template gate** (`parseImportType`): blocks local-only imports from remote base locations
2. **`--no-remote-imports` gate** (`withRemote`): blocks HTTP and S3 when `BlockRemoteImports` is set.
   CFN, SSM, and SSM-path are NOT blocked because they use IAM-authenticated AWS SDK calls, not
   open HTTP fetches.
3. **AWS credentials gate** (`withAwsEnv`): blocks CFN, SSM, SSM-path, and S3 when no AWS environment
   is configured. Error: `"AWS import type requires credentials and is not available in this context"`

### Content Parsing Pipeline

Four parsing modes exist, dispatched by loader type:

| Parsing Mode                 | Used By            | Behavior on Parse Failure |
|------------------------------|--------------------|---------------------------|
| `parseByExtensionStrict`     | file, S3, HTTP     | Returns `ImportError`     |
| `parseByFormatSuffix`        | SSM single         | Returns `ImportError`     |
| `parseByFormatSuffixLenient` | SSM-path           | Falls back to `String`    |
| No parsing                   | env, git, random   | Always returns `String`   |

**Extension-strict parsing** (`parseByExtensionStrict`):
```
parseByExtensionStrict ext content rawBytes =
  case ext of
    ".yaml" | ".yml" -> parseYaml content  -- Left ImportError on failure
    ".json"          -> parseJson rawBytes -- Left ImportError on failure
    _                -> Right (String content)
```

**Format-suffix parsing** (`parseByFormatSuffix` / `parseByFormatSuffixLenient`):
```
parseByFormatSuffix suffix val =
  case suffix of
    Nothing     -> Right (String val)
    Just "json" -> parseJson val   -- Left ImportError on failure
    Just "yaml" -> parseYaml val   -- Left ImportError on failure
    Just _      -> Right (String val)  -- unknown suffix treated as no format

parseByFormatSuffixLenient suffix val =
  case suffix of
    Nothing     -> String val
    Just "json" -> fromRight (String val) (parseJson val)   -- falls back to String
    Just "yaml" -> fromRight (String val) (parseYaml val)   -- falls back to String
    Just _      -> String val
```

### Circular Import Detection Algorithm

```
data ImportStack = ImportStack
  { isActive :: Set Text      -- O(log n) membership test
  , isChain  :: [Text]        -- display chain in resolution order
  }

pushImport :: Text -> ImportStack -> Either Text ImportStack
pushImport loc stack
  | loc `member` isActive stack =
      Left $ "Circular import detected: "
          <> intercalate " -> " (reverse (loc : isChain stack))
  | otherwise =
      Right $ ImportStack
        { isActive = insert loc (isActive stack)
        , isChain  = loc : isChain stack
        }

popImport :: ImportStack -> ImportStack
popImport stack = case isChain stack of
  []          -> stack
  (loc : rest) -> ImportStack
    { isActive = delete loc (isActive stack)
    , isChain  = rest
    }
```

The stack is push-on-enter, pop-on-exit (call-stack semantics). Diamond patterns (A imports B and
C, both of which import D) are NOT cycles because D is popped after each child completes.

### $defs + $imports Merge Semantics

Processing order within a document:
1. `$defs` is fully resolved first (all defs available to all imports)
2. `$imports` entries are resolved sequentially in declaration order
3. Each resolved import is added to the environment before the next import's location is interpolated
4. When an imported document contains `$imports` or `$defs`, it is recursively preprocessed with
   its own environment. Custom resource templates registered inside the imported document are NOT
   exported to the parent.

### Import Manifest

Every successfully resolved import produces an `ImportRecord`:
```
data ImportRecord = ImportRecord
  { irKey         :: Maybe Text   -- variable name (Nothing for anonymous)
  , irFrom        :: Text         -- base location (the importing document's path)
  , irImported    :: Text         -- resolved location of the imported document
  , irSha256Digest :: Text        -- SHA256 of raw imported text content
  }
```
Records accumulate in declaration order in the `ImportManifest` for audit/tracing.

---

## User Stories

---

### US-03-001: Import local files

**As a** Developer or Platform Engineer, **I want to** load YAML, JSON, or plain-text files
from the local filesystem into my template's variable environment, **so that** I can share
configuration across multiple stacks without duplicating values.

**Acceptance Criteria:**

- A bare path with no type prefix (e.g., `./vpc-outputs.yaml`, `shared/constants.yaml`) is
  treated as an implicit `file:` import.
- The explicit `file:` prefix (e.g., `file:path/to/file.yaml`) is accepted and behaves
  identically to the bare form.
- Paths beginning with `./`, `../`, or `/` are always classified as `file:` imports, even
  without the prefix (enforced in `parseTypePrefix`).
- Relative paths are resolved against the directory of the importing document's base location.
  For a document at `/home/user/configs/main.yaml`, `./shared.yaml` resolves to
  `/home/user/configs/shared.yaml`.
- Absolute paths (starting with `/`) bypass the base directory and are used as-is.
- Files with `.yaml` or `.yml` extensions are parsed as YAML and injected as a structured value.
- Files with `.json` extension are parsed as JSON and injected as a structured value.
- Files with any other extension are injected as a raw UTF-8 string.
- YAML or JSON parse failure is an error (strict parsing via `parseByExtensionStrict`). There is
  no fallback to raw string on parse failure.
- A file that cannot be read (missing, permission denied) halts preprocessing with a clear
  message: `Failed to read file: <IOError>`.
- Non-UTF-8 file content halts preprocessing: `Invalid UTF-8 in file: <error>`.
- This import type is forbidden from remote templates (see US-03-010).

**Logic Flow:**

```
loadFileImport location baseLocation =
  rawPath   = stripPrefix "file:" location
  basePath  = stripPrefix "file:" baseLocation
  baseDir   = takeDirectory basePath
  fullPath  = if isAbsolute rawPath then rawPath
              else baseDir </> rawPath
  bytes     <- readFile fullPath         -- IOException -> "Failed to read file: ..."
  content   <- decodeUtf8 bytes          -- failure -> "Invalid UTF-8 in file: ..."
  ext       = takeExtension fullPath
  doc       <- parseByExtensionStrict ext content bytes
  return ImportData { idType=ImportFile, idLocation=fullPath, idRawData=content, idDoc=doc }
```

**Edge Cases:**

- Empty base location (`""`) makes `takeDirectory ""` return `"."`, so relative paths resolve
  from the current working directory.
- A location like `file:` with no path after the prefix results in an attempt to open the empty
  string, which fails with an IOError.
- A path that is neither a recognized YAML/JSON extension nor plain text (e.g., `.zip`) is
  returned as a raw string, not an error.
- YAML documents that parse successfully but contain no content (empty file) inject a Null value.

**Error Scenarios:**

- File not found: `Failed to read file: <path>: openFile: does not exist (No such file or directory)`
- UTF-8 violation: `Invalid UTF-8 in file: Cannot decode byte ...`
- YAML parse failure: `Failed to parse YAML: <error>`
- JSON parse failure: `Failed to parse JSON: <error>`
- Security violation from remote template: `Import type file is not allowed from remote templates`

**Complexity Notes:** Low. Pure filesystem I/O with no AWS dependencies.

---

### US-03-002: Import environment variables

**As a** CI Pipeline or Developer, **I want to** read environment variables into my template
variables, **so that** I can pass secrets, configuration, and deployment parameters from the
calling environment without hardcoding them.

**Acceptance Criteria:**

- Syntax: `env:VAR_NAME` or `env:VAR_NAME:default-value`.
- The variable name is everything between `env:` and the first subsequent colon (or end of
  string).
- The default value is everything after the second colon, including any colons within it. This
  allows defaults like `postgres://localhost:5432/myapp`.
- If the variable is set in the environment, its value is used regardless of any default.
- If the variable is unset and a default is provided, the default text is used.
- If the variable is unset and no default is provided, preprocessing fails with:
  `Environment variable not found: <VAR_NAME>`.
- The result is always a string (never auto-parsed as YAML or JSON).
- This import type is forbidden from remote templates (see US-03-010).

**Logic Flow:**

```
loadEnvImport location =
  stripped   = stripPrefix "env:" location
  (varName, defaultVal) = breakOn ":" stripped
    -- breakOn ":" "FOO:bar" -> ("FOO", Just "bar")
    -- breakOn ":" "FOO"     -> ("FOO", Nothing)
  envVal <- lookupEnv varName
  case (envVal, defaultVal) of
    (Just val, _)       -> return String val
    (Nothing, Just def) -> return String def
    (Nothing, Nothing)  -> error "Environment variable not found: <varName>"
```

**Edge Cases:**

- `env:MY_VAR:` (colon but no default text) gives a default of `""` (empty string), not
  "no default". The variable is absent + empty default -> returns empty string.
- Variable names with no alphabetic content (e.g., `env:123`) are passed as-is to `lookupEnv`;
  whether they exist is platform-dependent.
- An environment variable set to an empty string is considered "set"; no default is used.

**Error Scenarios:**

- Unset variable with no default: `Environment variable not found: MY_VAR`
- Security violation from remote template: `Import type env is not allowed from remote templates`

**Complexity Notes:** Low. Pure `lookupEnv` with no IO beyond environment inspection.

---

### US-03-003: Import git metadata

**As a** Developer or CI Pipeline, **I want to** embed the current git branch, commit SHA, or
describe tag into my template, **so that** deployed stacks are annotated with the exact revision
they were created from.

**Acceptance Criteria:**

- Syntax: `git:branch`, `git:sha`, or `git:describe`.
- `git:branch` invokes `git rev-parse --abbrev-ref HEAD` and returns trimmed stdout as a string.
- `git:sha` invokes `git rev-parse HEAD` and returns the full 40-character SHA as a string.
- `git:describe` invokes `git describe --always --dirty --tags` and returns trimmed stdout.
- Any git subcommand other than `branch`, `sha`, `describe` fails with:
  `Invalid git command: <cmd>. Expected: branch|describe|sha`.
- If the `git` binary is not found or throws an exception, fails with:
  `Failed to run git for <location>: <exception>`.
- If the git subprocess exits non-zero, fails with:
  `Git command failed (exit <code>) for <location>: <stderr>`.
- Trailing whitespace and newlines are stripped from the subprocess output before use.
- The result is always a string.
- This import type is forbidden from remote templates (see US-03-010).

**Logic Flow:**

```
loadGitImport location _baseLocation =
  cmd = stripPrefix "git:" location
  (prog, args) = case cmd of
    "branch"   -> ("git", ["rev-parse", "--abbrev-ref", "HEAD"])
    "describe" -> ("git", ["describe", "--always", "--dirty", "--tags"])
    "sha"      -> ("git", ["rev-parse", "HEAD"])
    other      -> error "Invalid git command: <other>. Expected: branch|describe|sha"
  (exitCode, stdout, stderr) <- readProcessWithExitCode prog args ""
  case exitCode of
    ExitSuccess     -> return (strip stdout)
    ExitFailure n   -> error "Git command failed (exit <n>) for <location>: <stderr>"
```

**Edge Cases:**

- Detached HEAD: `git:branch` returns `HEAD` (git's literal output for detached state).
- Repo with no commits: `git rev-parse HEAD` exits non-zero; the error propagates.
- Repository not initialized (no `.git`): subprocess fails with a non-zero exit; error propagates.
- Dirty working tree with `git:describe`: the `--dirty` flag causes `-dirty` suffix to appear.

**Error Scenarios:**

- Unknown subcommand: `Invalid git command: tag. Expected: branch|describe|sha`
- Not in a git repo: `Git command failed (exit 128) for git:sha: fatal: not a git repository`
- Binary missing: `Failed to run git for git:branch: <process exception>`

**Complexity Notes:** Low-medium. Subprocess invocation introduces process-management concerns
but the logic is straightforward. The `baseLocation` parameter is accepted but intentionally
unused; git always queries the local repo.

---

### US-03-004: Generate random values

**As a** Developer, **I want to** generate a random name or integer at preprocessing time,
**so that** I can create unique but human-readable identifiers for ephemeral stacks or resources.

**Acceptance Criteria:**

- Syntax: `random:dashed-name`, `random:name`, or `random:int`.
- `random:dashed-name` generates `<adjective>-<noun>` (e.g., `clever-eagle`). Both components
  are drawn independently and uniformly from the built-in word lists (29 adjectives, 29 nouns).
- `random:name` generates `<adjective><noun>` with no separator (e.g., `cleverereagle`).
- `random:int` generates a decimal integer string in the range [1, 999] inclusive.
- Any subtype other than the three above fails with: `Unknown random type: <subtype>`.
- A new value is generated on every preprocessing run. Values are not stable across runs.
- This import type is allowed from remote templates.

**Logic Flow:**

```
loadRandomImport location =
  subtype = stripPrefix "random:" location
  case subtype of
    "dashed-name" -> adj <- randomElement adjectives
                     noun <- randomElement nouns
                     return (adj <> "-" <> noun)
    "name"        -> adj <- randomElement adjectives
                     noun <- randomElement nouns
                     return (adj <> noun)
    "int"         -> n <- randomRIO (1, 999)
                     return (show n)
    other         -> error "Unknown random type: <other>"
```

**Edge Cases:**

- The word lists are fixed at compile time (29 adjectives, 29 nouns). The space has
  29 x 29 = 841 possible dashed-name combinations and 841 possible name combinations.
- `random:int` has 999 possible values. Collisions are probable over many runs.
- Stability: templates relying on random values MUST NOT expect the same value across runs.
  Use `$defs` to materialize a random value once per preprocessing run if the same value must
  appear in multiple places within the same document.

**Error Scenarios:**

- Unknown subtype: `Unknown random type: uuid`

**Complexity Notes:** Low. Pure random IO with no external dependencies.

---

### US-03-005: Import file hashes

**As a** Developer, **I want to** compute a SHA256 hash of a local file or directory and inject
it as a template variable, **so that** I can detect when a deployed artifact has changed and
conditionally trigger updates.

**Acceptance Criteria:**

- `filehash:path/to/file` computes SHA256 of file content and injects the lowercase hex digest.
- `filehash-base64:path/to/file` computes SHA256 and injects the base64-encoded digest.
- Paths are resolved relative to the importing document's directory (same rules as `file:`).
- A path prefixed with `?` (e.g., `filehash:?dist/optional.zip`) allows a missing file without
  error; a missing optional file returns the string `FILE_MISSING`.
- When the path points to a directory, the directory hash algorithm is applied (see below).
- Both types are forbidden from remote templates.
- The Handlebars template helpers `filehash` and `filehashBase64` provide equivalent functionality
  inline (e.g., `{{ filehash "dist/handler.zip" }}`).

**Directory Hashing Algorithm:**

```
computePathHash path =
  if isDirectory path then
    files     <- listFilesRecursive path    -- all files, not directories
    sorted    = sort files                  -- lexicographic sort of full paths
    hexHashes <- map sha256Hex (map readFile sorted)
    combined  = intercalate "," hexHashes   -- comma-separated hex digests
    return (sha256Hex (encodeUtf8 combined))
  else
    return (sha256Hex (readFile path))
```

Steps:
1. Recursively list all files under the directory (not directories themselves)
2. Sort file paths lexicographically
3. SHA256-hash each file's raw bytes individually, producing hex digests
4. Join all hex hashes with commas
5. SHA256-hash the resulting comma-joined string
6. Return the final hash (hex or base64 depending on import type)

**Logic Flow:**

```
loadFilehashImport location baseLocation isBase64 =
  (filePath, allowMissing) = parseFilehashLocation location
    -- "filehash:?path" -> ("path", True)
    -- "filehash:path"  -> ("path", False)
  baseDir      = takeDirectory (stripPrefix "file:" baseLocation)
  resolvedPath = if isAbsolute filePath then filePath else baseDir </> filePath
  if not (exists resolvedPath) then
    if allowMissing then return "FILE_MISSING"
    else error "Invalid location <resolvedPath> for filehash in <baseLocation>"
  else
    hexHash = computePathHash resolvedPath
    if isBase64 then return (base64Encode (hexToBytes hexHash))
    else return hexHash
```

**Error Scenarios:**

- File/dir not found (without `?` prefix): `Invalid location <path> for filehash in <baseLoc>`
- File/dir not found (with `?` prefix): returns `FILE_MISSING` string.
- IO error during hashing: `Failed to hash <path>: <exception>`
- Non-UTF-8 file: hashing operates on raw bytes, not decoded text (no UTF-8 error).

**Complexity Notes:** Medium. Requires streaming SHA256 via a cryptography library, directory
recursive walk with sorting, optional-file handling, and base64 encoding.

---

### US-03-006: Import from S3

**As a** Platform Engineer or CI Pipeline, **I want to** load YAML or JSON configuration from
S3 objects, **so that** I can share common infrastructure parameters across accounts and regions
from a central configuration store.

**Acceptance Criteria:**

- Syntax: `s3://bucket-name/path/to/object.yaml` or `s3://bucket-name/path/to/object.json`.
- The URI is parsed into bucket name and object key. A missing `/` after the bucket name, an
  empty bucket name, or an empty key all produce a parse error.
- Content is fetched from S3 using the current AWS environment.
- The response body is streamed with a 10 MB size limit (`s3MaxResponseBytes`), enforced
  incrementally during streaming. If exceeded, an `S3SizeLimitExceeded` exception is thrown
  before the full body is buffered.
- The response body is decoded as UTF-8. Non-UTF-8 bytes produce an import error.
- Extension-based content parsing applies (strict): `.yaml`/`.yml` -> YAML parse; `.json` ->
  JSON parse; other -> raw string. YAML and JSON parse failures are errors (no fallback).
- S3 fetch exceptions (network, credentials, access denied, object not found) are wrapped in a
  descriptive import error.
- Templates loaded from S3 are considered remote (base location starts with `s3://`) and are
  subject to security restrictions on further imports (see US-03-010).
- Relative imports within an S3-based template inherit the S3 base path. A relative path
  `sibling.yaml` inside `s3://bucket/configs/app.yaml` resolves to
  `s3://bucket/configs/sibling.yaml`.
- This import type is blocked by `--no-remote-imports`.
- This import type requires AWS credentials.

**Logic Flow:**

```
loadS3Import awsEnv location =
  uri              = stripPrefix "s3:" location
  (bucket, key)    <- parseS3Uri uri    -- strips "//" prefix, splits on first "/"
  bytes            <- fetchS3Object awsEnv bucket key  -- streaming with 10 MB limit
  content          <- decodeUtf8 bytes
  ext              = extractExtension key
  doc              <- parseByExtensionStrict ext content bytes
  return ImportData { idType=ImportS3, idLocation=location, ... }
```

**Edge Cases:**

- Object keys containing embedded `/` characters are handled correctly (only the first `/` is
  used to separate bucket from key).
- S3 URIs with no key (e.g., `s3://bucket/`) produce: `S3 URI has empty key: bucket/`.
- S3 URIs with no bucket (e.g., `s3:///key`) produce: `S3 URI has empty bucket name: /key`.
- Objects without a recognized extension are returned as raw text strings.

**Error Scenarios:**

- S3 access denied: `S3 fetch error for //bucket/key: AccessDenied ...`
- Object not found: `S3 fetch error for //bucket/key: NoSuchKey ...`
- Network error: `S3 fetch error for //bucket/key: <exception>`
- Size exceeded: `S3 fetch error for //bucket/key: S3SizeLimitExceeded 10485760`
- Invalid URI (no key): `S3 URI missing key (no '/' after bucket): bucket-name`

**Complexity Notes:** Medium. Requires AWS credentials in scope. Streaming with size limit via
conduit.

---

### US-03-007: Import from HTTP/HTTPS

**As a** Platform Engineer or CI Pipeline, **I want to** fetch YAML or JSON configuration from
HTTP or HTTPS endpoints, **so that** I can load shared configuration from internal APIs or
public registries without placing files on S3.

**Acceptance Criteria:**

- Syntax: `http://host/path` or `https://host/path` with a full URL.
- A GET request is made to the URL. No authentication headers are added automatically.
- A 30-second response timeout is enforced (`httpTimeoutSeconds`).
- A 10 MB maximum response body size is enforced (`httpMaxResponseBytes`), checked incrementally
  during streaming. If exceeded, an `HttpSizeLimitExceeded` exception is thrown before the full
  body is buffered.
- HTTP 2xx responses are accepted; any other status code fails with:
  `HTTP error <status> for <url>`.
- The response body is decoded as UTF-8. Non-UTF-8 bytes produce an import error.
- Content parsing is based on the URL path's file extension (extracted from the path component
  after stripping scheme, host, query string, and fragment). `.yaml`/`.yml` and `.json` trigger
  structured parsing; other extensions yield raw string. YAML and JSON parse failures are errors
  (strict parsing, no fallback to raw string).
- HTTP and HTTPS URLs are treated as the same import type; both are routed to the same loader.
- Templates loaded from HTTP or HTTPS are considered remote and are subject to security
  restrictions on further imports (see US-03-010).
- Relative imports within an HTTP/HTTPS template resolve relative to the parent URL's directory
  component. `sibling.yaml` inside `https://example.com/configs/app.yaml` resolves to
  `https://example.com/configs/sibling.yaml`.
- This import type is blocked by `--no-remote-imports`.

**Logic Flow:**

```
loadHttpImport location =
  mgr              <- newTlsManager
  (status, body)   <- fetchHttpStreaming mgr location
    -- Sets response timeout: httpTimeoutSeconds * 1_000_000 microseconds
    -- Reads chunks via readWithLimit, throws HttpSizeLimitExceeded if > 10 MB
  if status not in [200..299] then
    error "HTTP error <status> for <location>"
  content          <- decodeUtf8 body
  ext              = takeExtension (urlPath location)
    -- urlPath strips scheme + host, query string, and fragment
  doc              <- parseByExtensionStrict ext content body
  return ImportData { idType=ImportHttp, idLocation=location, ... }
```

**Edge Cases:**

- A URL with no path extension (e.g., `https://api.example.com/config`) returns the body as a
  raw string regardless of Content-Type header. iidy-hs does not inspect Content-Type.
- HTTP redirects: the HTTP client follows redirects automatically; the final URL determines the
  effective content.
- HTTPS with an untrusted certificate: the HTTP client uses the system trust store; untrusted
  certificates cause an import error.
- Query strings and fragments are stripped before extension extraction, so
  `https://example.com/file.yaml?v=1#section` correctly detects `.yaml`.

**Error Scenarios:**

- Non-2xx response: `HTTP error 404 for https://example.com/missing.yaml`
- Network failure: `HTTP fetch error for https://example.com/file.yaml: <exception>`
- UTF-8 error: `UTF-8 decode error for https://example.com/file.yaml: <error>`
- Size exceeded: `HTTP fetch error for <url>: HttpSizeLimitExceeded 10485760`
- Timeout: `HTTP fetch error for <url>: <timeout exception>`

**Complexity Notes:** Medium. No AWS dependencies, but network I/O requires exception handling.
Content-Type is ignored in favor of URL extension, which can surprise users with extension-less
API endpoints.

---

### US-03-008: Import CloudFormation stack data

**As a** Platform Engineer or Developer, **I want to** read outputs, parameters, tags,
resources, and exports from existing CloudFormation stacks, **so that** I can wire together
stacks that depend on each other without hardcoding ARNs and resource IDs.

**Acceptance Criteria:**

The following cfn sub-types are supported:

| Syntax                             | Returns                                                     |
|------------------------------------|-------------------------------------------------------------|
| `cfn:output:stackName/OutputKey`   | Single output value                                         |
| `cfn:output:stackName`             | All outputs as a YAML mapping                               |
| `cfn:export:ExportName`            | Named CloudFormation export value                           |
| `cfn:parameter:stackName/Key`      | Single parameter value                                      |
| `cfn:parameter:stackName`          | All parameters as a YAML mapping                            |
| `cfn:tag:stackName/Key`            | Single tag value                                            |
| `cfn:tag:stackName`                | All tags as a YAML mapping                                  |
| `cfn:resource:stackName/LogicalId` | Resource object (LogicalId, PhysicalId, Type, Status)       |
| `cfn:resource:stackName`           | All resources as a mapping keyed by logical ID              |
| `cfn:stack:stackName`              | Entire stack as mapping with `Outputs`, `Parameters`, `Tags`|

- When a specific key is requested and not found, preprocessing fails with a descriptive error.
- When no key is given (all-outputs/parameters/tags/resources forms), a YAML mapping is returned.
- `cfn:resource:` items include `LogicalResourceId`, `PhysicalResourceId`, `ResourceType`, and
  `ResourceStatus` fields.
- `cfn:stack:` returns a top-level mapping with `Outputs`, `Parameters`, and `Tags` keys, each
  being a mapping of key-to-value pairs.
- The stack must exist in the current AWS account and region. A missing stack produces an error.
- AWS credentials must be available. Access denied conditions produce a wrapped error.
- This import type is allowed from remote templates.
- This import type is NOT blocked by `--no-remote-imports` (uses IAM auth, not open HTTP).

**Logic Flow:**

```
parseCfnLocation location =
  stripped = stripPrefix "cfn:" location
  parts   = splitOn ":" stripped
  case parts of
    (fieldStr : rest) | not (null rest) ->
      field       <- parseField fieldStr  -- output|export|parameter|tag|resource|stack
      resolvedLoc = intercalate ":" rest  -- rejoin remaining parts (handles stack names with colons)
      return (field, resolvedLoc)
    _ -> error "Invalid cfn import format. Expected cfn:field:location"

-- Stack/Key splitting (used by output, parameter, tag, resource):
splitStackKey loc = case breakOn "/" loc of
  (stack, "")   -> (stack, Nothing)    -- all values
  (stack, rest) -> (stack, Just rest)  -- single key (after dropping "/")

-- Sub-type dispatch:
loadCfnImport awsEnv location =
  (field, resolvedLoc) <- parseCfnLocation location
  case field of
    CfnOutput    -> withStack: DescribeStacks, extract output(s)
    CfnExport    -> ListExports (non-paginated), find by name
    CfnParameter -> withStack: DescribeStacks, extract parameter(s)
    CfnTag       -> withStack: DescribeStacks, extract tag(s)
    CfnResource  -> DescribeStackResources, extract resource(s)
    CfnStack     -> withStack: DescribeStacks, assemble {Outputs, Parameters, Tags}
```

**Edge Cases:**

- A stack with zero outputs when queried for a specific output: error, not empty string.
- A stack with zero outputs when queried for all outputs (`cfn:output:stackName`): returns
  empty mapping `{}`.
- `cfn:export:` searches globally across all exports in the account/region; the export name must
  be unique (CloudFormation guarantees this).
- Stack name vs. stack ID: both are accepted by `DescribeStacks`; the loader passes the value
  through as-is.

**Error Scenarios:**

- Stack not found: `Stack not found: <stackName>`
- Output key not found: `Output key '<key>' not found in stack: <stackName>`
- Parameter key not found: `Parameter '<key>' not found in stack: <stackName>`
- Tag key not found: `Tag '<key>' not found in stack: <stackName>`
- Resource not found: `Resource '<key>' not found in stack: <stackName>`
- Export not found: `Export '<exportName>' not found`
- Empty stack name: `Empty stack name in: <location>`
- CFN API error: `CFN fetch error for <stack>: <exception>`

**Complexity Notes:** High. Six distinct sub-type dispatch paths with different AWS API calls
(DescribeStacks, ListExports, DescribeStackResources).

---

### US-03-009: Import SSM parameters

**As a** Platform Engineer or Developer, **I want to** read parameters from AWS Systems Manager
Parameter Store, **so that** I can inject secrets, feature flags, and shared configuration into
templates without storing them in source control.

**Acceptance Criteria:**

**Single parameter (`ssm:`):**

- Syntax: `ssm:/parameter/path`, `ssm:/parameter/path:json`, `ssm:/parameter/path:yaml`.
- The parameter name is the full SSM path (e.g., `/myapp/prod/db/password`).
- `SecureString` parameters are always decrypted. `withDecryption = True` is set unconditionally.
- Without a format suffix, the raw string value is returned.
- With `:json` suffix, the value is parsed as JSON and injected as a structured value.
  Parse failure is an error: `Invalid JSON in SSM parameter: <error>`.
- With `:yaml` suffix, the value is parsed as YAML and injected as a structured value.
  Parse failure is an error: `Invalid YAML in SSM parameter: <error>`.
- If the parameter does not exist, the AWS exception propagates as an import error.
- Requires `ssm:GetParameter` permission; SecureString also requires KMS decrypt permission.

**Path prefix (`ssm-path:`):**

- Syntax: `ssm-path:/parameter/prefix`, `ssm-path:/parameter/prefix:json`,
  `ssm-path:/parameter/prefix:yaml`.
- Retrieves all parameters under the given path prefix, recursively.
- Returns a mapping where each key is the parameter name relative to the prefix and each value
  is the parameter's string value (or parsed structured value if `:json`/`:yaml` is appended).
- For `ssm-path:`, format suffix parsing uses **lenient** mode: parse failures fall back to the
  raw string value rather than returning an error.
- Retrieval is recursive (equivalent to `GetParametersByPath` with `Recursive = True`).
- `SecureString` parameters are always decrypted.
- Results are paginated (all pages consumed via conduit).
- Requires `ssm:GetParametersByPath` permission.

**Both types:**

- Allowed from remote templates.
- NOT blocked by `--no-remote-imports` (uses IAM auth, not open HTTP).
- AWS credentials must be available.

**Logic Flow:**

```
-- Format suffix parsing (shared by both):
parseFormatSuffix stripped =
  case breakOnEnd ":" stripped of
    ("", _)                          -> (stripped, Nothing)       -- no colon
    (prefix, "json")                 -> (dropEnd 1 prefix, Just "json")
    (prefix, "yaml")                 -> (dropEnd 1 prefix, Just "yaml")
    _                                -> (stripped, Nothing)       -- colon is part of path

-- Single parameter:
loadSsmImport awsEnv location =
  (paramName, formatSuffix) <- parseSsmLocation location
  val <- GetParameter(paramName, withDecryption=True)
  doc <- parseByFormatSuffix formatSuffix val    -- strict: error on parse failure
  return ImportData { idType=ImportSsm, ... }

-- Path prefix:
loadSsmPathImport awsEnv location =
  (paramPath, formatSuffix) <- parseSsmPathLocation location
  params <- GetParametersByPath(paramPath, recursive=True, withDecryption=True)
    -- paginated: consumes all pages
  obj = buildResultObject paramPath formatSuffix params
    -- For each (name, val):
    --   relKey = stripPathPrefix paramPath name  -- "/app/config/db/host" -> "db/host"
    --   parsedVal = parseByFormatSuffixLenient formatSuffix val  -- lenient: falls back to String
    -- Returns Object mapping
  return ImportData { idType=ImportSsmPath, ... }
```

**Edge Cases:**

- A parameter path with `:json` suffix (e.g., `ssm:/app/config:json`): the suffix is stripped
  before the API call; the returned value is parsed as JSON.
- Empty parameter value: returns empty string (not an error).
- Parameters that contain YAML-like content but are requested without `:yaml` suffix: returned
  as raw string.
- `ssm-path:` with no parameters under the prefix: returns an empty mapping.
- Unknown format suffix (e.g., `:xml`): treated as part of the path, not stripped.

**Error Scenarios:**

- Parameter not found: `SSM fetch error for /my/param: ParameterNotFound ...`
- Access denied: `SSM fetch error for /my/param: AccessDeniedException ...`
- Network error: `SSM fetch error for /my/param: <exception>`
- SSM-path error: `SSM path fetch error for /my/prefix: <exception>`
- Invalid JSON in SSM parameter (strict only): `Invalid JSON in SSM parameter: <error>`
- Invalid YAML in SSM parameter (strict only): `Invalid YAML in SSM parameter: <error>`

**Complexity Notes:** Medium. `ssm-path:` requires paginated GetParametersByPath calls and
relative key trimming. Format suffix handling (`:json`, `:yaml`) requires stripping the suffix
before the API call and parsing the result afterward. Lenient vs strict parsing differs between
single and path modes.

---

### US-03-010: Security model for remote templates

**As a** Developer or Platform Engineer, **I want to** safely include remote templates from S3
or HTTP endpoints without risking local resource exposure, **so that** third-party or shared
templates cannot read my credentials, files, or repository metadata.

**Acceptance Criteria:**

- A base location is classified as remote if it begins with `s3://`, `http://`, or `https://`.
- Five import types are classified as local-only: file, env, git, filehash, filehash-base64.
- When a remote template attempts a local-only import, the error is:
  `Import type <typeStr> is not allowed from remote templates`.
- Paths starting with `./`, `../`, or `/` are unconditionally treated as file imports, even
  without an explicit `file:` prefix. This means a remote template cannot escape the restriction
  using a bare relative path.
- Relative imports from remote templates (bare path, no explicit type prefix, not starting with
  `./`, `../`, or `/`) inherit the parent's base location. The import location is resolved
  relative to the parent's directory in the same scheme (S3 or HTTPS).
- Six remote-safe types are permitted from any context: S3, HTTP/HTTPS, cfn, ssm, ssm-path,
  random.
- Security validation is performed before any loader is called.
- The security model is applied per-import, not per-document. A local template that imports
  a remote template does not transfer its local privileges to the remote template.

**Security classification pseudocode:**

```
isRemoteBase :: Text -> Bool
isRemoteBase loc = isPrefixOf "s3://" loc
               || isPrefixOf "http://" loc
               || isPrefixOf "https://" loc

isLocalOnly :: ImportType -> Bool
isLocalOnly = \case
  ImportFile          -> True
  ImportEnv           -> True
  ImportGit           -> True
  ImportFilehash      -> True
  ImportFilehashBase64 -> True
  _                   -> False
```

**Base Path Resolution:**

| Parent location                          | Base directory used for relative imports     |
|------------------------------------------|----------------------------------------------|
| `/home/user/configs/main.yaml`           | `/home/user/configs/`                        |
| `./configs/app.yaml`                     | `./configs/`                                 |
| `config.yaml` (no directory)             | `` (empty -> current working directory)      |
| `s3://bucket/file.yaml`                  | `s3://bucket/`                               |
| `s3://bucket/configs/app.yaml`           | `s3://bucket/configs/`                       |
| `https://example.com/file.yaml`          | `https://example.com/`                       |
| `https://example.com/configs/app.yaml`   | `https://example.com/configs/`               |

**Edge Cases:**

- A local template that imports a remote template: the remote import executes with the remote
  template's S3 or HTTPS URL as its base location. Any further imports from that remote document
  are subject to remote restrictions.
- A remote template that imports another remote template in a different scheme (S3 importing
  HTTPS) is permitted, as both are remote-safe.
- A remote template with a bare relative import like `database.yaml` (no `./` prefix) inherits
  the parent's remote base and resolves to the same S3 bucket prefix or HTTPS directory.

**Error Scenarios:**

- `env:` from S3 template: `Import type env is not allowed from remote templates`
- `file:./local.yaml` from HTTPS template: `Import type file is not allowed from remote templates`
- `./local.yaml` from S3 template (implicit file): `Import type file is not allowed from remote templates`
- `/absolute/path` from HTTPS template: `Import type file is not allowed from remote templates`

**Complexity Notes:** Medium. The security boundary is a single predicate composition; the
challenge is that `parseTypePrefix` must correctly handle the edge case where `./`, `../`, and
`/` prefixes classify bare paths as `file:` imports before the security check fires.

---

### US-03-011: Cycle detection and nested imports

**As a** Developer, **I want to** receive a clear error when templates form a circular import
chain, **so that** I can identify and fix accidental or malicious self-referential configurations
before they cause infinite loops.

**Acceptance Criteria:**

- Every import resolution call pushes the resolved import location onto an import stack.
- If the resolved location is already in the active set, a cycle is detected.
- The error message includes the full import chain in resolution order:
  `Circular import detected: a.yaml -> b.yaml -> a.yaml`
  (where `->` is U+2192 RIGHTWARDS ARROW).
- The chain is shown with the cycle-closing location repeated at the end for clarity.
- After successful resolution of a nested document, the location is popped from the stack
  to allow the same file to be imported from multiple non-cyclic parents.
- An import manifest (separate from the import stack) accumulates records for all successfully
  resolved imports, for audit/tracing purposes.
- Cycle detection is applied only to document-level recursive imports (i.e., when one template
  loads another template that is itself preprocessed). Scalar imports (env, git, random, SSM,
  CFN single values) do not recurse and are not pushed onto the import stack.

**Logic Flow:**

See "Circular Import Detection Algorithm" in the Import Dispatch Architecture section above.

**Edge Cases:**

- A document that imports itself directly: `a.yaml -> a.yaml`.
- A long chain: `a.yaml -> b.yaml -> c.yaml -> d.yaml -> a.yaml`.
- The same document imported from two different parents (diamond pattern): this is NOT a cycle.
  `a.yaml` importing both `b.yaml` and `c.yaml`, both of which import `d.yaml`, is valid.
  The import stack is a call-stack structure (push on enter, pop on exit), not a global seen set.
- An import that fails before pushing onto the stack does not affect the cycle-detection state.

**Error Scenarios:**

- Direct self-import: `Circular import detected: a.yaml -> a.yaml`
- Indirect cycle: `Circular import detected: a.yaml -> b.yaml -> c.yaml -> a.yaml`

**Complexity Notes:** Low. The import stack uses a `Set` for O(log n) membership testing and a
list for chain display. The diamond pattern works correctly because the stack is restored after
each child document is processed.

---

### US-03-012: Handlebars interpolation in import paths

**As a** Developer, **I want to** use Handlebars `{{ variable }}` expressions inside import
location strings, **so that** I can dynamically construct import paths based on previously
resolved variables without duplicating logic.

**Acceptance Criteria:**

- Import location strings are checked for `{{` before invoking the import loader.
- If `{{` is present, the location string is passed through the Handlebars interpolation engine
  with the current environment (all previously resolved `$defs` and `$imports`) as context.
- If `{{` is absent, the location is used verbatim (no interpolation overhead).
- All standard Handlebars helpers are available during location interpolation (`defaultHelpers`).
- Interpolation failure (undefined variable, syntax error) produces a `PeHandlebarsError` and
  halts preprocessing.
- Interpolation uses the environment as it exists at the point the import is processed. `$defs`
  entries are available (processed first); `$imports` entries are available in declaration order
  (each resolved import is added to the environment before the next import's location is
  interpolated).
- The resolved location (after interpolation) is what is used for import type detection and
  loading. Security model checks apply to the resolved location.

**Logic Flow:**

1. Check the location text for `{{`.
2. If present: build the Handlebars context from the environment, run the interpolation engine
   with all standard helpers available.
3. If absent: use the location verbatim (fast path, no parse overhead).
4. The resolved location string is then used for type detection and loading.

**Edge Cases:**

- A location like `s3://{{ bucket }}/configs/app.yaml` where `bucket` is defined in `$defs`:
  resolves correctly if `bucket` is in scope before the import is processed.
- Forward references within `$imports` are not supported. An import cannot reference a variable
  that is defined by a later `$imports` entry in the same block. Declaration order is
  resolution order.
- `$defs` entries are always available to all `$imports`, regardless of position in the
  document, because `$defs` is fully processed before `$imports` begins.
- A Handlebars expression that resolves to an empty string produces an empty import location,
  which will fail at the loader level with an appropriate error.
- Nested `{{ }}` expressions are processed by the Handlebars engine; the import system does not
  add any special treatment beyond delegating to `interpolate`.

**Error Scenarios:**

- Undefined variable in location: `PeHandlebarsError` wrapping the Handlebars engine error.
- Handlebars syntax error in location: `PeHandlebarsError`.

**Complexity Notes:** Low. The interpolation is a delegation to the existing Handlebars engine.
The short-circuit on absence of `{{` avoids unnecessary parse overhead for the common case of
literal import paths.

---

## Testing Requirements

- **File loader:** test relative path resolution from a document in a subdirectory; test
  absolute path bypass; test `.yaml`, `.json`, and unknown extension parsing; test YAML parse
  failure produces error (not fallback); test JSON parse failure produces error (not fallback);
  test missing file error; test non-UTF-8 file error; test `file:` prefix stripping.
- **Env loader:** test variable present; test variable absent with default; test variable absent
  without default (error); test default value containing colons; test empty-string default;
  test empty-string variable value (not treated as absent).
- **Git loader:** test `branch`, `sha`, `describe` subcommands map to correct `git` invocations;
  test unknown subcommand error; test subprocess failure (non-zero exit); test subprocess
  exception wrapping; test stdout trimming.
- **Random loader:** test `dashed-name` format (adjective-hyphen-noun); test `name` format
  (concatenation); test `int` range [1, 999] inclusive; test unknown subtype error.
- **Filehash loader:** test hex SHA256 for `filehash:`; test base64 SHA256 for
  `filehash-base64:`; test optional-file `?` prefix returns `FILE_MISSING`; test directory
  hashing (recursive walk, sorted, comma-joined hex hashes, re-hashed).
- **S3 loader:** test S3 URI parsing with valid URI, empty bucket, empty key, missing key
  separator; test content routing by extension; test UTF-8 error path; test 10 MB size limit.
- **HTTP loader:** test URL path extraction (including query/fragment stripping); test extension
  detection for YAML/JSON/other; test 2xx acceptance; test non-2xx error; test strict parse
  failure; test UTF-8 error path; test 10 MB size limit; test 30-second timeout.
- **CFN loader:** test all 6 sub-types (output, export, parameter, tag, resource, stack);
  test single-key and all-keys forms; test reference parsing with slash separator; test empty
  stack name; test missing key errors; test that dot separator is rejected. Integration tests
  against mock CFN stubs for found/not-found stack and found/not-found keys.
- **SSM loader:** test SSM prefix stripping; test format suffix parsing (:json, :yaml, none);
  test mock GetParameter success; test mock parameter not found; test that decryption is enabled
  unconditionally; test ssm-path with pagination; test ssm-path lenient parsing (parse failure
  falls back to string); test relative key stripping.
- **Security model:** test each local-only type rejected from each remote base (s3, http,
  https); test each remote-safe type accepted from remote base; test all types accepted from
  local base; test `./path` classified as file import from remote; test `../path` classified
  as file import from remote; test `/abs` classified as file import from remote.
- **`--no-remote-imports`:** test that HTTP and S3 are blocked; test that CFN, SSM, SSM-path
  are NOT blocked; test error message: `"Remote imports are disabled (--no-remote-imports)"`.
- **AWS credentials gate:** test that CFN, SSM, SSM-path, S3 fail without credentials; test
  error message: `"AWS import type requires credentials and is not available in this context"`.
- **Cycle detection:** test direct self-import cycle; test two-node cycle; test three-node
  cycle with correct chain display; test diamond pattern (not a cycle); test that stack is
  restored after child document processing.
- **Handlebars interpolation:** test literal path skips interpolation; test `{{ var }}`
  resolved from `$defs`; test `$imports` forward reference fails; test Handlebars error
  propagates correctly.
- **Import manifest:** test record ordering; test empty manifest; test SHA256 digest computed
  from raw text content.
- **Engine integration:** test `$defs` fully available to `$imports`; test `$imports` entries
  resolved in declaration order; test environment accumulation across multiple imports; test
  error propagation from loader through engine; test recursive preprocessing of imported
  documents; test custom resource templates not exported from imported documents.
- **Content parsing:** test `parseByExtensionStrict` for .yaml, .yml, .json, .txt; test
  `parseByFormatSuffix` strict error on invalid JSON/YAML; test `parseByFormatSuffixLenient`
  fallback to String on invalid JSON/YAML.

---

## Cross-References

- `docs/import-types.md` -- user-facing reference for all import type syntax and examples.
- `docs/SECURITY.md` -- full security model with threat analysis.
- `docs/requirements/00-overview.md` -- project-level requirements context.
- `docs/requirements/01-cli-interface.md` -- CLI options that affect import behavior
  (`--environment`, `--profile`, `--assume-role-arn`, `--region`).
- `docs/requirements/02-yaml-preprocessing.md` -- two-phase pipeline, variable scope, and
  Handlebars integration that the import system feeds into.
- `DIVERGENCES.md` -- documented deviations from Rust oracle.
- Rust oracle: `~/src/iidy/target/debug/iidy` (read-only reference binary)
