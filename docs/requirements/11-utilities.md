# PRD: Utility Commands

## Overview

This document specifies requirements for the iidy-hs utility commands: standalone tools
that support the CloudFormation workflow without directly invoking AWS stack operations.
These commands cover template preprocessing (`render`), error documentation (`explain`),
interactive demos (`demo`), project scaffolding (`init-stack-args`), import inspection
(`get-import`), stack migration (`convert-stack-to-iidy`), and shell completion
(`completion`). Two commands — `lint-template` and `estimate-cost` — are thin wrappers
around CloudFormation API calls documented in `05-cfn-operations.md`; they are referenced
here for completeness.

All behavior is byte-for-byte equivalent to the Rust iidy reference implementation unless
explicitly noted in `DIVERGENCES.md`.

## Technical Context

The utility commands cover:

- `render` — YAML preprocessing pipeline exposed as a standalone command; also reused
  internally by `demo` to preprocess the demo script itself.
- `explain` — static error code database lookup; no AWS calls.
- `demo` — structured script executor with typed command format.
- `init-stack-args` — file scaffolding; no AWS calls.
- `get-import` — resolves file and environment imports; AWS-backed imports are rejected
  and the user is directed to use `render` instead. Reuses the same import loader
  infrastructure as the full YAML preprocessing pipeline.
- `convert-stack-to-iidy` — AWS-backed conversion using `GetTemplate`, `DescribeStacks`,
  and `GetStackPolicy`.
- `completion` — shell completion script generation via the CLI parser's built-in protocol.

---

## User Stories

### US-11-001: Render preprocessed templates

**As a** Developer or CI Pipeline, **I want to** preprocess an iidy YAML template and
emit the result as JSON, YAML, or CloudFormation-flavored YAML, **so that** I can
inspect the final template before deployment, pipe it into other tools, or write it to
disk for archiving.

**Acceptance Criteria:**

- Input may be a file path or the literal string `"-"` (read from stdin).
- YAML spec selection follows this priority order:
  1. `--yaml-spec 1.1` forces YAML 1.1 compatibility mode.
  2. `--yaml-spec 1.2` forces YAML 1.2 strict mode.
  3. `--yaml-spec auto` (default) auto-detects from the source text; if YAML 1.1
     is detected, compatibility mode is used; otherwise YAML 1.2 strict mode.
- The full iidy preprocessing pipeline runs: `$imports`, `$defs`, `!$` tags, Handlebars
  interpolation, custom resource expansion.
- If `--query` is provided, the JMESPath expression is applied to the preprocessed
  output. A failed or invalid query prints `"Invalid JMESPath query: <query>"` to
  stderr and returns exit code 1.
- Output format is controlled by `--format` (case-insensitive):
  - `json`: pretty-printed JSON.
  - `yaml` or `yml`: custom YAML emitter that preserves key insertion order.
  - `yaml-cloudformation`: identical to `yaml` for the render command (the distinction
    matters to downstream tools, not to `render` itself).
  - Any other value: prints `"Unsupported format: <value>. Use 'yaml' or 'json'"` to
    stderr and returns exit code 1.
- Output destination is controlled by `--outfile` (default `"-"`):
  - `"-"` or `"stdout"`: write to stdout.
  - Any other value: write to the named file.
- Overwrite protection: if the output file already exists and `--overwrite` is not set,
  print `"Output file '<path>' exists. Use --overwrite to overwrite it."` to stderr and
  return exit code 1.
- On successful file write, print `"Template rendered to: <path>"` to stderr.
- Parse errors are formatted with enhanced context and written to stderr; exit code 1.
- Preprocessing errors are formatted with enhanced context and written to stderr; exit
  code 1.
- Exit code 0 on success, 1 on any error.

**Logic Flow:**

```
runRender emit args gopts:
  -- Step 1: Read input
  (content, baseLocation) = if args.template == "-"
                            then (stdin, "-")
                            else (readFile args.template, args.template)
  source = decodeUtf8 content

  -- Step 2: Parse YAML
  ast <- parseYaml content baseLocation
    | Left (ParseError pos msg) -> formatParseErrorEnhanced -> stderr, exit 1

  -- Step 3: Select YAML spec and preprocess
  useYaml11 = case args.yamlSpec of
    YamlV11 -> True
    YamlV12 -> False
    YamlAuto -> shouldUseYaml11Compatibility (detectYamlSpec source)
  preprocess = if useYaml11 then preprocessYaml11 else preprocessYaml
  val <- preprocess dispatcher ast args.template
    | Left err -> formatPreprocessErrorEnhanced -> stderr, exit 1
    | Right (PreprocessResult val _manifest) -> val

  -- Step 4: Apply JMESPath query (optional)
  outputVal = case args.query of
    Nothing -> val
    Just q  -> applyJmesPath q (toValue val)
      | Left err -> formatJMESPathQueryError -> stderr, exit 1
      | Right filtered -> fromValue filtered

  -- Step 5: Format output
  rendered = case args.format of
    RenderJson    -> encodePretty (toValue outputVal)    -- pretty JSON
    RenderYaml    -> emitYaml outputVal                  -- custom YAML emitter
    RenderCfnYaml -> emitYaml outputVal                  -- same as yaml for render

  -- Step 6: Write output
  if isStdoutTarget args.outfile   -- "-" or "stdout"
    then emit (OdRawOutput (rendered <> "\n"))
    else
      if fileExists args.outfile && not args.overwrite
        then stderr "Output file '<path>' exists. Use --overwrite to overwrite it.", exit 1
        else writeFile args.outfile rendered, exit 0
```

**Edge Cases:**

- Empty YAML file: parses as `Null`; preprocessing succeeds and emits `null` or `{}`.
- Stdin input with `"-"`: reads from stdin; `baseLocation` is set to `"-"` for error
  position display.
- JMESPath query that matches but returns `null`: treated as a successful result; emits
  `null`.
- `--query` with a syntactically invalid expression: the JMESPath evaluator returns an
  error; the query string is included in the error message verbatim.
- Output file path containing directory components: the directory must exist; no
  auto-creation is performed.

**Error Scenarios:**

- File not found: the file read raises an IO exception; this propagates uncaught
  (the shell reports it as an unhandled exception).
- Format flag typo (e.g., `--format yml2`): `"Unsupported format: yml2. Use 'yaml' or 'json'"` to stderr, exit 1.
- Overwrite guard: `"Output file 'out.yaml' exists. Use --overwrite to overwrite it."` to stderr, exit 1.

**Complexity Notes:**

The custom pipeline preserves YAML mapping key insertion order through the full
preprocessing and emission cycle. Applying a JMESPath query discards insertion order;
downstream emission then falls back to alphabetical order for any node touched by the
query.

---

### US-11-002: Explain error codes

**As a** Developer or Reviewer, **I want to** look up the meaning of an iidy error code
by number or full name, **so that** I can quickly understand what went wrong and how to
fix it without consulting external documentation.

**Acceptance Criteria:**

- Accepts one or more codes as positional arguments: `iidy explain ERR_2001 3006 err_1003`.
- Each code is normalised to `ERR_NNNN` form:
  1. Upper-case the input.
  2. Strip a leading `ERR_` prefix if present (leaving just the digits).
  3. Left-pad the digit string to 4 characters with `'0'`.
  4. Prepend `"ERR_"`.
- For each known code, print to stdout in order:
  ```
  Error ERR_NNNN
  Category: <category>
  Description: <one-line description>

  <multi-line details paragraph>
  ```
- For each unknown code: print `"Unknown error code: <raw input>"` to stderr; continue
  processing remaining codes.
- With no arguments: print `"Usage: iidy explain <CODE>..."` to stderr and return.
- Multiple codes are processed left-to-right; known codes write to stdout, unknown codes
  to stderr. Output is interleaved in argument order.
- Covered error families:
  - `ERR_1xxx`: YAML Syntax & Parsing (ERR_1001–ERR_1005)
  - `ERR_2xxx`: Variable & Scope (ERR_2001–ERR_2006)
  - `ERR_3xxx`: Import & Loading (ERR_3001–ERR_3010)
  - `ERR_4xxx`: Tag Syntax & Structure (ERR_4001–ERR_4005)
  - `ERR_5xxx`: Type & Validation (ERR_5001–ERR_5006)
  - `ERR_6xxx`: Template & Handlebars (ERR_6001–ERR_6005)
  - `ERR_7xxx`: CloudFormation Specific (ERR_7001–ERR_7004)
  - `ERR_8xxx`: Configuration & Setup (ERR_8001–ERR_8005)
  - `ERR_9xxx`: Internal & System (ERR_9001–ERR_9005)

**Logic Flow:**

```
args = []   → print "Usage: iidy explain <CODE>..." to stderr
args = codes → for each code:
  normalise: upper → strip "ERR_" → pad to 4 digits → prepend "ERR_"
  lookup in error database
    found    → print to stdout (code, category, description, blank line, details)
    not found → print "Unknown error code: <raw>" to stderr
```

**Edge Cases:**

- Input `"2001"`: normalised to `"ERR_2001"` (pad single digit group to 4).
- Input `"01"`: normalised to `"ERR_0001"`.
- Input `"ERR_2001"`: strips prefix, pads `"2001"` to 4 digits, becomes `"ERR_2001"`.
- Input `"err_2001"`: upper-cased to `"ERR_2001"`, then processed normally.
- Code in a gap (e.g., `ERR_2007`): no match in `allErrors`; unknown error output.

**Error Scenarios:**

- Unknown code: message to stderr, processing continues; overall exit code is still 0.
- No arguments: usage line to stderr only; no output to stdout.

**Complexity Notes:**

The error database is a static list compiled into the binary. Lookups are O(n) linear
scan; with ~45 entries this is negligible. The normalisation function handles arbitrary
leading zeros and mixed case without branching on length (left-padding is a no-op when
the string is already 4+ characters).

---

### US-11-003: Run demo scripts

**As a** Developer or Reviewer, **I want to** replay a structured demo script that
executes shell commands with simulated typing, **so that** I can record consistent
screencasts or walk through iidy features interactively without manual typing.

**Acceptance Criteria:**

- The demo script is a YAML file preprocessed in YAML 1.1 compatibility mode before execution.
- The top-level document must be a mapping with a `files` key (optional, mapping of
  relative path to content) and a `demo` key (required, sequence of commands).
- Absolute paths and `..` components in `files` keys are rejected with an IO error.
- File contents are unpacked into a temporary directory (`<tmpdir>/iidy-demo/`) before
  any commands run. The directory is removed via a cleanup bracket regardless of success
  or failure.
- The `IIDY_EXE` environment variable is set to the current executable path when the
  binary on `PATH` named `iidy` is absent or points to a different file.
- The `PKG_SKIP_EXECPATH_PATCH` environment variable is set to `"yes"` to suppress
  nix wrapper path patching.
- Command types (parsed from the `demo` sequence):
  - **String value**: shell command (`DemoShell`). Printed character-by-character with a
    50 ms/char delay (scaled by `timescaling`), prefixed with `"\ESC[31mShell Prompt >\ESC[0m "`.
    Then executed via `/usr/bin/env bash -c`.
  - `{silent: "<cmd>"}`: executes without printing the command (`DemoSilent`).
  - `{sleep: <N>}`: sleeps `N * timescaling` seconds (`DemoSleep`).
  - `{banner: "<text>"}`: displays text in a bold-yellow-on-dark-grey 80-column banner
    (`DemoBanner`). Multi-line text is split on `\n`.
  - `{setenv: {KEY: VALUE, ...}}`: merges new variables into the current environment
    for subsequent commands (`DemoSetEnv`).
- When `maskSecrets` is true, all stdout and stderr output from shell commands is
  filtered to replace 12-digit AWS account numbers (`\b[0-9]{12}\b`) with
  `"************"` using POSIX regex.
- `iidy` at command-start positions (after `|`, `;`, `&`, `(`, `{`) is substituted with
  the actual executable path when `IIDY_EXE` is set.
- Exit code 0 on success; exit code 1 on YAML parse error, preprocessing error, or
  script structure error.
- Failed shell commands raise an IO error (the demo aborts).

**Logic Flow:**

```
runDemo scriptPath timescaling maskSecrets remoteImports:
  content <- readFile scriptPath

  -- Parse and preprocess in YAML 1.1 mode
  ast <- parseYaml content scriptPath
    | Left (ParseError pos msg) -> formatParseErrorEnhanced -> stderr, exit 1
  oval <- preprocessYaml11 dispatcher ast scriptPath
    | Left err -> formatPreprocessErrorEnhanced -> stderr, exit 1
  processed = toValue oval

  -- Parse demo script structure
  (files, commands) <- parseDemoScript processed
    | Left err -> "Failed to parse demo script: " <> err -> stderr, exit 1

  -- Execute with temporary directory
  bracket (createDir tmpDir/iidy-demo) (removeDir) $ \demoDir ->
    unpackFiles files demoDir   -- validate: no absolute paths, no ".." components
    iidyExe <- getIidyExe       -- compare current exe with PATH iidy
    envMap  <- getEnvironment + { PKG_SKIP_EXECPATH_PATCH = "yes" }
    if iidyExe then envMap += { IIDY_EXE = exePath }
    for each command in commands:
      case command of
        DemoShell cmd ->
          substituted = substituteIidyCommand cmd iidyExe
            -- regex: (^|[|;&({])( *)(iidy)\b -> replace "iidy" with exe path
          printCommand substituted timescaling
            -- char-by-char with 50ms * timescaling delay
            -- prefix: "\ESC[31mShell Prompt >\ESC[0m "
          execShell substituted demoDir envMap maskSecrets
        DemoSilent cmd ->
          substituted = substituteIidyCommand cmd iidyExe
          execShell substituted demoDir envMap maskSecrets
        DemoSleep secs ->
          threadDelay (secs * timescaling * 1_000_000)
        DemoSetEnv vars ->
          envMap = Map.union vars envMap
        DemoBanner text ->
          displayBanner text
            -- 80-col banner, bold yellow on dark grey (ANSI 256-color 236)
            -- multi-line: split on "\n"
    exit 0

-- Account number masking (when maskSecrets = true):
maskAwsAccountNumbers text:
  regex match "\b[0-9]{12}\b" -> replace with "************"
  recursively process suffix for multiple matches
```

**Command types** (parsed from the `demo` sequence):

```haskell
data DemoCommand
    = DemoShell  Text           -- string value: shell command with typing simulation
    | DemoSilent Text           -- {silent: "<cmd>"}: execute without display
    | DemoSleep  Int            -- {sleep: N}: delay N * timescaling seconds
    | DemoSetEnv (Map Text Text) -- {setenv: {K: V}}: merge into environment
    | DemoBanner Text           -- {banner: "<text>"}: display formatted banner
```

**Edge Cases:**

- `timescaling = 0.0`: all delays are rounded to 0 µs (effectively instant).
- Empty `files` map: no files written; `demo` directory still created and cleaned up.
- Empty `demo` sequence: no commands run; exit code 0.
- Banner with embedded `\n`: splits into multiple banner rows.
- `maskSecrets = true` with a non-12-digit number in output: not masked (regex requires
  exactly 12 digits bounded by `\b`).
- `iidy` substitution: only replaces at command boundary positions, not mid-word (e.g.,
  `"iidy-render"` is not substituted).

**Error Scenarios:**

- Script file not found: IO exception propagates uncaught.
- YAML parse error: formatted error to stderr, exit 1.
- Unknown command format in `demo` sequence: `"Failed to parse demo script: unknown demo command format"` to stderr, exit 1.
- Shell command exits non-zero: an IO error is raised, aborting the demo.
- Absolute path in `files`: `ioError "Illegal path <p>. Must be relative."`.
- `..` in `files` path: `ioError "Illegal path <p>. Cannot contain parent directory references."`.

**Complexity Notes:**

The typing simulation flushes stdout after each character and disables line buffering
during the loop to ensure smooth output even when stdout is connected to a terminal. The
masking implementation uses POSIX regex and recursively processes the suffix after each
match to handle multiple account numbers in one output block.

---

### US-11-004: Initialize new iidy project

**As a** Developer, **I want to** scaffold a new iidy project directory with
`stack-args.yaml` and `cfn-template.yaml`, **so that** I have a correctly structured
starting point without having to remember the exact file format.

**Acceptance Criteria:**

- Running `iidy init-stack-args` with no force flags creates both files if they do not
  exist.
- If a file already exists and the relevant force flag is absent, print
  `"<filename> already exists! See help [-h] for overwrite options"` to stderr and
  skip that file. The other file is still processed.
- Force flags:
  - `--force`: overwrite both files unconditionally.
  - `--force-stack-args`: overwrite `stack-args.yaml` only.
  - `--force-cfn-template`: overwrite `cfn-template.yaml` only.
  - `--force` logically ORs with the per-file flags.
- On successful write of a file, print `"<filename> has been created!"` to stderr.
- Exit code is always 0 (the function returns `pure 0` regardless of file existence).
- `stack-args.yaml` content is a commented template covering: `StackName`, `Template`,
  `ApprovedTemplateLocation`, `Region`, `Profile`, `Tags`, `Parameters`, `Capabilities`,
  `NotificationARNs`, `RoleARN`, `TimeoutInMinutes`, `OnFailure`, `StackPolicy`,
  `ResourceTypes`, `CommandsBefore`.
- `cfn-template.yaml` content is a minimal valid CloudFormation template:
  a single `WaitConditionHandle` resource named `Dummy`.

**Logic Flow:**

```
forceStackArgs   = --force OR --force-stack-args
forceCfnTemplate = --force OR --force-cfn-template

for each file (stack-args.yaml, cfn-template.yaml):
  if file exists AND not forced:
    print "<filename> already exists! See help [-h] for overwrite options" to stderr
  else:
    write file content
    print "<filename> has been created!" to stderr
return exit 0
```

**Edge Cases:**

- Both files already exist with no force flags: both skip messages to stderr, exit 0.
- `--force-stack-args` with existing `cfn-template.yaml` and no `--force`: overwrites
  only `stack-args.yaml`; `cfn-template.yaml` emits "already exists" message.
- Files are written to the current working directory; no path argument is accepted.

**Error Scenarios:**

- Write permission denied on the current directory: IO exception propagates uncaught.
- Existing file is a directory: `doesFileExist` returns `False`; write attempt will fail
  with an IO exception.

**Complexity Notes:**

The generated `stack-args.yaml` includes inline comments explaining every field. This
serves as embedded documentation and the content must not be modified without also
updating the Rust reference.

---

### US-11-005: Resolve and inspect imports

**As a** Developer or Platform Engineer, **I want to** resolve a single import location
and inspect its contents, **so that** I can verify that file paths, environment
variables, and other import sources resolve correctly before embedding them in templates.

**Acceptance Criteria:**

- Accepts a single import location string as a positional argument (e.g.,
  `"./params.yaml"`, `"env:DEPLOY_ENV"`, `"s3://bucket/key"`).
- The import type is determined from the location string prefix/scheme.
- Supported import types that load successfully:
  - File imports: loaded from local filesystem relative to the current working directory.
  - Environment variable imports: loaded from the process environment.
- AWS-backed import types (S3, SSM, CloudFormation, Git, etc.) return an error:
  `"Import type '<type>' requires AWS credentials. Use the full render command for AWS-backed imports."` to stderr, exit 1.
- Parse failure returns `"Import error: <message>"` to stderr, exit 1.
- Load failure returns `"Import error: <message>"` to stderr, exit 1.
- Output format is controlled by `--format` (case-insensitive):
  - `"json"`: compact JSON, newline-terminated, to stdout.
  - `"yaml"`: YAML serialization to stdout.
  - `"yaml-cloudformation"`: same as `yaml` for get-import.
  - The `RenderFormat` enum has no `Raw` variant; these three are the only options.
- Optional `--query` JMESPath expression: currently not applied (the flag is parsed but
  not applied). This is a known gap; behavior matches Rust.
- Exit code 0 on success, 1 on any error.

**Logic Flow:**

```
runGetImport emit args gopts:
  location     = args.import
  baseLocation = "."          -- always CWD, not relative to a template file
  dispatcher   = mkFullDispatcher importCfg

  result <- dispatcher location baseLocation
  case result of
    Left (ImportError err) ->
      stderr "Import error: " <> err
      exit 1
    Right importData ->
      doc = importData.doc    -- Aeson Value
      case args.format of
        RenderJson    -> emit (OdRawOutput (Aeson.encode doc <> "\n"))
        RenderYaml    -> emit (OdRawOutput (emitYaml (fromValue doc)))
        RenderCfnYaml -> emit (OdRawOutput (emitYaml (fromValue doc)))
      exit 0
```

**NOTE:** The `RenderFormat` enum has three variants (`RenderJson | RenderYaml |
RenderCfnYaml`). There is no `Raw` variant. The `--format` flag defaults to one
of these three values; the "raw" format described in some documentation is not
a separate code path in the current implementation. `RenderCfnYaml` behaves
identically to `RenderYaml` for get-import.

**Edge Cases:**

- `ImportEnv` with an unset variable: `loadEnvImport` returns a `Left ImportError`;
  message printed to stderr, exit 1.
- `ImportFile` with a missing file: `loadFileImport` returns a `Left ImportError`; same.
- Import location that is a bare filename with no scheme: `parseImportType` treats it as
  a relative file path (`ImportFile`).

**Error Scenarios:**

- AWS import type: deterministic error message referencing `render` command.
- Unknown import scheme: `parseImportType` returns `Left`; message to stderr, exit 1.
- JSON output of non-object YAML (e.g., a scalar): `Aeson.encode` emits the JSON scalar
  representation.

**Complexity Notes:**

The base location is always the current working directory (`"."`), because `get-import`
is not invoked in the context of a template file. This differs from the preprocessing
pipeline where the base location tracks the importing file's directory.

---

### US-11-006: Convert existing stacks to iidy format

**As a** Platform Engineer, **I want to** generate an iidy project directory from an
existing CloudFormation stack, **so that** I can bring stacks that were created outside
iidy under iidy management without rewriting the template from scratch.

**Acceptance Criteria:**

- Positional arguments: `<stackname>` and `<output-dir>`.
- AWS API calls performed (in order):
  1. `GetTemplate` to fetch the stack's current template body.
  2. `DescribeStacks` to fetch parameters, tags, capabilities, timeout, termination
     protection, notification ARNs, role ARN, and disable-rollback flag.
  3. `GetStackPolicy` to fetch the stack policy (falls back to `defaultStackPolicy` on
     any exception).
- Output files written to `<output-dir>/` (created if absent):
  - `stack-policy.json`: the stack policy, pretty-printed as JSON.
  - `_original-template.json` or `_original-template.yaml`: the raw template body,
    extension chosen by whether the body starts with `"{"`.
  - `cfn-template.yaml`: the template converted to YAML (or kept as YAML if already
    YAML), optionally with CFN-canonical key ordering.
  - `stack-args.yaml`: generated by `buildStackArgsYaml` with all extracted metadata.
- `--sortkeys` (default true) / `--no-sortkeys`: controls whether CFN-specific key
  weight functions are applied to `cfn-template.yaml`. Key ordering follows:
  - Document level: `AWSTemplateFormatVersion` → `Description` → `Metadata` →
    `Parameters` → `Mappings` → `Conditions` → `Transform` → `Resources` → `Outputs`.
  - Parameter entries: `Description` → `Type` → `MinValue` → `MaxValue` → `MinLength` →
    `MaxLength`.
  - Resource entries: `Type` first, `Properties` last.
  - Output entries: `Description` → `Value` → `Export`.
  - Tag entries: `Key` → `Value`.
  - IAM Statement entries: `Sid` → `Effect` → `Action` → `Resource` → `Condition`.
  - PolicyDocument / AssumeRolePolicyDocument: `Version` → `Statement`.
  - Policies entries: `PolicyName` → `PolicyDocument`.
- `--move-params-to-ssm`: migrates non-Environment parameters to SSM as `SecureString`
  under `/<currentEnv>/<project>/`. Requires a project name (from `--project` or the
  `project` tag). Parameters in `stack-args.yaml` are replaced with `!$ ssmParams.<key>`
  references and a `ssm-path:/{{environment}}/{{project}}/` import is added.
- `--project <name>`: overrides the project name (default: the `project` tag value).
- Stack name parameterisation in `stack-args.yaml`:
  - Known environment strings (`production`, `staging`, `development`, `integration`,
    `testing`) are replaced with `{{environment}}`.
  - Trailing `-<digits>` suffix is replaced with `-{{build_number}}`.
  - Project name occurrences are replaced with `{{project}}`.
- Each file written is announced: `"Wrote <path>"` to stderr.
- On `GetTemplate` or `DescribeStacks` failure: returns `Left "<message>"`.
- Stack not found in `DescribeStacks` response: returns `Left "Stack <name> not found"`.
- Template conversion failure: returns `Left "Failed to convert template: <err>"`.

**Logic Flow:**

```
GetTemplate stackName
  → error: "Failed to get template: ..." → error
  → success:
DescribeStacks stackName
  → error: "Failed to describe stack: ..." → error
  → empty: "Stack <name> not found" → error
  → success (stack):
GetStackPolicy stackName (exception → defaultStackPolicy)
create output directory
write stack-policy.json
write _original-template.<ext>
convert template body to YAML
  → error: "Failed to convert template: ..." → error
  → success: write cfn-template.yaml
extract: tags, project, currentEnv, params, caps, timeout, etc.
if --move-params-to-ssm: migrate parameters to SSM
build and write stack-args.yaml
return exit 0
```

**Edge Cases:**

- JSON template (`templateBody` starts with `"{"`): saved as
  `_original-template.json`; converted to YAML for `cfn-template.yaml`.
- No `project` tag and no `--project`: `project` defaults to `""` (empty string); SSM
  migration requires a non-empty project and prints an error to stderr if triggered.
- No `environment` or `Environment` tag: `currentEnv` defaults to `"development"`.
- Stack policy API failure: silently falls back to `defaultStackPolicy` (allow all
  updates).
- `--no-sortkeys`: keys appear in iteration order of the underlying map (non-deterministic
  across implementations and versions).

**Error Scenarios:**

- Stack not found or in `DELETE_COMPLETE` state: `DescribeStacks` returns empty list;
  error `"Stack <name> not found"`.
- Template conversion failure (malformed JSON/YAML): error `"Failed to convert template: <error>"`.
- `--move-params-to-ssm` without project name: logs error to stderr; processing continues
  without SSM migration.
- SSM `PutParameter` failure during migration: exception is silently swallowed; the
  parameter key is still included in the SSM reference map.

**Complexity Notes:**

The `stack-args.yaml` generator uses a two-pass strategy for SSM parameter references:
first it writes placeholder strings for SSM-migrated keys, then post-processes the YAML
text to substitute `!$ ssmParams.<key>` references. This avoids escaping issues with
YAML custom tags during the structural assembly phase.

---

### US-11-007: Generate shell completion scripts

**As a** Developer, **I want to** install tab-completion for iidy commands and flags in
my shell, **so that** I can complete subcommands and options without consulting the help
text.

**Acceptance Criteria:**

- Subcommand: `iidy completion [SHELL]`.
- Optional `SHELL` argument accepts: `bash`, `zsh`, `fish`, `powershell`.
- Shell auto-detection: if `SHELL` is omitted, inspect the `$SHELL` environment variable
  to determine the shell.
- Completion script generation uses the CLI parser's built-in bash-completion protocol.
  The program name used is `"iidy-hs"`.
- Bash: generates a `_iidy_hs` completion function using `complete -F`.
- Zsh and Fish: the CLI parser library generates bash-compatible completion output for
  all shells. Zsh and fish shells can source the bash completion output directly (zsh via
  `bashcompinit`, fish via `bass` or similar shim). Distinct native zsh (`#compdef`) and
  fish (`complete -c`) generators are not provided by the underlying parser library; the
  shell argument is accepted but the output format does not vary between bash, zsh, and
  fish targets.
- PowerShell: **not supported**. This is a documented divergence from the Rust
  implementation (`DIVERGENCES.md`). Behavior when requested: no error is raised by the
  CLI parser (the `SHELL` argument is accepted), but the completion infrastructure does
  not generate PowerShell output.
- The completion script is printed to stdout.
- Exit code 0 on success.

**Logic Flow:**

```
parse completion command (optional shell name)
case shell of
  absent     → detect from $SHELL environment variable
  present    → use provided shell name
CLI parser's completion infrastructure intercepts --bash-completion-* flags
  → generate script for detected shell
  → print to stdout
  → exit 0
```

**Edge Cases:**

- `$SHELL` is unset or empty: the completion infrastructure defaults to bash completion output.
- `SHELL` argument value `"powershell"`: accepted by the parser but produces bash-format
  output (not a PowerShell-native script).
- All shell arguments (`bash`, `zsh`, `fish`) produce the same bash-format completion
  output; the shell name is accepted but does not change the output format.
- Piping completion script to `source` directly: works as long as stdout is not
  buffered mid-line.

**Error Scenarios:**

- Unknown shell name: the CLI parser does not validate the shell name; output may
  default to bash format.

**Complexity Notes:**

The completion infrastructure is handled by the CLI parser's built-in completion
protocol. The `completion` command branch in the main dispatch is never reached for
normal completion invocations; the parser library intercepts the `--bash-completion-*`
flags directly.

---

## Cross-References

### Commands documented elsewhere

- **lint-template**: Validates a CloudFormation template via the `ValidateTemplate` API.
  Full requirements in `05-cfn-operations.md` (US-05-011, error scenarios section).
  Key behaviors: templates exceeding 51200 bytes emit a warning and skip validation;
  output routed via the `OutputData` emitter pipeline.

- **estimate-cost**: Estimates monthly cost for a stack template via the
  `EstimateTemplateCost` API. Full requirements in `05-cfn-operations.md`
  (US-05-011, error scenarios section). Key behaviors: template load failure returns
  `Left` error; cost URL emitted via `OutputData`.

### Related documents

| Document                   | Relationship                                              |
| -------------------------- | --------------------------------------------------------- |
| `02-yaml-preprocessing.md` | Full preprocessing pipeline used by `render` and `demo`  |
| `03-import-system.md`      | Import loaders used by `render` and `get-import`         |
| `05-cfn-operations.md`     | `lint-template`, `estimate-cost` full specs               |
| `07-error-handling.md`     | Error formatting used by `render` and `demo`              |
| `08-aws-integration.md`    | AWS credential chain used by `convert-stack-to-iidy`     |
| `09-ssm-params.md`         | SSM parameter migration used by `convert-stack-to-iidy`  |
| `DIVERGENCES.md`           | PowerShell completion, `--query` in `get-import`          |

## Testing Requirements

- `render`: unit tests for each format (`json`, `yaml`, `yaml-cloudformation`); YAML
  spec selection (auto, 1.1, 1.2); JMESPath query application; overwrite protection
  (file exists with and without `--overwrite`); stdin input path (`"-"`); invalid format
  string; parse error path; preprocessing error path.
- `explain`: normalisation of all input forms (`ERR_2001`, `err_2001`, `2001`, `01`);
  known code output format (field order, blank line before details); unknown code to
  stderr; empty args usage message; multiple mixed known/unknown codes.
- `demo`: script parsing (all five command types); account number masking (match,
  no-match, multiple matches); iidy command substitution (boundary positions, non-boundary
  not substituted); environment and stack name parameterization (pure functions,
  testable without AWS).
- `init-stack-args`: file absent (both files created); file exists without force (skip
  message); `--force` overwrites both; `--force-stack-args` overwrites only
  `stack-args.yaml`; `--force-cfn-template` overwrites only `cfn-template.yaml`.
- `get-import`: file import success (json/yaml/raw output); env import success; AWS
  import type error message; parse error from bad location string.
- `convert-stack-to-iidy`: pure helpers (environment parameterization, stack name
  parameterization, CFN key sorting, template body conversion, stack-args YAML
  generation) tested without AWS; AWS path tested with mock AWS environment.
- `completion`: CLI parser wiring test confirms the completion command parses correctly
  with and without a shell argument.

All AWS-touching code paths use mock fixtures. No real AWS calls in the test suite.
