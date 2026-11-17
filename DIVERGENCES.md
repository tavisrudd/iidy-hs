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
- S3 upload/download for template approval
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

## Unresolved Tags in Plain Imported Documents: Spelling Normalised

**Cause**: the parser stores a preprocessing tag as a typed node, not as its
source text.

A plain imported document (no `$imports` or `$defs`) keeps its `!$` tags
unresolved, as in Rust. The tag is printed from the parsed node, so three
spellings come out in canonical form where Rust prints the source form:

- Alias tags: `!$include x` prints as `!$ x`, and `!$string x` prints as
  `!$toYamlString x`.
- A one-element sequence argument to a single-argument tag loses its
  sequence: `!$not [true]` prints as `!$not true`.
- A tag whose argument is a mapping prints the fields the parser knows in a
  fixed order, not source order.

Separately, `get-import` indents the dashes of a sequence argument under any
tag (`c: !$join\n  - ','`, and likewise for CloudFormation tags), where
Rust puts them at the key's column (`c: !$join\n- ','`). That is the
emitter's tag-argument layout (`emitTagArgument` in `src/Iidy/Yaml/Emitter.hs`),
outside this card.

Fixing the three spellings above needs the parser to keep the written tag name and argument node
on the AST.

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

Top-level templates and stack-args accept repeated keys in both ports.
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
