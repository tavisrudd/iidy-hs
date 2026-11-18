# Known Divergences: iidy-hs vs iidy (Rust)

This document lists all intentional or framework-imposed behavioral differences
between the Haskell port (iidy-hs) and the Rust original (iidy).

## CLI Help Formatting

**Cause**: clap (Rust) vs optparse-applicative (Haskell) — different formatting libraries.

- Slightly different flag/argument layout in `--help` output
- clap auto-generates `--no-X` variants for boolean flags; optparse-applicative uses explicit `flag True False`
- All content (command names, descriptions, flag names) is identical

## YAML Serialization in Snapshots

**Cause**: serde_yaml vs custom HsYAML emitter.

Two Rust test snapshots (`handlebars-in-tags`, `yaml-11-booleans`) use serde_yaml's
internal serialization format which differs from actual CLI output. Our emitter
produces correct YAML tag syntax (e.g., `!Ref` tags). Both ports produce
identical output when run as CLI commands — the snapshot difference is a
test artifact in the Rust codebase.

## Shell Completion Scripts

**Cause**: clap_complete generates scripts dynamically; Haskell uses hardcoded scripts.

- PowerShell completion is not supported (Rust supports it via clap_complete)
- Completion script content may differ in edge cases (both support bash, zsh, fish)
- Default shell detection: both read `$SHELL` env var when no shell argument given

## Error Display: stderr vs stdout TTY Check

**Cause**: Intentional improvement in Haskell.

Error color detection checks `stderr` TTY status in Haskell (since errors are
printed to stderr), while Rust checks `stdout`. The Haskell behavior is arguably
more correct — if stderr is piped to a file but stdout is a TTY, errors should
not contain ANSI codes since they'll end up in the file.

## Explain Command: More Permissive Input

**Cause**: Intentional Haskell improvement.

The `explain` command accepts multiple input formats:
- `ERR_2001` (standard, same as Rust)
- `err_2001` (case-insensitive, Haskell addition)
- `2001` (digits only, auto-prefixed, Haskell addition)

Rust only accepts the `ERR_NNNN` format.

## FORCE_COLOR Environment Variable

Both Rust and Haskell respect the `FORCE_COLOR` env var to force colored output
even when not connected to a TTY. Both also respect `NO_COLOR` with higher
priority (NO_COLOR > FORCE_COLOR > TTY check).

## describe-stack Event Pagination

**Cause**: Intentional optimization with conditional pagination.

Both implementations use single-page event fetches for polling loops (new events
always appear on the first page). For `describe-stack --events N`, Rust paginates
up to `N * 2` events to ensure the requested count is satisfiable. Haskell now
does the same via `fetchStackEventsUpTo`. The `list-stacks` command paginates
fully in both implementations.

## Drift Detection Polling Timeout

**Cause**: Intentional safety improvement in Haskell.

Rust polls `DescribeStackDriftDetectionStatus` indefinitely with no timeout.
Haskell adds a configurable safety cap (default: 100 iterations x 3s = 5 minutes)
to prevent infinite hangs on stuck drift detections. Emits a `LevelWarning`
status update if the cap is reached and proceeds with potentially incomplete
results. Constants are in `DescribeStackDrift.hs` (`driftPollMaxIterations`,
`driftPollIntervalSecs`).

**TODO**: Fix Rust to also have a timeout cap.

## Terminal Status List: UPDATE_FAILED Bug (Fixed in Haskell)

**Cause**: Bug in Rust iidy (inherited from iidy-js, then fixed in iidy-js).

The Rust port (`is_terminal_status.rs`) does NOT include `UPDATE_FAILED` in
its terminal status list, which is correct — CloudFormation auto-initiates
rollback after `UPDATE_FAILED`, so the polling loop must continue until
`UPDATE_ROLLBACK_COMPLETE` or `UPDATE_ROLLBACK_FAILED`. iidy-hs matches this.

However, an earlier iidy-hs bug DID include `UPDATE_FAILED`, which would have
caused premature polling termination. Fixed 2026-03-01.

Source of truth: `iidy-js/src/cfn/statusTypes.ts` (14 terminal statuses).
See `Context.hs` for detailed provenance documentation.

**TODO**: Audit Rust terminal status list against iidy-js to confirm full
alignment (DELETE_SKIPPED, REVIEW_IN_PROGRESS presence).

## JMESPath: Subset Implementation

**Cause**: Custom subset parser vs full `jmespath` crate in Rust.

The Haskell port implements a ~370 LOC custom JMESPath parser/evaluator covering
the subset used by iidy templates: field access, indexing, wildcards, projections,
filters, multi-select, pipes, comparisons, and literals. The Rust port uses the
full [`jmespath` crate](https://crates.io/crates/jmespath) which implements the
complete [JMESPath specification](https://jmespath.org/specification.html).

Unsupported features (not used by any iidy template in practice):
- All 26 built-in functions (`length()`, `keys()`, `sort()`, etc.)
- Slice expressions (`[0:5]`, `[::2]`)
- Binary logical operators (`&&`, `||`) — unary `!` IS supported
- Parenthesized expressions for precedence
- Quoted identifiers (`"foo bar"`)

If a user writes a JMESPath expression using an unsupported feature, they will
get a clear error message stating the feature is not supported (not a generic
parse error). See `notes/jmespath-subset.md` for full details.

## Live AWS Operations (Untestable Offline)

The following behaviors require live AWS and are verified by code review only:
- Stack creation/update/deletion actual API behavior
- S3 upload/download for template approval against real buckets (the
  request, review and deploy checks are tested against mock S3)
- SSM parameter read/write operations
- Real terminal spinner animation timing
- Live polling loop behavior with real CloudFormation events
- Network NTP time synchronization

## Import Trust Gate: Fails Closed

**Cause**: Intentional security fix (card C14).

A template may use the local-only import types (`file:`, plain paths, `env:`,
`git:`, `filehash:`, `filehash-base64:`) only when its own base location is
positively a local file: a plain path, `./`, `../`, `/` or `file:`, or a path
whose text before its first colon is not a valid RFC 3986 URI scheme (for
example `dir/./c:d.yaml`, which the file loader produces when `dir/x.yaml`
imports `./c:d.yaml`). Every other base is untrusted: `s3:` in both the short
(`s3:bucket/key`) and long (`s3://`) forms, `ssm:`, `ssm-path:`, `cfn:`,
`http(s):`, and any unknown or differently-cased scheme-shaped prefix. That
includes a local file named like `a:b.yaml` loaded without a `./` prefix: it
counts as local in Rust but is untrusted here, so it cannot use the local-only
import types (write `./a:b.yaml` instead). Windows drive paths such as
`C:\configs\stack-args.yaml` are scheme shaped too, so they are untrusted in
the same way; Rust treats them as local. There is no Windows build.

Rust (`src/yaml/imports/mod.rs:251-259`) treats a base as remote only when its
lower-cased prefix is `s3`, `http` or `https`, so a document loaded through
`ssm:`, `ssm-path:` or `cfn:` can still read local files, environment variables
and git data, and a base with an unknown prefix counts as local.

Relative imports from a remote parent also differ. Rust gives an unprefixed
import the parent's remote type (`mod.rs:263-281`, test
`test_relative_imports_inherit_remote_type`); Haskell classifies it as a local
file import and rejects it from an untrusted parent. This difference predates
C14 and is unchanged by it.

## AWS-Backed Imports Refused From Untrusted Documents

**Cause**: Intentional security fix (card C15).

A document whose requester chain is not trusted (any document from the
root template to it is remote and not under a `--trust-import-source`
prefix) cannot import `s3:` (both forms), `ssm:`, `ssm-path:` or `cfn:`. The
error names the import type and the untrusted location and suggests
`--trust-import-source`. The check runs before any AWS environment is used,
so a refused import makes no AWS call. Rust and iidy-js let a remote
template read these with the user's credentials, which together with an
attacker-built import URL let it send secrets to a server it controls (the
C4 review's finding). There is no same-bucket exception for `s3:`.

## HTTP Imports From Untrusted Documents: Address Filter

**Cause**: Intentional security fix (card C15).

An HTTP import requested by an untrusted document cannot reach IPv4
`127.0.0.0/8`, `0.0.0.0/8` or `169.254.0.0/16`, IPv6 `::`, `::1`, `fe80::/10`
or `fd00:ec2::/32`, or the IPv4-mapped, IPv4-compatible and NAT64
(`64:ff9b::/96`) forms of the blocked IPv4 ranges. The host name is resolved
locally and checked on the first request and on every redirect hop; plain
HTTP connects to the checked address. A trusted document's request to a URL
under a trusted prefix may only be redirected to trusted locations. Rust and
iidy-js fetch any address.

Known gaps:

- HTTPS: the TLS library does its own lookup after the check, leaving a
  DNS-rebinding window, limited by certificate validation for the requested
  host name.
- With `HTTP_PROXY` / `HTTPS_PROXY` set, the target is resolved and checked
  locally before the request goes to the proxy, but the proxy may resolve it
  differently, and the proxy's own address is not filtered. Behind a proxy
  on a network without external DNS, these imports fail with "cannot
  resolve".
- Private address ranges, 6to4 (`2002::/16`), Teredo (`2001::/32`), local-use
  NAT64 (`64:ff9b:1::/48`) and IPv4-translated (`::ffff:0:0/96`) addresses are
  not filtered.
- Requests from local or trusted documents are not filtered, redirects
  included.

HTTP imports no longer use a SOCKS proxy given in `http_proxy` /
`https_proxy` (the HTTP manager is built from `tlsManagerSettings`, which
honours HTTP proxies only). Rust's `reqwest` is built without its `socks`
feature, so this matches Rust; earlier iidy-hs versions accepted SOCKS
there.

## Custom Templates From Untrusted Locations: Parameters Only

**Cause**: Intentional security fix (card C15); follows iidy-js.

A custom resource template loaded from an untrusted location expands with
its parameters only, for resource-type use and for `!$expand`. Rust gives
every custom template the importing template's variables; iidy-hs keeps
that for local templates and templates under a trusted prefix reached
through trusted documents, and follows iidy-js (which isolates non-local
templates) for the rest.

## `--trust-import-source`

**Cause**: iidy-hs addition (card C15); neither Rust nor iidy-js has it.

`--trust-import-source PREFIX` (global, repeatable) makes documents under a
remote location prefix trusted like local files, when every document that
led to them is trusted: they may use AWS-backed imports, their HTTP imports
are not filtered, and as custom templates they see the importing template's
variables. They never gain the local-only import types. Prefixes are
validated at parse time (lower-case remote scheme, bucket or host without a
default port, trailing `/`, no `.` or `..` segment) and match as literal,
case-sensitive text prefixes. Trust comes from the command line only. `iidy
demo` passes the flag on to the commands it runs.

`iidy demo` passes `--no-remote-imports` and `--trust-import-source` to every
`iidy` command in the script, including when the running binary is the
`iidy` on `PATH` (the command name is kept and the flags follow it). Rust
skips substitution in that case (`demo.rs:93-112`), so its demo commands run
with remote imports allowed. Without any such flag the commands are left
untouched.

## Terminal Width: COLUMNS Override

**Cause**: Kept from the earlier Haskell implementation (card C9).

iidy-hs honours a valid `COLUMNS` (positive integer) as the highest-priority
output width. Otherwise it uses the real terminal size (the `terminal-size`
package), as Rust does; with neither, the interactive renderer falls back to
130. Rust never reads `COLUMNS`: its order is the real terminal size, then 130
(`src/output/terminal.rs:54`, `src/output/theme.rs:177`).

iidy-hs queries only stdout for the terminal size; Rust's `terminal_size`
tries stdout, stderr and stdin in turn. So with stdout redirected, Rust can
still find a size from stderr or stdin, while iidy-hs reports no width.
`COLUMNS` must be a positive integer of at most 10000; anything else is
ignored. A real size of 0 (reported by some ptys) is ignored too.

## YAML Sequence Indentation Outside get-import

**Cause**: Card C25 fixed `get-import` only; the other `serde_yaml` call sites
still use the indenting emitter.

Rust writes block sequences under a mapping key with the dashes at the key's
column (`serde_yaml`): `c:\n- x`. iidy-hs `get-import` now matches. These
iidy-hs outputs still indent the dashes (`c:\n  - x`), where Rust uses
`serde_yaml`: the `!$toYamlString` tag (`resolver.rs:1781`), the handlebars
`toYaml` helper (`helpers/serialization.rs:57`), the rendered template text
that `create-stack` and friends send to CloudFormation
(`cfn/template_loader.rs:143`), and the `param` commands' YAML output
(`params/mod.rs:234`, own emitter in `src/Iidy/Params/Client.hs`). The
documents parse to the same data; only the bytes differ. `render` itself
matches Rust (it uses Rust's own indenting emitter).

## Tag Argument Layout in get-import

`get-import` indents the dashes of a sequence argument under any
tag (`c: !$join\n  - ','`, and likewise for CloudFormation tags), where
Rust puts them at the key's column (`c: !$join\n- ','`). That is the
emitter's tag-argument layout (`emitTagArgument` in `src/Iidy/Yaml/Emitter.hs`).
Unresolved `!$` tags in a plain imported document print with the name and
argument as written, as Rust does.

## AWS Imports in Stack-Args Files

**Cause**: feature kept from iidy-js (TypeScript); Rust lacks it.

A stack-args file may use AWS imports (`ssm:`, `ssm-path:`, `cfn:`, `s3:`).
Rust preprocesses stack-args with an import loader that has no AWS
configuration (`src/cfn/stack_args.rs`, `src/yaml/engine.rs`), so those
imports fail there with "AWS configuration required". iidy-hs follows
iidy-js (`src/cfn/loadStackArgs.ts`): the imports run under an AWS
environment built from `Profile`, `Region` and `AssumeRoleARN` as written in
the file, merged under `--profile`, `--region` and `--assume-role-arn`.

Those three fields must then be plain strings or environment maps of plain
strings. When one is computed (a `!$` or other tag, a `{{...}}` template, or
an environment map without an entry for the environment) and the command
line does not set it, the first AWS import is refused before any AWS call,
naming the field and the option that sets it. Unlike iidy-js, a file
without AWS imports may still compute these fields; they take effect for
the deployment itself. A failure to build the import environment is
reported with its cause.

## get-import --format: Rejected at Parse Time

**Cause**: deliberate; follows iidy-js (TypeScript), which checks the format
at parse time, rather than Rust's late check.

`get-import --format` accepts exactly `yaml` and `json`, lower case. Anything
else, including `yaml-cloudformation`, `yml`, `YAML` and `Json`, is a command
line usage error (`error: option --format: Unknown output format: X. Valid
formats: json, yaml`, then the usage text, exit code 1) before the import is
loaded. Rust takes any string, loads the import and applies the query first,
then prints `Unsupported format: 'X'. Use 'yaml' or 'json'.` on stderr and
exits 1 (`src/cfn/get_import.rs`). `render --format` is unchanged and still
accepts `yaml-cloudformation`.

## Duplicate Mapping Keys: Error Text

**Cause**: HsYAML and aeson token streams, unlike serde_yaml and serde_json,
do not give a key path or byte column, and floats are displayed by iidy-hs.

A repeated key in an imported YAML or JSON document (file, HTTP, S3, SSM) or
in a `!$parseYaml` string is rejected, as in Rust. Which keys count as
repeated follows serde_yaml (`a` and `"a"`, `1` and `0x1`, `true` and `True`,
`1.0` and `1e0` and `01.0`, and equal sequences or mappings in any entry
order are the same key; `1` and `1.0`, `1` and `01` and `1` and `"1"` are not).
What differs is the message:
- Rust adds the enclosing key path for nested YAML (`b: duplicate entry ...`)
  and a line and column for JSON. iidy-hs adds ` at line L column C` (both
  1-based, at the repeated key) for YAML and nothing for JSON.
- JSON key identity is the decoded string only; a repeated key is reported as
  `duplicate entry with key "k"` and no position.
- Float keys are displayed by iidy-hs (`1.0`, `0.5`), which can differ from
  Rust for very large or very small values; infinities are `.inf` and `-.inf`.
- A repeated sequence or mapping key reads `duplicate entry in YAML map` (as
  Rust), a boolean key `` `true` `` and a null key `duplicate entry with null
  key`.

A repeated key in a top-level template (the `render` command and a `render:`
template), in stack-args and in a demo script is rejected the same way
(`duplicate entry with key "k" at line L column C`, as a parse error before
preprocessing). **Cause**: follows iidy-js (TypeScript), whose js-yaml rejects
it. Rust accepts such a key and keeps the last value. A template body fetched
from AWS for `convert-stack-to-iidy` stays lenient.
Separately, iidy-hs reads a value spelled `01` as the number 1 where Rust
reads a string; key identity above does not depend on that.

## Template: Missing Path Is an Error, Not Inline Content

**Cause**: deliberate; follows iidy-js (TypeScript), which has no inline
templates, and drops an accident of the Rust rule.

A `Template:` value that is not a URL and names no existing file is inline
content only when it starts with `{` or `[` (after trimming) or contains a
newline. Anything else is a path, and a missing file is an error naming the
resolved path (`Failed to load template from: PATH (no such file)`). Rust
(`src/cfn/template_loader.rs:57-61`) also takes any value under 260 bytes
without `/` or `\` as the body, so a typo such as `Template: templat.yaml`
is uploaded as a one-line template there. In iidy-hs a bare word naming an
existing file still loads that file.

## render: AWS Environment Built Lazily

Rust `render` has no AWS environment at all: it calls `preprocess_yaml` with
no AWS config (`render.rs:31-33`), so an `ssm:`, `ssm-path:`, `cfn:` or `s3:`
import fails there. iidy-hs gives `render` an AWS environment built from the
global AWS options (`--profile`, `--region`, `--assume-role-arn`), the same
way `get-import` does (the decision recorded in C23, item 9). The
environment is built once, at the first AWS-backed import the trust gate lets
through, so credentials are needed only when an AWS import is used: a
template with only `file:`, `env:` or no imports renders without any AWS
configuration, and an AWS import refused by the gate or by
`--no-remote-imports` never builds the environment. A credential, region or
STS failure is reported as an import error on that import. A stack-args file
rendered by `render` is not covered here.

## Template Approval

**Cause**: card C16. The approval workflow follows iidy-js (TypeScript), the
original, where Rust and iidy-hs had drifted from it; the entries below say
where iidy-hs differs from iidy-js, Rust, or both.

- **Deploy-time enforcement** (differs from Rust; follows iidy-js). With
  `ApprovedTemplateLocation` set, create-stack, update-stack (direct and
  `--changeset`), create-changeset, create-or-update and estimate-cost check
  the approved object with `HeadObject` and send a presigned `TemplateURL`
  for it (15 minutes) instead of the local body; a missing object is refused
  before any call that changes a stack. Rust sends the local body and checks
  nothing. iidy-js estimate-cost sends the URL without checking; iidy-hs
  refuses first.
- **Refusal text**. The suggested command is `iidy-hs --region R
  --environment E [--profile P] template-approval request <argsfile>`;
  iidy-js prints `iidy --region R [--profile P] template-approval request
  <argsfile>` without `--environment`, although the hash depends on the
  environment's render.
- **Review prompts on an empty diff** (differs from Rust; follows iidy-js).
  Rust and earlier iidy-hs reported "approved" without writing anything.
- **SHA256 keys** (differs from iidy-js; same as Rust). iidy-js names
  approved objects by the MD5 of the template, so templates approved with
  iidy-js are not found and must be approved again.
- **Request lint uses CloudFormation `ValidateTemplate`** (same as Rust;
  differs from iidy-js, which lints locally with laundry-cfn,
  `lint.ts:11-16`, and passes `Parameters` under
  `--lint-using-parameters`). The request therefore needs
  `cloudformation:ValidateTemplate` by default, and a `ValidateTemplate`
  access or network error also fails it. A body over 51199 UTF-8 bytes is
  skipped with a warning.
- **Bucket region** (differs from both). Every S3 call of the request,
  review and deploy check goes to the bucket's own region from
  `GetBucketLocation` (sent to us-east-1). If that call fails for any
  reason, the stack's region is used and a later S3 failure names the
  failed lookup. Tavis chose this option with the fallback "if the call is
  denied"; the supervisor accepted falling back on any failure, since every
  wrong-region result fails closed and the wider fallback keeps setups
  that cannot reach us-east-1 (regional VPC endpoints, other partitions,
  cross-account buckets). iidy-js uses us-east-1 for the review and the
  signed URL and the stack's region for the request; Rust uses the stack's
  region for the request and `--region` or us-east-1 for the review.
- **Presigned URL host**. amazonka signs on the regional host
  (`https://<bucket>.s3.<region>.amazonaws.com/...`, path style for dotted
  bucket names); iidy-js signs `https://s3.amazonaws.com/<bucket>/<key>`.
- **Size limit on the approval path**: 999999 bytes after rendering,
  counted in UTF-8 bytes, so 999999 is accepted and 1000000 refused.
  iidy-js counts UTF-16 units and refuses at `length >= 999999`
  (`loadCFNTemplate.ts:48`). Templates sent as a body keep the 51199-byte
  limit.
- **`latest` at the bucket root**. With a bucket-only
  `ApprovedTemplateLocation` (`s3://bucket` or `s3://bucket/`), iidy-hs
  writes `latest`; iidy-js writes `/latest` (`${bucketDir}/latest`,
  `approval/index.ts:85`, `104`). Both put the hashed object at the root.
- **Refusals with approval on**. A `Template` that is an `s3://` or
  `https://` URL, or no `Template`, is refused with its own message
  ("Template must be a local file when ApprovedTemplateLocation is set,
  not a URL (...)", "Template is required in stack-args.yaml when
  ApprovedTemplateLocation is set: ..."). iidy-js fails with "Unable to
  determine versioned template location" (`https://`, none) or "Use
  https:// S3 path-based urls ..." (`s3://`).
- **`HeadObject` errors other than 404** fail the request and review (as
  iidy-js, which rethrows); a 403 message notes that S3 also answers 403
  for a missing object when `s3:ListBucket` is not granted. Earlier iidy-hs
  read every error as "not approved" and uploaded.
- **Pending upload ACL**: `bucket-owner-full-control`, as iidy-js and Rust;
  the approve writes carry none, as iidy-js.

## Resource Limits on Untrusted Input

Rust bounds none of the following (`src/yaml/` has no depth, alias or helper
size constant; only the circular-import check at `engine.rs:82`). iidy-hs
refuses the input with an error naming the limit, its value and what hit it.
The values are named constants in `Iidy.Constants`.

- **YAML alias expansion**: at most 250000 nodes per document after every
  alias is expanded (scalars, sequences and mappings count one each), and at
  most 50 MiB of scalar text after expansion. Counted in the parser as the
  document loads, so a bomb is refused before anything is expanded.
- **Import depth**: at most 32 nested imports on one chain, the root
  document excluded ("import depth 33 exceeds 32: a.yaml -> b.yaml ...").
- **Import count**: at most 1000 imports resolved in one run, the root
  document excluded.
- **Handlebars helper output**: no single helper result over 1048576
  characters. `pad` and `replace` are the helpers that can amplify their
  input; both are checked before the result is built.
- **HTTP import total time**: 60 seconds from request to the end of the
  body, on top of the existing 30 second wait for the response headers and
  the 10 MB body cap.

## Control Characters in Terminal Output

**Cause**: Intentional hardening in Haskell (the Rust original has no such filter).

The interactive renderer escapes control characters in text that comes from
outside the tool (template text and diffs, AWS strings such as event reasons,
tags, parameters and output values, stack names, error text) before it adds
its own colour codes or computes column widths. Each escaped character is
shown as `\uNNNN` (four lower-case hex digits, the spelling Rust's YAML
emitter uses for control characters). Escaped: C0 controls except newline and
tab, DEL, C1 controls (U+0080-U+009F), U+2028, U+2029, the bidirectional
controls U+202A-U+202E and U+2066-U+2069, and a carriage return not directly
followed by a newline. Rust prints such text unfiltered.

Exempt: the two document outputs, `OdRawOutput` and the template body of
`OdStackTemplate` (what `render`, `get-import` and `get-stack-template`
print for redirecting into files), keep their bytes exact. The JSON renderer
already escapes control characters. Error text printed outside the renderer
(for example `dieTxt`) is not yet covered.

## YAML Output of Strings with Non-Printable Characters

**Cause**: Rust `render` bug, fixed in iidy-hs first (Rust fix: card C42).

iidy-hs prints a string containing a non-printable character (C0 controls
other than tab and newline, DEL, C1 controls including U+0085, U+2028,
U+2029, U+FEFF, U+FFFE, U+FFFF) double-quoted with YAML escapes, in every command that emits
YAML, so the output parses back to the same value. Short escapes are used
where YAML has them (`\0 \a \b \t \n \v \f \r \e \N \L \P`), otherwise `\xHH`
or `\uHHHH` with upper-case hex digits. Until C42 lands, Rust `render` prints
such strings differently (single-quoted or plain text with literal
backslash sequences, or the raw character), and the Rust parser keeps the
escapes as literal text, so its output is not valid for the original value.
Rust `get-import` (serde_yaml) already prints the same double-quoted form.

## Explain: Output Layout

**Cause**: deliberate; kept by Tavis (2026-11-16, card C30).

Rust `iidy explain` (`src/explain.rs:14-30`) prints, per known code, the
embedded markdown file for four codes only (ERR_1001, 2001, 4002, 5001;
`src/yaml/errors/ids.rs:182-188`, text in `src/docs/errors/`, which says
`IY2001` rather than `ERR_2001`). Every other code gets a generic block
(`ids.rs:334-356`): `Error ERR_NNNN: description`, `Category: ...`, the
description again, and "This error code doesn't have detailed documentation
yet." iidy-hs prints one layout for all codes: `Error ERR_NNNN`,
`Category:`, `Description:`, a blank line and a hand-written details
paragraph. The descriptions themselves equal Rust's `description()`
(pinned by a test); the no-argument message and its exit status (0) also
match Rust. The TypeScript original has no `explain` command.

## Demo: Sleep and Typing Delay Rounding

**Cause**: deliberate; kept by Tavis (2026-11-16, card C30).

Rust truncates the scaled `sleep:` duration to whole seconds
(`src/demo.rs:134-136`) and the typing delay to whole milliseconds
(`demo.rs:363-366`). iidy-hs rounds the scaled value to the nearest
microsecond (`sleepMicros`, `typingDelayMicros`), so `sleep: 1` at
`--timescaling 0.5` waits 0.5 s here and 0 s in Rust, and at 1.5 waits 1.5 s
against Rust's 1 s. The TypeScript original scales exactly
(`src/demo.ts:123,144`), so iidy-hs is nearer to it.

## Demo: Fractional sleep Values

**Cause**: follows the TypeScript original (card C30 decision).

`sleep: 0.5` is accepted and waits the scaled fractional time. Rust types
the field as `u64` (`src/demo.rs:43`) and rejects a fractional value;
TypeScript accepts it (`src/demo.ts:123`). A negative value is rejected at
parse time with `demo sleep must not be negative` (the earlier iidy-hs
silently skipped the sleep; Rust rejects it through `u64`). A value above
86400 seconds is also rejected at parse time (`demo sleep must not exceed
86400 seconds`) so the microsecond count cannot overflow.

## Demo: Masking Is Not Streamed

**Cause**: structural; out of scope of card C30.

Rust masks account numbers only in PTY mode, line by line, as output
arrives (`src/demo.rs:303-340`). iidy-hs masks the whole captured stdout and
stderr of each step separately after the step ends. Output is identical for
the Rust ARN cases (`demo.rs:490-530`, pinned by tests): Rust's second ARN
pass can never change what its first `\b\d{12}\b` pass left, so iidy-hs
uses the single pass. The TypeScript original has no masking and no
`--mask-secrets` option.

## CommandsBefore: Values Checked, Expanded Per Command

**Cause**: Intentional (Tavis, card C40, Option E of
`notes/C40/report--commands-before-design.org`): no stack-args value may
become shell code.

Rust and iidy-js run each `CommandsBefore` entry through bash in the
argsfile's directory for `create-stack`, `update-stack`, `create-changeset`
and `create-or-update`, and drop the field for every other command (Rust
`src/cfn/stack_args.rs:277-313`, `process_commands_before` from `:493`;
iidy-js `src/cfn/loadStackArgs.ts:137-166`, `src/cfn/runCommandSet.ts:11-67`).
iidy-hs runs them for the same commands, in the same directory, with the
same `iidy_*` variables, bash helper functions, banners and failure text,
and resolves imports again after them, as both do. It differs as follows.

Against both:

- Every value a `{{ ... }}` substitutes into a command must be a non-empty
  string of `[A-Za-z0-9._/:@+=,%-]` that does not start with `-`; any other
  value is refused (never quoted), naming the entry, the expression and the
  value's source. Every command is expanded once with the file hashes
  stubbed before the first one runs, so a refused value runs nothing.
- An entry must be a string written in the stack-args file. A tagged entry,
  an imported or computed list, and a `CommandsBefore` produced by a
  computed key are refused before anything runs.
- A `$defs` or `$imports` name that clashes with a built-in context name
  (`iidy`, `region`, `environment`) is refused.
- Stdin is inherited when it is a terminal and is `/dev/null` otherwise
  (Rust closes it; iidy-js always inherits it).
- Output is streamed (Rust buffers it until the command exits); in
  `--output-mode json` the banners and the commands' stdout go to stderr.
- `PKG_SKIP_EXECPATH_PATCH` (a Node packaging workaround) is not set.
- A bare argsfile name runs the commands in `.`.

Against Rust only:

- Rust preprocesses the document (tags, `$defs`, `$imports`) into the
  command text before expanding it with the `iidy` namespace, so its
  commands can be built from computed values, and a `{{ iidy.region }}` in
  an entry fails its first preprocess ("Variable error: 'iidy.region' not
  found"). iidy-hs takes the entry as written and expands it once with the
  iidy-js context (`iidy.*`, bare `region` and `environment`, every
  `$defs` and `$imports` name).
- Rust has no `filehash` or `filehashBase64` Handlebars helper (only the bash
  functions) and expands every command before running any. iidy-hs has both
  helpers (a literal path only, relative to the argsfile, as a whole
  `{{ ... }}` output) and expands each
  command just before it runs, so `filehash` sees what earlier commands
  built.
- A command killed by a signal reports "killed by signal N" (Rust: "exit
  code -1").
- `iidy.stackName` prefers the stack name given on the command line, as
  iidy-js does (`loadStackArgs.ts:157`); Rust uses the file's `StackName`.
- With no region resolved (no `--region`, `Region`, `AWS_REGION` or
  `AWS_DEFAULT_REGION`), the commands still run with `iidy_region` empty
  (and a `{{ iidy.region }}` is refused as empty); Rust fails the load
  before the commands (`stack_args.rs:258`). iidy-hs then fails when it
  builds the AWS environment, after the commands ran.

Against iidy-js only:

- The `iidy_*` variables are set over the inherited environment (Rust
  order); in iidy-js an inherited `iidy_region` wins.
- A command killed by a signal fails the load; iidy-js treats it as success.
- `filehash` takes a literal path only, and only as a whole `{{ ... }}`
  output (not as a helper argument or block condition).

## `--debug`: Accepted, No Effect

**Cause**: shared with Rust (not a divergence from it); recorded for the
difference from iidy-js (Tavis, card C22).

`--debug` is accepted and does nothing; the help text keeps Rust's "Log debug
information to stderr.". Rust parses the flag (`src/cli.rs:100-107`) and
nothing reads it; its `debug!` output follows `RUST_LOG`
(`src/main.rs:265`), and `debug_log!` is compiled in only with the
`debug-logging` cargo feature. iidy-js sets `DEBUG` and the log level to
`debug` with the flag (`src/cli/utils.ts:22-25`, `src/main.ts:470`), and
its `logger.debug` calls then print (for example
`src/cfn/stackArgsToX.ts:47-52`). Scripts that pass `--debug` keep working.
