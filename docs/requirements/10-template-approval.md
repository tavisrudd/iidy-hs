# PRD: Template Approval Workflow

## Overview

The template approval workflow provides a structured, auditable mechanism for
gating CloudFormation template changes through human review before they are used
in stack deployments. Templates are hashed by content, staged in S3 as `.pending`
objects, reviewed via a diff-and-confirm step, and promoted to approved locations
that the CloudFormation service role may read.

This workflow separates the concerns of template authorship and deployment authority:
developers upload candidates; reviewers (or automation) approve them; the approval
state lives entirely in S3 and is enforced through IAM policy rather than any
application-level gate.

The workflow is accessed via two subcommands of `template-approval`:
- `template-approval request <argsfile>` — preprocesses a template, computes its
  content hash, and uploads it as a `.pending` object to S3.
- `template-approval review <url>` — downloads a `.pending` object, diffs it
  against the previously approved version, and promotes or rejects it.

All output is routed through the standard `OutputDispatch` / `OutputData` pipeline.
Both subcommands emit structured output compatible with `--output-mode json`.

## Implementation Context

- **Primary module**: `src/Iidy/Cfn/Operations/TemplateApproval.hs`
  - `templateApprovalRequest` — request flow
  - `templateApprovalReview` — review flow
- **Hashing + S3 URL utilities**: `src/Iidy/Cfn/TemplateHash.hs`
  - `calculateTemplateHash` — SHA256 of UTF-8 encoded template content, hex string
  - `generateVersionedLocation` — derives `(bucket, key)` from base location + hash
  - `parseS3Url` — parses `s3://bucket/key` into components
- **Template loading**: `src/Iidy/Cfn/TemplateLoader.hs`
  - `loadCfnTemplate` — loads template body from file, S3 URL, HTTP URL, or inline
  - `templateMaxBytes` = 51199 (51 KB inline limit)
- **Stack args schema**: `src/Iidy/Cfn/Types.hs`
  - `StackArgs.saApprovedTemplateLocation` — base S3 URL (required for approval)
  - `StackArgs.saTemplate` — template file path or spec (required for approval)
- **Output types**: `src/Iidy/Output/Types.hs`
  - `OdApprovalRequestResult ApprovalRequestResult`
  - `OdApprovalStatus ApprovalStatus`
  - `OdTemplateDiff TemplateDiff`
  - `OdApprovalResult ApprovalResult`
  - `OdTemplateValidation TemplateValidation` (declared; not yet emitted by request
    flow — reserved for future lint integration)
- **Confirmation**: `src/Iidy/Confirm.hs` — `requestConfirmation`
- **CLI parser**: `src/Iidy/Cli/Parser.hs`
  - `approvalRequestArgsParser` — ARGSFILE positional + `--no-lint-template` flag
  - `approvalReviewArgsParser` — URL positional + `--context LINES` (default 500)
- **S3 operations**: amazonka `HeadObject`, `PutObject`, `GetObject`, `DeleteObject`
  via helpers in `TemplateApproval.hs` (`s3ObjectExists`, `uploadToS3`,
  `downloadFromS3`, `deleteFromS3`)
- **ACL**: `bucket-owner-full-control` is the intended ACL for cross-account safety;
  the current implementation calls `PutObject` without an explicit ACL field (ACL
  support is a known gap; see Testing Requirements)

**Key S3 key naming convention:**

```
<baseKey>/<sha256hex><ext>            -- approved object (no suffix)
<baseKey>/<sha256hex><ext>.pending    -- pending object (awaiting review)
<baseKey>/latest                      -- pointer to current approved content
```

Where `baseKey` is derived from the `ApprovedTemplateLocation` field with trailing
slashes normalized, and `ext` is the file extension of the `Template` field (e.g.
`.yaml`). The `latest` key lives at the parent directory level of the hash-named
objects.

**Diff algorithm**: `generateDiff old new` computes a simple set-difference diff:
lines present in `old` but not `new` are prefixed with `"- "`, lines present in
`new` but not `old` are prefixed with `"+ "`. This is not a unified context diff;
it is order-insensitive. The `--context` flag controls `TemplateDiff.tdContextLines`
(recorded in the output type) but does not currently trim the diff output.

---

## User Stories

### US-10-001: Request template approval

**As a** Developer or CI Pipeline, **I want to** submit a preprocessed CloudFormation
template for reviewer approval, **so that** production deployments are gated on
verified template content and every approved template is traceable to a specific
content hash.

**Acceptance Criteria:**

- `template-approval request <argsfile>` is the invocation form.
- The argsfile must contain both `ApprovedTemplateLocation` (an `s3://bucket/path`
  base URL) and `Template` (a file path, `render:` path, or URL). If either field
  is absent, the command exits with a descriptive error before contacting AWS.
- The template is loaded via `loadCfnTemplate` (full preprocessing pipeline,
  including `render:` prefix YAML engine pass, import resolution, and Handlebars
  interpolation).
- Template loading failure (file not found, YAML parse error, import resolution
  error) is returned as `Left` immediately; no S3 calls are made.
- A SHA256 hash of the fully-processed UTF-8 template content is computed via
  `calculateTemplateHash`.
- The approved S3 key is derived as `<baseKey>/<hash><ext>` (no `.pending` suffix)
  via `generateVersionedLocation`. If the base location is invalid (no bucket, no
  key), an error is returned.
- If an object already exists at the approved key (verified by `HeadObject`), the
  command exits 0 and emits `OdApprovalRequestResult` with `arrAlreadyApproved =
  True`. No upload is performed. `arrNextSteps` contains `"Template has already
  been approved"`.
- If no approved object exists, the template is uploaded to the `.pending` key
  (`approvedKey <> ".pending"`) via `PutObject`. On upload failure the command
  returns `Left ("Failed to upload pending template: " <> awsError)`.
- On successful upload, `OdApprovalRequestResult` is emitted with:
  - `arrTemplateLocation` = `"s3://<bucket>/<approvedKey>"` (the content-addressed
    approved location, without `.pending`)
  - `arrPendingLocation` = `"s3://<bucket>/<approvedKey>.pending"`
  - `arrAlreadyApproved` = `False`
  - `arrNextSteps` = `["Review with: iidy-hs template-approval review " <> pendingLoc]`
- The command returns exit code 0 on success (both already-approved and newly
  uploaded paths). Non-zero exit on validation or upload failure.
- The `--no-lint-template` flag is accepted by the CLI and passed to
  `templateApprovalRequest` as the `lintTmpl` boolean. Lint is not currently
  performed inside this function (the flag is received but no `ValidateTemplate`
  call is made); `OdTemplateValidation` is not emitted. This is a known gap.

**Logic Flow:**

```
validate saApprovedTemplateLocation present
  → absent: Left "ApprovedTemplateLocation is required in stack-args.yaml"
validate saTemplate present
  → absent: Left "Template is required in stack-args.yaml"
loadCfnTemplate saTemplate argsfilePath env
  → trTemplateBody == Nothing: Left "Failed to load template body"
  → Just body:
      generateVersionedLocation baseLocation body templatePath
        → Left err: return Left err
        → Right (bucket, approvedKey):
            s3ObjectExists awsEnv bucket approvedKey
              → True:  emit OdApprovalRequestResult (alreadyApproved=True)
                       return Right 0
              → False:
                  uploadToS3 awsEnv bucket (approvedKey <> ".pending") body
                    → Left err: return Left ("Failed to upload pending template: " <> err)
                    → Right ():
                        emit OdApprovalRequestResult (alreadyApproved=False)
                        return Right 0
```

**Edge Cases:**

- Trailing slashes on `ApprovedTemplateLocation` are normalized by
  `generateVersionedLocation`: `"s3://bucket/templates/"` and
  `"s3://bucket/templates"` both produce `"templates/<hash>.yaml"` as the key.
- The `Template` field may be a bare filename (e.g. `"cfn-template.yaml"`),
  resolved relative to the argsfile directory. It may also be a `render:` prefixed
  path, an `s3://` URL, or an `https://` URL. The extension used in the hash key
  is taken from the `Template` field via `System.FilePath.takeExtension`, not from
  the content type of the loaded body.
- If `Template` is an S3 or HTTP URL, `loadCfnTemplate` returns a
  `TemplateResult` with `trTemplateBody = Nothing` and a URL; `templateApprovalRequest`
  treats `trTemplateBody == Nothing` as a load failure. Templates must be locally
  resolvable for approval requests.
- Parameter changes that do not affect the template body (e.g., changing a
  `Parameters` value in the argsfile) do not change the hash; the same approved
  object applies. This is intentional: approval gates template content, not
  parameter values.

**Error Scenarios:**

- Missing `ApprovedTemplateLocation`: `Left "ApprovedTemplateLocation is required in stack-args.yaml"`, exit 1.
- Missing `Template` field: `Left "Template is required in stack-args.yaml"`, exit 1.
- Template file not found or unreadable: load error propagated as `Left`, exit 1.
- Invalid `ApprovedTemplateLocation` format (no bucket or no key): `Left` from
  `parseS3Url`, exit 1.
- S3 `HeadObject` access denied (no s3:GetObject on approved key): treated as
  object-absent (exception caught and mapped to `False`); upload proceeds. This
  means a developer without read access to the approved prefix will always attempt
  to upload, even if the template is already approved.
- S3 `PutObject` failure (no permission, bucket does not exist, etc.): `Left
  "Failed to upload pending template: <awsErr>"`, exit 1.

**Complexity Notes:**

The function signature is:
```haskell
templateApprovalRequest
  :: CfnContext
  -> StackArgs
  -> Bool           -- ^ lint template (currently unused)
  -> Maybe FilePath -- ^ argsfile path (for template resolution)
  -> Text           -- ^ environment (for preprocessing)
  -> (OutputData -> IO ())
  -> IO (Either Text Int)
```

The `lintTmpl` parameter is structurally wired but no `ValidateTemplate` call is
made. A future implementation would call `Amazonka.send ValidateTemplate` when
`lintTmpl = True` and emit `OdTemplateValidation` with errors and warnings.

**Estimated complexity**: Low. The function is ~45 lines of straight-line IO with
no loops and a single AWS read + optional write.

---

### US-10-002: Review and approve a pending template

**As a** Reviewer or Platform Engineer, **I want to** inspect a pending template
change and either approve or reject it, **so that** I can verify the intended
modification before it becomes available for stack deployments.

**Acceptance Criteria:**

- `template-approval review <url>` is the invocation form. `<url>` must be a valid
  `s3://` URL ending with `.pending`; any other format is rejected before AWS calls.
- The pending S3 key is derived from the URL by parsing bucket and key via
  `parseS3Url`.
- The approved key is derived by stripping the `.pending` suffix (8 characters)
  from the pending key: `approvedKey = T.dropEnd 8 pendingKey`.
- The `latest` key is derived from the approved key's parent directory:
  `latestKey = parentDir <> "/latest"` where `parentDir` is the path component
  before the final `/`. If there is no parent directory, `latestKey = "latest"`.
- `OdApprovalStatus` is emitted before any download, containing:
  - `apsPendingExists`: whether a `HeadObject` on the pending key succeeds
  - `apsAlreadyApproved`: whether a `HeadObject` on the approved key succeeds
  - `apsPendingLocation`: the original `<url>` argument
  - `apsApprovedLocation`: `Just approvedLoc` if already approved, else `Nothing`
- If the pending object does not exist: return `Left ("Pending template not found at " <> url)`.
- If the template is already approved (approved key exists): return `Right 0` after
  emitting `OdApprovalStatus`. No diff or confirmation.
- If the pending object exists and is not yet approved:
  - Download the pending template via `GetObject`.
  - Download the latest approved template via `GetObject`. If `latest` does not
    exist, treat it as empty content (`""`).
  - Compute `OdTemplateDiff` via `generateDiff latest pending`:
    - `tdDiffOutput`: diff text (empty string if no changes)
    - `tdContextLines`: the `--context` argument (default 500)
    - `tdHasChanges`: `not (T.null diffOutput)`
  - Emit `OdTemplateDiff`.
  - If `tdHasChanges = False` (pending content is identical to latest): auto-approve
    without prompting. Emit `OdApprovalResult` with `arApproved = True`,
    `arCleanupCompleted = False`. Return `Right 0`.
  - If `tdHasChanges = True`: call `requestConfirmation "Would you like to approve
    these changes?"`.
    - If confirmed:
      - Upload pending content to approved key via `PutObject`.
      - Upload pending content to latest key via `PutObject`.
      - Delete pending key via `DeleteObject`.
      - Emit `OdApprovalResult` with `arApproved = True`, `arCleanupCompleted = True`,
        `arApprovedLocation = Just approvedLoc`,
        `arLatestLocation = Just ("s3://" <> bucket <> "/" <> latestKey)`.
      - Return `Right 0`.
    - If rejected:
      - Emit `OdApprovalResult` with `arApproved = False`, `arApprovedLocation =
        Nothing`, `arLatestLocation = Nothing`, `arCleanupCompleted = False`.
      - Return `Right 1`.

**Logic Flow:**

```
parseS3Url url
  → Left err: return Left err
validate T.isSuffixOf ".pending" pendingKey
  → False: return Left "URL must end with .pending suffix"
s3ObjectExists awsEnv bucket pendingKey → pendingExists
s3ObjectExists awsEnv bucket approvedKey → alreadyApproved
emit OdApprovalStatus { pendingExists, alreadyApproved, ... }
if not pendingExists:
  return Left ("Pending template not found at " <> url)
if alreadyApproved:
  return Right 0
downloadFromS3 awsEnv bucket pendingKey → pending (default "")
downloadFromS3 awsEnv bucket latestKey  → latest  (default "")
let diffOutput = generateDiff latest pending
    hasChanges = not (T.null diffOutput)
emit OdTemplateDiff { diffOutput, contextLines, hasChanges }
if not hasChanges:
  emit OdApprovalResult { approved=True, cleanupCompleted=False }
  return Right 0
requestConfirmation "Would you like to approve these changes?"
  → True:
      uploadToS3 awsEnv bucket approvedKey pending
      uploadToS3 awsEnv bucket latestKey   pending
      deleteFromS3 awsEnv bucket pendingKey
      emit OdApprovalResult { approved=True, cleanupCompleted=True }
      return Right 0
  → False:
      emit OdApprovalResult { approved=False }
      return Right 1
```

**Edge Cases:**

- The `latest` key download failing (object not found) is silently treated as an
  empty previous template. This is the correct behavior for the first-ever approval
  of a template: there is no prior approved version to diff against.
- S3 download errors other than not-found (e.g., access denied) are also mapped to
  `""` via the `either (const "") id` pattern. This means a reviewer without read
  access to `latest` will see every template as an addition (diff against empty),
  which is misleading. A more robust implementation would surface the error.
- If upload of the approved key succeeds but upload of the latest key fails (partial
  failure), the pending key is not deleted. The approved object exists but `latest`
  is stale. The current implementation does not handle partial failures; upload
  results are discarded with `_ <- uploadToS3`.
- `generateDiff` is set-theoretic: it reports lines removed and lines added
  regardless of position. A line that moved from one location to another in the file
  will appear as both removed and added. For CloudFormation YAML templates this is
  generally acceptable since resource ordering rarely matters.
- The `--context` flag value is stored in `tdContextLines` but does not trim the
  diff; the full diff is always emitted. This is a known gap versus the intended
  behavior of showing a configurable number of context lines around changes.

**Error Scenarios:**

- URL does not start with `s3://`: `Left "Invalid S3 URL (must start with s3://): <url>"`, exit 1.
- URL does not end with `.pending`: `Left "URL must end with .pending suffix"`, exit 1.
- Pending object not found: `Left "Pending template not found at <url>"`, exit 1.
- `HeadObject` or `GetObject` AWS error: exception propagated to top-level handler,
  exit 1.
- User rejects the approval: `OdApprovalResult { arApproved = False }` emitted,
  exit 1 (not 130; rejection is a normal operational outcome, not a cancellation).
- `PutObject` or `DeleteObject` failure during promotion: exception propagated,
  exit 1. Pending object may remain; re-running the review command is safe.

**Complexity Notes:**

The function signature is:
```haskell
templateApprovalReview
  :: CfnContext
  -> Text       -- ^ S3 URL of pending template
  -> Int        -- ^ context lines for diff
  -> (OutputData -> IO ())
  -> IO (Either Text Int)
```

The confirmation prompt format matches all other confirmation prompts in the system
(`Iidy.Confirm.requestConfirmation`): blank line + `"? "` + bold bright red ANSI
on TTY + message + reset + `" (y/N) "`. Non-TTY: `"? " <> message <> " (y/N) "`.

**Estimated complexity**: Medium. The function involves three S3 reads, conditional
prompting, and up to three S3 writes, with error handling at each step. The
primary complexity is the `OdApprovalStatus` emit occurring before the pending
existence check branches.

---

### US-10-003: Handle already-approved templates without unnecessary upload

**As a** CI Pipeline or Developer, **I want** the request command to exit 0 without
re-uploading when the template has not changed, **so that** repeated runs of CI
pipelines are idempotent and do not create spurious `.pending` objects for already-
approved content.

**Acceptance Criteria:**

- After computing the content hash and deriving the approved S3 key, a `HeadObject`
  check determines whether an approved object already exists at that key.
- If the approved object exists: emit `OdApprovalRequestResult` with
  `arrAlreadyApproved = True` and return exit code 0. No `PutObject` call is made.
- If the approved object does not exist (including if `HeadObject` returns an access-
  denied error, which is mapped to `False`): proceed with uploading the pending object.
- The output emitted in the already-approved case must include:
  - `arrTemplateLocation` = the full `s3://bucket/approvedKey` URL
  - `arrPendingLocation` = the same URL (since no pending was created)
  - `arrAlreadyApproved` = `True`
  - `arrNextSteps` = `["Template has already been approved"]`
- On the review side: if the reviewer runs `template-approval review` on a URL
  where the approved key already exists (checked via `HeadObject` on `approvedKey`),
  `OdApprovalStatus` is emitted with `apsAlreadyApproved = True` and the command
  returns exit code 0 immediately.

**Logic Flow:**

```
-- Request path
s3ObjectExists awsEnv bucket approvedKey
  → True:
      emit OdApprovalRequestResult { alreadyApproved=True
                                   , templateLocation=approvedLoc
                                   , pendingLocation=approvedLoc  -- same URL
                                   , nextSteps=["Template has already been approved"]
                                   }
      return Right 0
  → False:
      [upload path, as in US-10-001]

-- Review path
s3ObjectExists awsEnv bucket approvedKey → alreadyApproved
emit OdApprovalStatus { alreadyApproved, ... }
if alreadyApproved: return Right 0
```

**Edge Cases:**

- Because `HeadObject` access denied is mapped to `False`, a developer without
  `s3:GetObject` on the approved prefix will always attempt to upload, even if the
  template is already approved. In cross-account setups this may cause spurious
  `.pending` uploads that reviewers must then handle.
- The hash is computed from the fully processed template content. If the same
  source file produces different output after preprocessing (e.g., due to
  non-deterministic imports such as `$random` or timestamps), the hash will differ
  on each run even if the semantic content is the same. Templates using
  non-deterministic imports are not suitable for the approval workflow.

**Error Scenarios:**

- `HeadObject` fails with a non-access-denied AWS error (network failure, invalid
  bucket name): exception propagated to top-level handler.

**Complexity Notes:**

This story describes behavior that falls out of US-10-001 and US-10-002 without
additional logic. It is documented as a separate story to make the idempotency
guarantee explicit for CI integrations.

**Estimated complexity**: Negligible (already implemented in US-10-001/US-10-002).

---

### US-10-004: Enforce IAM-based security model for approval workflow

**As a** Platform Engineer, **I want** the approval workflow to enforce separation
of concerns through IAM policies on the S3 bucket, **so that** developers cannot
self-approve their own templates, and the CloudFormation service role can only read
finalized approved content.

**Acceptance Criteria:**

- The workflow is designed around three IAM permission profiles. iidy-hs itself
  enforces no application-level role check; enforcement is entirely through S3 IAM
  policies on the bucket hosting the approved template locations.
- **Developer** (template authors):
  - Needs `s3:PutObject` on `<prefix>/*.pending` keys only.
  - Does not need `s3:GetObject` on approved keys (though missing it causes the
    idempotency check to fail silently; see US-10-003 edge cases).
  - Must NOT have `s3:PutObject` on non-pending keys (would allow self-approval).
- **Reviewer** (approval authority):
  - Needs `s3:GetObject` on all keys (pending and approved) to download and diff.
  - Needs `s3:PutObject` on non-pending keys to write approved and latest objects.
  - Needs `s3:DeleteObject` on pending keys to clean up after approval.
  - May have `s3:HeadObject` on all keys for existence checks.
- **CloudFormation service role** (deployment authority):
  - Needs `s3:GetObject` on approved keys only (not `.pending` keys).
  - Should NOT have access to `.pending` keys (prevents deploying unreviewed content).
  - Typically attached to the CFN stack via `ServiceRoleArn` in stack-args.yaml.
- **Cross-account safety**: The `PutObject` call in `uploadToS3` is intended to use
  `bucket-owner-full-control` ACL to ensure the bucket owner retains control when
  developer and reviewer are in different AWS accounts. The current implementation
  does not set an explicit ACL (this is a known gap). In same-account setups this
  is not an issue.

**Logic Flow:**

```
-- IAM policy sketch (not enforced by iidy-hs itself):

Developer policy:
  Allow s3:PutObject on arn:aws:s3:::<bucket>/<prefix>/*.pending

Reviewer policy:
  Allow s3:GetObject    on arn:aws:s3:::<bucket>/<prefix>/*
  Allow s3:HeadObject   on arn:aws:s3:::<bucket>/<prefix>/*
  Allow s3:PutObject    on arn:aws:s3:::<bucket>/<prefix>/*
  Allow s3:DeleteObject on arn:aws:s3:::<bucket>/<prefix>/*.pending

CloudFormation service role policy:
  Allow s3:GetObject on arn:aws:s3:::<bucket>/<prefix>/<hash>.*
  Deny  s3:GetObject on arn:aws:s3:::<bucket>/<prefix>/*.pending
```

**Edge Cases:**

- In the `templateApprovalRequest` function, the `HeadObject` existence check on
  the approved key will fail with access denied for developers who lack `s3:GetObject`.
  The exception is caught by `s3ObjectExists` (via `try @SomeException`) and mapped
  to `False`. The developer then proceeds to upload the pending object. This is
  tolerable but means idempotency checks do not work correctly for developers in
  cross-account setups.
- The `latest` key is not under the `*.pending` restriction and must be writable by
  the reviewer. It is read by reviewers (as the "previous approved" baseline for
  diffs) but should not be accessible to CloudFormation service roles directly;
  stack deployments should reference the exact content-addressed key, not `latest`.

**Error Scenarios:**

- Developer attempts to write a non-pending key (self-approval attempt): S3 returns
  access denied; `PutObject` fails; error propagated to top-level handler.
- CloudFormation service role attempts to read a `.pending` key: S3 returns access
  denied; deployment fails with a template load error. This is the intended
  enforcement boundary.

**Complexity Notes:**

iidy-hs participates in this security model by structuring S3 key names to make
IAM prefix conditions straightforward (`*.pending` for pending, no suffix for
approved). The application does not independently verify IAM policies or reject
operations that would violate the model; that enforcement belongs at the IAM layer.

**Estimated complexity**: N/A (security model documentation; no application logic
beyond the key naming convention already implemented).

---

### US-10-005: Track template identity via content hash

**As a** Developer or CI Pipeline, **I want** the approval state to be tied to
the exact content of the template, not its filename or version label, **so that**
any edit to the template (however small) requires a new approval before deployment,
and templates that have not changed are automatically recognized as already approved.

**Acceptance Criteria:**

- The SHA256 hash is computed over the fully processed template content as a UTF-8
  encoded byte string via `Crypto.Hash.hashWith SHA256 (TE.encodeUtf8 content)`.
- The hash is formatted as a 64-character lowercase hex string.
- The approved S3 key is `<normalizedBaseKey>/<sha256hex><ext>` where `ext` is
  taken from the `Template` field value (e.g. `.yaml`, `.json`, or `""` if the
  template field has no extension).
- A template whose body has not changed between runs (same processed content)
  produces the same hash and therefore the same S3 key. The `HeadObject` check in
  `templateApprovalRequest` will find the approved object and return
  `arrAlreadyApproved = True` without re-uploading.
- A template whose body has changed produces a different hash and therefore a
  different S3 key. The old approval is unaffected; a new `.pending` object is
  uploaded; a new review is required.
- Parameter-only changes in the argsfile (changing `Parameters` map values) do not
  affect the template body hash. The same approval applies regardless of parameter
  values.
- `calculateTemplateHash` and `generateVersionedLocation` are pure functions with
  no IO; they can be tested without AWS.

**Logic Flow:**

```
-- Hash computation (pure)
calculateTemplateHash :: Text -> Text
calculateTemplateHash content =
  let digest = hashWith SHA256 (TE.encodeUtf8 content)
      bytes  = BA.convert digest :: BS.ByteString
  in T.pack (concatMap toHex (BS.unpack bytes))

-- Key derivation (pure)
generateVersionedLocation :: Text -> Text -> Text -> Either Text (Text, Text)
generateVersionedLocation baseLocation content templatePath = do
  (bucket, baseKey) <- parseS3Url baseLocation
  let hash     = calculateTemplateHash content
      ext      = T.pack (takeExtension (T.unpack templatePath))
      basePath = if T.isSuffixOf "/" baseKey
                 then T.dropEnd 1 baseKey
                 else baseKey
      key      = basePath <> "/" <> hash <> ext
  Right (bucket, key)
```

**State machine for a single template path:**

```
No Request
  │  (developer runs template-approval request)
  ▼
Pending (.pending key exists, approved key absent)
  │  (reviewer runs template-approval review and approves)
  ▼
Approved (approved key exists, .pending key deleted)
  │  (developer edits template → new hash → new base key)
  ▼
New Pending (new .pending key, old approved key untouched)
  │  (reviewer approves new version)
  ▼
New Approved
```

**Edge Cases:**

- Whitespace-only differences in the template body (e.g., trailing newline added)
  produce a different hash and require a new approval. This is a feature, not a
  bug: the approval is for exact content.
- Templates preprocessed with `$random` tags or `{{now}}` Handlebars helpers are
  non-deterministic. Each run produces a different body and therefore a different
  hash. Such templates are incompatible with the approval workflow; operators
  should avoid non-deterministic constructs in templates intended for approval.
- The `ext` is extracted from the `Template` field string, not from the loaded file
  content's MIME type. If `Template: cfn-template.yaml` is used, `ext = ".yaml"`.
  If `Template: render:cfn-template.yaml` is used, `takeExtension "render:cfn-template.yaml"`
  returns `".yaml"` because `takeExtension` extracts the last suffix regardless of
  the `render:` prefix. This is correct behavior.
- Two templates with the same content but different file extensions will hash to
  the same key content but different S3 keys (different extensions). In practice
  CloudFormation templates are always YAML or JSON so this is not a concern.

**Error Scenarios:**

- Hash computation itself cannot fail (pure function over UTF-8 bytes).
- `parseS3Url` returns `Left` for malformed base locations; this propagates to
  the caller as a `Left` error before any hashing occurs.

**Complexity Notes:**

`calculateTemplateHash` depends on the `crypton` package (via `Crypto.Hash`),
which provides the `SHA256` algorithm. The `hashWith` call produces a `Digest
SHA256` value; `BA.convert` converts it to a raw `ByteString` for hex encoding.
The manual hex encoding loop (`toHex`) avoids a dependency on `base16-bytestring`.

**Estimated complexity**: Negligible. Both functions are pure, O(n) in template
size, and have no branching beyond the trailing-slash normalization.

---

## Testing Requirements

### Unit Tests (pure functions)

- `calculateTemplateHash` with known inputs: verify the 64-character lowercase hex
  output matches an independently computed SHA256. At minimum: empty string, single
  character, and a realistic YAML template fragment.
- `generateVersionedLocation` with:
  - Base location with trailing slash (`"s3://bucket/templates/"`) — verify slash
    is normalized.
  - Base location without trailing slash (`"s3://bucket/templates"`) — verify same
    key is produced.
  - Template path with `.yaml` extension — verify extension appears in key.
  - Template path with no extension — verify key ends with the hash directly.
  - Invalid base location (no bucket, no key) — verify `Left` is returned.
- `parseS3Url` with:
  - Valid URL `"s3://bucket/some/key"` — verify `Right ("bucket", "some/key")`.
  - URL without `s3://` prefix — verify `Left`.
  - URL with no bucket (`"s3:///key"`) — verify `Left`.
  - URL with no key (`"s3://bucket"`) — verify `Left`.
- `generateDiff` with:
  - Identical strings — verify empty output.
  - Single line added — verify `"+ line"` in output.
  - Single line removed — verify `"- line"` in output.
  - No changes in content but different ordering — verify non-empty diff
    (current implementation is set-theoretic, not positional).

### Integration Tests (via mock AWS)

- `templateApprovalRequest` with mock `cfnEnv`:
  - Both `ApprovedTemplateLocation` and `Template` present; `s3ObjectExists`
    returns `False`; `uploadToS3` succeeds — verify `OdApprovalRequestResult`
    emitted with `arrAlreadyApproved = False` and correct pending URL.
  - Same setup but `s3ObjectExists` returns `True` — verify
    `arrAlreadyApproved = True` and no upload attempted.
  - `ApprovedTemplateLocation` absent — verify `Left` returned without AWS calls.
  - `Template` absent — verify `Left` returned without AWS calls.
- `templateApprovalReview` with mock:
  - Pending exists, not yet approved, no latest, user approves — verify three
    S3 writes and `OdApprovalResult { arApproved = True, arCleanupCompleted = True }`.
  - Pending exists, already approved — verify `Right 0` with no diff or upload.
  - Pending does not exist — verify `Left "Pending template not found at ..."`.
  - Non-`.pending` URL — verify `Left "URL must end with .pending suffix"`.
  - No changes between pending and latest — verify auto-approve without confirmation.
  - User declines confirmation — verify `Right 1` and `OdApprovalResult { arApproved = False }`.
- Emission sequence for review (changes present, user approves): verify order is
  `OdApprovalStatus`, `OdTemplateDiff`, `OdApprovalResult`.
- Emission sequence for request (new upload): verify `OdApprovalRequestResult`
  is emitted exactly once.

### Renderer Tests

- `OdApprovalRequestResult` renders without crash in both `InteractiveRenderer`
  and `JsonRenderer`.
- `OdApprovalStatus`, `OdTemplateDiff`, `OdApprovalResult` each render without
  crash in both renderers.
- JSON renderer produces valid JSON for all four approval output types.

### Known Gaps (not yet tested or implemented)

- The `--no-lint-template` path: no `ValidateTemplate` call is made; `OdTemplateValidation`
  is never emitted. Tests for this path are deferred until lint integration is added.
- `bucket-owner-full-control` ACL on `PutObject`: not set in the current
  implementation. A test that verifies ACL header presence would require mock
  inspection of the raw `PutObject` request.
- Partial-failure handling during promotion (approved upload succeeds, latest
  upload fails): not tested; the current implementation discards upload errors
  during promotion.
- Context-line trimming in `generateDiff`: the `tdContextLines` value is stored but
  not used to trim output. Tests for context-line behavior are deferred.

---

## Cross-References

- `src/Iidy/Cfn/Operations/TemplateApproval.hs` — `templateApprovalRequest`,
  `templateApprovalReview`, `s3ObjectExists`, `uploadToS3`, `downloadFromS3`,
  `deleteFromS3`, `generateDiff`
- `src/Iidy/Cfn/TemplateHash.hs` — `calculateTemplateHash`, `generateVersionedLocation`,
  `parseS3Url`
- `src/Iidy/Cfn/TemplateLoader.hs` — `loadCfnTemplate`, `templateMaxBytes`
- `src/Iidy/Cfn/Types.hs` — `StackArgs.saApprovedTemplateLocation`,
  `StackArgs.saTemplate`, `OpTemplateApprovalRequest`, `OpTemplateApprovalReview`
- `src/Iidy/Output/Types.hs` — `ApprovalRequestResult`, `TemplateValidation`,
  `ApprovalStatus`, `TemplateDiff`, `ApprovalResult`, `OdApprovalRequestResult`,
  `OdTemplateValidation`, `OdApprovalStatus`, `OdTemplateDiff`, `OdApprovalResult`
- `src/Iidy/Confirm.hs` — `requestConfirmation` (used in review confirmation step)
- `src/Iidy/Cli/Parser.hs` — `approvalCommandsParser`, `approvalRequestArgsParser`,
  `approvalReviewArgsParser`, `ApprovalRequestArgs`, `ApprovalReviewArgs`
- `src/Iidy/Cli.hs` — `ApprovalCommands`, `ApprovalRequest`, `ApprovalReview`
- `src/Iidy/Output/Renderers/Interactive.hs` — renders approval output types
- `src/Iidy/Output/Renderers/Json.hs` — JSON rendering of approval output types
- `docs/requirements/05-cfn-operations.md` — CFN operations using approved templates
  via `StackArgs.saApprovedTemplateLocation`
- `docs/requirements/08-aws-integration.md` — AWS credential chain (used for S3 access)
- `DIVERGENCES.md` — known behavioral differences from Rust iidy
- Rust reference: `~/src/iidy/src/cfn/` (read-only oracle)
