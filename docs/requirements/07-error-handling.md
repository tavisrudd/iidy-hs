# PRD: Error Handling

## Overview

iidy-hs provides structured, human-readable error messages for all preprocessing and
deployment failures. Each error carries a unique numeric code, a source location, ANSI
color formatting, a one-line guidance hint, a three-line source-context excerpt, and a
footer that directs the user to `iidy explain ERR_XXXX` for full documentation.

The error system covers 50 distinct error conditions across 9 categories, spanning YAML
syntax, variable/scope resolution, import loading, tag parsing, type validation,
Handlebars templating, CloudFormation intrinsics, CLI configuration, and internal/system
failures.

All error output goes to stderr. Color detection checks stderr's TTY status (diverging
from the Rust implementation, which checks stdout). The `--color` flag and the `NO_COLOR`
/ `FORCE_COLOR` environment variables provide explicit overrides.

## Technical Context

The error display pipeline is entirely pure (formatting functions accept the error record
and produce text); color detection is the only IO operation. The explain command accepts
`ERR_XXXX`, `err_xxxx`, or bare numeric codes. SIGINT is handled via POSIX `_exit(130)`
to avoid runtime backtrace output. `ColorChoice` has three values: `ColorAlways`,
`ColorNever`, `ColorAuto`.

### Complete Error Code Table

| Code | Constructor                     | Category              |
|------|---------------------------------|-----------------------|
| 1001 | InvalidYamlSyntax               | YAML Syntax           |
| 1002 | YamlVersionMismatch             | YAML Syntax           |
| 1003 | UnsupportedYamlFeature          | YAML Syntax           |
| 1004 | MalformedYamlStructure          | YAML Syntax           |
| 1005 | YamlMergeKeyUsage               | YAML Syntax           |
| 2001 | VariableNotFound                | Variable & Scope      |
| 2002 | VariableNameCollision           | Variable & Scope      |
| 2003 | InvalidVariableName             | Variable & Scope      |
| 2004 | CircularVariableReference       | Variable & Scope      |
| 2005 | VariableOutOfScope              | Variable & Scope      |
| 2006 | LookupQueryFailed               | Variable & Scope      |
| 3001 | ImportFileNotFound              | Import & Loading      |
| 3002 | ImportUrlUnreachable            | Import & Loading      |
| 3003 | ImportAuthenticationFailure     | Import & Loading      |
| 3004 | ImportCircularDependency        | Import & Loading      |
| 3005 | ImportFormatNotSupported        | Import & Loading      |
| 3006 | EnvironmentVariableNotFound     | Import & Loading      |
| 3007 | GitCommandFailure               | Import & Loading      |
| 3008 | S3AccessDenied                  | Import & Loading      |
| 3009 | SsmParameterNotFound            | Import & Loading      |
| 3010 | CloudFormationStackNotFound     | Import & Loading      |
| 4001 | UnknownPreprocessingTag         | Tag Syntax            |
| 4002 | MissingRequiredTagField         | Tag Syntax            |
| 4003 | InvalidTagFieldValue            | Tag Syntax            |
| 4004 | IncompatibleTagCombination      | Tag Syntax            |
| 4005 | TagSyntaxError                  | Tag Syntax            |
| 5001 | TypeMismatchInOperation         | Type & Validation     |
| 5002 | InvalidArrayOperation           | Type & Validation     |
| 5003 | InvalidObjectOperation          | Type & Validation     |
| 5004 | DivisionByZero                  | Type & Validation     |
| 5005 | InvalidComparison               | Type & Validation     |
| 5006 | StringOperationOnNonString      | Type & Validation     |
| 6001 | HandlebarsSyntaxError           | Handlebars            |
| 6002 | UnknownHandlebarsHelper         | Handlebars            |
| 6003 | HandlebarsHelperArgumentError   | Handlebars            |
| 6004 | TemplateCompilationFailure      | Handlebars            |
| 6005 | TemplateExecutionError          | Handlebars            |
| 7001 | InvalidCloudFormationIntrinsic  | CloudFormation        |
| 7002 | CloudFormationReferenceError    | CloudFormation        |
| 7003 | CloudFormationDependencyIssue   | CloudFormation        |
| 7004 | CloudFormationTemplateSizeLimit | CloudFormation        |
| 8001 | InvalidCommandLineArgument      | Configuration         |
| 8002 | MissingRequiredConfiguration    | Configuration         |
| 8003 | ConfigurationFileNotFound       | Configuration         |
| 8004 | AwsCredentialsNotConfigured     | Configuration         |
| 8005 | UnsupportedFileFormat           | Configuration         |
| 9001 | InternalProcessingError         | Internal & System     |
| 9002 | MemoryAllocationFailure         | Internal & System     |
| 9003 | FileSystemPermissionDenied      | Internal & System     |
| 9004 | NetworkConnectivityIssue        | Internal & System     |
| 9005 | UnexpectedSystemError           | Internal & System     |

### Enhanced Error Display Format

```
<bold-red>Error Type<reset>: <message> @ <cyan>file:line:column<reset> <grey>(errno: ERR_XXXX)<reset>
  -> <light-blue>guidance text<reset>

<dark-grey>  N-1<reset> | <grey>previous line content<reset>
<red>    N<reset> | current line content
     |     <red>^^^<reset> <grey>inline description<reset>
<dark-grey>  N+1<reset> | <grey>next line content<reset>

   <light-blue>available variables: var1, var2, var3<reset>

   <light-blue>For more info: iidy explain ERR_XXXX<reset>
```

Line numbers are right-aligned in a fixed 4-character gutter (`padGutter4`), matching
Rust's `{:4}` format specifier. Carets are omitted when the column position is zero or
past the end of the line. The caret span is clamped to the remaining characters on the
current line.

### ANSI Color Assignments

| Role                  | Escape Code      | Applied To                        |
|-----------------------|------------------|-----------------------------------|
| Bold red (`ecBoldRed`) | `\ESC[1;31m`    | Error type word in header         |
| Red (`ecRed`)         | `\ESC[31m`       | Carets, current line number       |
| Cyan (`ecCyan`)       | `\ESC[36m`       | File location (file:line:col)     |
| Grey (`ecGrey`)       | `\ESC[38;5;245m` | Context line content, inline desc |
| Light blue (`ecLightBlue`) | `\ESC[38;5;75m` | Guidance arrow, help text, footer |
| Dark grey (`ecDarkGrey`) | `\ESC[90m`    | Previous/next line numbers        |
| Reset (`ecReset`)     | `\ESC[0m`        | Terminates every colored span     |

---

## User Stories

### US-07-001: See Enhanced Error Display with Source Context

**As a** Developer, **I want to** receive a richly formatted error message that names the
error type, shows the precise file location, provides a one-line guidance hint, and
renders a three-line source excerpt with caret underline, **so that** I can identify and
fix preprocessing mistakes without opening the source file manually.

**Acceptance Criteria:**

1. Every displayed error includes a header line in the form:
   `<error-type>: <message> @ <file>:<line>:<column> (errno: ERR_XXXX)`
2. The error type word is rendered in bold red; the file location in cyan; the errno tag
   in grey.
3. A guidance line immediately follows the header, indented two spaces, prefixed with
   `-> ` in light blue.
4. The source context block renders up to three lines: the line before the error (dark
   grey number, grey content), the error line itself (red number, default content), and
   the line after (dark grey number, grey content). Missing boundary lines (first line,
   last line) are silently omitted.
5. A caret line (`^` characters) appears directly below the error line when the column
   position is known and falls within the line's length. Carets are rendered in red.
6. An inline description follows the carets, separated by a space, in grey.
7. A footer line reads `For more info: iidy explain ERR_XXXX` in light blue.
8. When colors are disabled, all ANSI escape sequences are absent and the text layout
   is otherwise identical.
9. Line numbers in the gutter are right-aligned in a field of exactly 4 characters.
10. All error output is written to stderr.

**Logic Flow:**

The error formatter dispatches on the error variant. Each variant emits: header, guidance,
source context (with or without carets depending on variant), variant-specific help
sections, then footer. Source lines are retrieved by 1-based index. Gutter numbers are
right-aligned in 4 characters. Caret span is computed as
`max 1 (min spanLen (lineLen - col + 1))`.

**Edge Cases:**

- Error on the very first line: previous-line slot is empty, omitted.
- Error on the very last line: next-line slot is empty, omitted.
- Column position of 0 or past end of line: caret line is suppressed entirely.
- Empty inline description: caret line still appears, without the trailing grey label.
- Source content not available: all context lines are suppressed without error.

**Error Scenarios:**

- `formatSourceContext` receives a `SourceLocation` with a line number beyond the source:
  all three context slots resolve to `Nothing` and are omitted gracefully.

**Complexity Notes:**

Medium. The formatting logic is pure and straightforward, but the exact whitespace and
colour-span boundaries must match the Rust reference output byte-for-byte in snapshot
tests. The gutter width (4 chars), the `-> ` prefix, and the `| ` separator are all
fixed constants that must not drift.

---

### US-07-002: Track Error Position in YAML Files

**As a** Developer, **I want** errors to report the exact line and column in the YAML
source where the problem occurred, **so that** my editor can jump directly to the
offending location.

**Acceptance Criteria:**

1. Every error message includes a `SourceLocation` with non-zero file, line, and column
   fields.
2. Line numbers are 1-based in all user-visible output.
3. Column numbers are 1-based in all user-visible output.
4. For tag-related errors, the position points to the tag name (e.g. `!${}`, `!Ref`)
   rather than the value; adjustment logic searches backward from the parser-reported
   position to find the tag token on the current or immediately preceding line.
5. The parser's internal 0-based line/column indices are converted to 1-based before being
   stored in `SourceLocation`.
6. When no position is available, the location displays as `<unknown>:0:0` and the caret
   line is suppressed.

**Logic Flow:**

The YAML parser fires parse events with 0-based position values. The conversion layer
increments both line and column by 1 before constructing `SourceLocation`. Tag-position
adjustment iterates over the source lines starting at the reported line, scanning for
the tag string, and updates the column accordingly.

**Edge Cases:**

- Multi-line scalar: position points to the opening line of the scalar.
- Anchor and alias resolution: position refers to the usage site, not the anchor
  definition.
- Synthetic errors generated from post-parse validation: position may be approximate and
  point to the containing mapping key rather than the offending value.

**Error Scenarios:**

- The YAML parser omits position data for certain parse events: `SourceLocation` is
  constructed with line=0 and column=0, and caret rendering is skipped.

**Complexity Notes:**

Medium. The 0-to-1-based conversion is trivial, but the tag-position search heuristic
requires care to avoid false positives when the tag string appears as ordinary text
earlier on the same line.

---

### US-07-003: Look Up Error Explanations via the explain Command

**As a** Developer, **I want to** run `iidy explain ERR_2001` (or `iidy explain 2001`)
and receive a full description of what the error means and how to resolve it, **so that**
I can learn about error conditions without consulting external documentation.

**Acceptance Criteria:**

1. Accepts one or more error codes as arguments: `iidy explain ERR_2001 ERR_3002`.
2. `iidy explain ERR_XXXX` (upper-case prefix) resolves to the matching error code and
   prints the explanation to stdout.
3. `iidy explain err_xxxx` (lower-case prefix) resolves identically to the upper-case
   form.
4. `iidy explain XXXX` (bare integer, no prefix) also resolves correctly.
5. A known code produces output containing: the error code string (`ERR_XXXX`), the
   category name, a short description, and a detailed explanation paragraph; the exit
   code is 0.
6. An unknown code produces a message on stderr indicating the code was not recognised;
   processing continues with remaining codes. The overall exit code is still 0.
7. The explain command is more permissive than the Rust implementation regarding input
   formats (lower-case prefix and bare integers are accepted in addition to the canonical
   `ERR_XXXX` form).

See also `11-utilities.md` US-11-002 for the full multi-code behavior specification.

**Logic Flow:**

For each code argument: normalise to upper-case, strip the `ERR_` prefix if present,
parse the remaining string as an `Int`, and call `errorIdFromCode`. A `Just` result
triggers the explanation lookup (stdout); a `Nothing` result triggers the unknown-code
message (stderr). Processing continues with the next code regardless.

**Edge Cases:**

- Input contains leading/trailing whitespace: behaviour unspecified; recommend stripping.
- Input is `ERR_0` or a negative number: resolves to `Nothing`, treated as unknown.
- Input is a valid integer but out of the defined range (e.g. `1999`): treated as unknown.
- Multiple codes with some unknown: known codes print to stdout, unknown codes print to
  stderr; overall exit code is still 0.

**Error Scenarios:**

- `iidy explain` with no argument: prints `"Usage: iidy explain <CODE>..."` to stderr
  and returns (exit code 0). Does not report ERR_8001.

**Complexity Notes:**

Low. The lookup is a pure table scan. The only implementation risk is ensuring the
normalisation logic handles all three input variants without omitting the lower-case and
bare-integer forms that the Rust binary does not accept.

---

### US-07-004: Handle YAML Syntax Errors (ERR_1001 – ERR_1005)

**As a** Developer, **I want** iidy to report precise YAML syntax failures with the
specific sub-category (syntax, version mismatch, unsupported feature, malformed
structure, or merge-key usage), **so that** I know whether the file is structurally
broken or merely uses a YAML feature that iidy does not support.

**Acceptance Criteria:**

1. A file with invalid YAML syntax (e.g. an unclosed bracket, bad indentation) produces
   ERR_1001 with a short message describing the parse failure.
2. A `%YAML 1.2` directive in a file processed under YAML 1.1 rules (or vice versa)
   produces ERR_1002.
3. Use of a YAML tag or feature not supported by iidy's parser produces ERR_1003.
4. A file whose top-level structure is not a mapping (e.g. a bare scalar or sequence
   where a CloudFormation template is expected) produces ERR_1004.
5. Use of the YAML merge key (`<<`) produces ERR_1005 with guidance explaining that merge
   keys must be expanded before preprocessing.
6. All five error variants render the standard header-guidance-context-footer layout.
7. The guidance and fix-hint sections for ERR_1001 and ERR_1005 include an `example:`
   inline block where applicable.

**Logic Flow:**

YAML parse failures are caught in the YAML loading layer and mapped to `YamlSyntaxError`
records. The short message, guidance, fix hint, and example fields are populated from the
parser diagnostic. The error formatter renders the YAML syntax error branch, which appends
an extra blank line before the footer.

**Edge Cases:**

- A file with a BOM character: treated as a syntax error or silently stripped, depending
  on parser behavior.
- An empty file: produces a malformed-structure error (ERR_1004) because an empty
  document cannot be a template mapping.
- A file containing only comments: same as empty file.

**Error Scenarios:**

- The YAML parser returns multiple parse errors: only the first is surfaced; subsequent
  errors may be cascades of the first.

**Complexity Notes:**

Low for the display layer; medium for the mapping layer, which must translate the YAML
parser's internal error values to the five iidy codes without losing position information.

---

### US-07-005: Handle Variable and Scope Errors (ERR_2001 – ERR_2006)

**As a** Developer, **I want** clear messages when a variable reference cannot be
resolved, names collide, names are syntactically invalid, references are circular, a
variable is used outside its defined scope, or a JMESPath / lookup query fails, **so
that** I can quickly identify which variable is problematic and what variables are
actually available at that point.

**Acceptance Criteria:**

1. ERR_2001 (VariableNotFound) includes the variable name in the message and renders the
   `available variables:` list in light blue below the source context.
2. ERR_2002 (VariableNameCollision) names both the new binding and the existing binding
   that it conflicts with.
3. ERR_2003 (InvalidVariableName) includes the invalid name and states the allowed
   character set or naming rules.
4. ERR_2004 (CircularVariableReference) names the variable that forms the cycle and, if
   known, the chain of references.
5. ERR_2005 (VariableOutOfScope) reports the variable name and explains why the reference
   is out of scope (e.g. used before a `!$with` block closes).
6. ERR_2006 (LookupQueryFailed) includes the failed query path and renders the
   `available keys:` list in light blue when the target object exists but the path does
   not match.
7. When the available-vars or available-keys list is empty, the section is omitted
   entirely (no blank heading).
8. The caret span for ERR_2001 is set to `length(variable_name) + 3` (accounting for the
   surrounding `${` and `}` syntax).

**Logic Flow:**

Variable resolution runs during template preprocessing. On failure, the error record is
constructed with the current scope's variable list attached. The formatter renders the
available-vars or available-keys section only when the list is non-empty.

**Edge Cases:**

- Variable name contains Unicode: the caret span must account for byte length vs.
  character length; caret span uses character length.
- Available-vars list is very long (> 20 items): all are rendered on one line, separated
  by `, `.
- Circular reference chain involves more than two variables: the full chain should be
  included if traceable.

**Error Scenarios:**

- A variable is both undefined and would collide with a built-in: ERR_2001 takes
  precedence over ERR_2002.

**Complexity Notes:**

Medium. The availability list requires threading scope information through the
preprocessing pipeline to the error constructor. The caret-span formula (`len + 3`) must
match the Rust reference exactly.

---

### US-07-006: Handle Import and Loading Errors (ERR_3001 – ERR_3010)

**As a** Platform Engineer, **I want** specific error codes for each category of import
failure (missing file, unreachable URL, auth failure, circular dependency, unsupported
format, missing env var, git failure, S3 denied, SSM not found, CFN stack not found),
**so that** I can distinguish a misconfigured path from a permissions problem and route
the alert to the right team.

**Acceptance Criteria:**

1. ERR_3001 (ImportFileNotFound) states the resolved absolute path that was not found and
   the source location of the `!$import` tag.
2. ERR_3002 (ImportUrlUnreachable) states the URL and the HTTP status code or network
   error.
3. ERR_3003 (ImportAuthenticationFailure) states the URL or resource identifier without
   embedding credentials; it must not log secret values.
4. ERR_3004 (ImportCircularDependency) names the import path that creates the cycle and
   lists the import chain.
5. ERR_3005 (ImportFormatNotSupported) states the file extension or MIME type that was
   detected.
6. ERR_3006 (EnvironmentVariableNotFound) names the missing variable and, where
   applicable, lists the environment variables that are set and visible to iidy.
7. ERR_3007 (GitCommandFailure) includes the git sub-command that was invoked and the
   first line of its stderr output.
8. ERR_3008 (S3AccessDenied) names the S3 bucket and key.
9. ERR_3009 (SsmParameterNotFound) names the SSM parameter path.
10. ERR_3010 (CloudFormationStackNotFound) names the stack and the AWS region queried.
11. All ten variants render within the standard header-guidance-context-footer layout.

**Logic Flow:**

Import resolution dispatches on the URI scheme (`file://`, `http://`, `https://`,
`s3://`, `ssm://`, `cfn://`, bare paths). Each resolver's failure branch is mapped to
the appropriate error code. The error record is constructed with the source location of
the originating `!$import` tag.

**Edge Cases:**

- Relative import paths: resolved relative to the containing file's directory before the
  not-found check.
- Circular detection: a set of in-progress import paths is threaded through the resolver;
  the cycle is detected when a path is added that is already in the set.
- ERR_3006 in CI: available env var list may be very long; consider truncation if over 50
  items.

**Error Scenarios:**

- Network unavailable when resolving `http://` import: ERR_3002 is raised; the error
  message must not block indefinitely (timeout required).

**Complexity Notes:**

High. Ten distinct error codes, each requiring bespoke context capture. The circular-
dependency detection requires state threading. The CI env-var listing must not expose
secrets.

---

### US-07-007: Handle Tag and Type Errors (ERR_4001 – ERR_5006)

**As a** Developer, **I want** iidy to distinguish between a tag it does not recognise
(4001), a tag with missing or invalid fields (4002–4004), a general tag syntax failure
(4005), and the six type-mismatch conditions (5001–5006), **so that** I can tell whether
I have a typo in a tag name or a genuine type error in a value expression.

**Acceptance Criteria:**

1. ERR_4001 (UnknownPreprocessingTag) includes the tag name as seen in the source and
   renders carets spanning the full tag name. The footer contains an `example:` block
   showing a valid tag from the same namespace when available.
2. ERR_4002 (MissingRequiredTagField) names the missing field and the tag type that
   requires it.
3. ERR_4003 (InvalidTagFieldValue) names the field, the value that was found, and the
   expected type or set of allowed values.
4. ERR_4004 (IncompatibleTagCombination) names both tags and explains why they cannot
   appear together.
5. ERR_4005 (TagSyntaxError) is used for structural parse failures within a known tag
   (e.g. a `!$with` block that is not a mapping).
6. When `tpiSpanLen > 0`, the tag error renders with carets; when `tpiSpanLen == 0`, it
   renders via `formatSourceContextNoCarets` (no caret line, but three context lines
   still shown).
7. ERR_5001 (TypeMismatchInOperation) renders the `formatTypeMismatchHelp` block, which
   states both the expected and found types, with an optional extra hint.
8. ERR_5002 (InvalidArrayOperation) and ERR_5003 (InvalidObjectOperation) name the
   operation attempted and the actual type of the value.
9. ERR_5004 (DivisionByZero) reports the expression context.
10. ERR_5005 (InvalidComparison) names the two types being compared.
11. ERR_5006 (StringOperationOnNonString) names the operation and the actual type.

**Logic Flow:**

Tag parsing failures surface with a `spanLen` field set by the parser. The error
formatter checks `spanLen > 0` and routes to the appropriate context formatter (with or
without carets). Type errors carry the expected type, found type, and an optional extra
hint.

**Edge Cases:**

- Tag with a multi-byte Unicode name: caret span uses character count, not byte count.
- Type error inside a deeply nested `!$map` or `!$reduce`: position points to the scalar
  that caused the error, not the enclosing tag.

**Error Scenarios:**

- An unknown tag that closely resembles a known tag (e.g. `!$improt` vs `!$import`): the
  error message for ERR_4001 may include a `Did you mean?` suggestion if the edit
  distance is 1 or 2.

**Complexity Notes:**

Medium. The caret/no-caret branching for tag parsing errors is the main subtlety. Type
errors require the type information to be available at the error construction site.

---

### US-07-008: Handle Handlebars Errors (ERR_6001 – ERR_6005)

**As a** Developer, **I want** detailed error messages when a Handlebars template fails
to parse or execute, **so that** I can identify typos in helper names, malformed
delimiter syntax, and runtime evaluation failures.

**Acceptance Criteria:**

1. ERR_6001 (HandlebarsSyntaxError) includes the character offset within the template
   string where the parse failure was detected.
2. ERR_6002 (UnknownHandlebarsHelper) names the helper that was referenced and, where
   possible, lists the registered helpers.
3. ERR_6003 (HandlebarsHelperArgumentError) names the helper, the argument position or
   name that is wrong, and the expected argument type or count.
4. ERR_6004 (TemplateCompilationFailure) is used for failures that occur during the
   compile phase rather than the parse phase; it includes the template source fragment.
5. ERR_6005 (TemplateExecutionError) is used for runtime failures (e.g. a helper that
   throws); it includes the helper name and the underlying error message.
6. All five variants render the standard header-guidance-context-footer layout, with the
   YAML source context pointing to the scalar node that contains the Handlebars template
   string.
7. Built-in helpers registered by iidy (`toYaml`, `filehash`, `filehashBase64`, plus
   standard helpers) are included in the available-helpers list for ERR_6002.

**Logic Flow:**

Handlebars evaluation is invoked from the scalar preprocessing path. Failures from the
parser or evaluator are caught and converted to structured error values before propagating
up to the display layer.

**Edge Cases:**

- Handlebars template inside a multi-line YAML literal block: the YAML source location
  points to the first line of the literal; the character offset within the template
  identifies the exact failure point.
- Nested Handlebars in a loop helper (`{{#each}}`): the source location is the outer
  template node; the inner offset is reported in the message text.

**Error Scenarios:**

- ERR_6005 when a helper performs I/O (e.g. `filehash` on a missing file): the
  underlying filesystem error message is included.

**Complexity Notes:**

Medium. Handlebars errors occur deep in the evaluation stack; ensuring that YAML source
positions are preserved through to the error renderer requires explicit position threading
from the YAML event layer to the Handlebars invocation site.

---

### US-07-009: Control Error Colors via --color and Environment Variables

**As a** CI Pipeline, **I want** to disable ANSI color codes in error output by setting
`NO_COLOR` or passing `--color never`, **so that** log aggregation tools receive clean
plain-text error messages without escape sequences.

**Acceptance Criteria:**

1. `--color always` forces ANSI codes on regardless of TTY status or environment
   variables.
2. `--color never` suppresses all ANSI codes regardless of TTY status or environment
   variables.
3. `--color auto` (default) applies the following precedence:
   a. If `NO_COLOR` is set (any value), produce plain text.
   b. Else if `FORCE_COLOR` is set (any value), produce colored output.
   c. Else check whether stderr is a TTY (`hIsTerminalDevice stderr`): if yes, produce
      colored output; if no, produce plain text.
4. The `NO_COLOR` check takes precedence over `FORCE_COLOR`.
5. Color detection is performed once at startup and the resulting `ErrorColors` record is
   threaded through the entire error formatting pipeline.
6. When colors are disabled (`noColors`), all six ANSI fields in `ErrorColors` are empty
   strings and the reset field is also empty; the visual layout (indentation, `->`,
   `|`, `^`) is preserved in plain text.
7. This implementation diverges from the Rust iidy, which checks stdout TTY. The
   Haskell implementation checks stderr TTY because all error output goes to stderr. This
   divergence is documented in `DIVERGENCES.md`.

**Logic Flow:**

Error color detection is called after argument parsing.
- `ColorAlways` returns full colors.
- `ColorNever` returns no colors.
- `ColorAuto` checks `NO_COLOR`, then `FORCE_COLOR`, then falls through to
  `hIsTerminalDevice stderr`.

**Edge Cases:**

- Both `NO_COLOR` and `FORCE_COLOR` set: `NO_COLOR` wins.
- `NO_COLOR` set to an empty string: an empty value still suppresses color (presence
  check, not value check).
- Terminal type is `dumb`: `hIsTerminalDevice` returns false; color is suppressed.
- Output redirected to a file: stderr is not a TTY; color is suppressed.

**Error Scenarios:**

- `--color invalid_value`: CLI argument parser raises ERR_8001.

**Complexity Notes:**

Low. The logic is a four-case decision tree. The key correctness requirement is that
`NO_COLOR` precedes `FORCE_COLOR` in the precedence chain, matching the no-color.org
specification.

---

### US-07-010: Handle Exit Codes Consistently

**As a** CI Pipeline, **I want** iidy to exit with predictable codes (0 = success,
1 = any error, 130 = user cancellation), **so that** build pipelines can distinguish
between template errors, deployment errors, and intentional user aborts without parsing
stderr.

**Acceptance Criteria:**

1. Successful completion of any command exits with code 0.
2. Any preprocessing, validation, AWS API, or configuration error exits with code 1.
3. A user-initiated cancellation — either by pressing Ctrl+C (SIGINT) or by declining a
   confirmation prompt — exits with code 130.
4. SIGINT handling uses POSIX `_exit(130)` to bypass the GHC runtime shutdown sequence
   and avoid printing a GHC backtrace or `ThreadKilled` message to the terminal.
5. Declining a confirmation prompt (e.g. for `delete-stack`) sets the exit code to 130
   and exits cleanly without printing an error message to stderr.
6. No other exit codes are used; in particular, exit code 2 (used by some Unix tools for
   argument errors) is not used — argument errors exit with code 1.
7. The exit code is the only mechanism for communicating pass/fail to the calling
   process; no sentinel strings are written to stdout for this purpose.

**Logic Flow:**

The CLI parser is invoked with a custom execution wrapper to retain control over the exit
path. Argument parse failures are caught and converted to exit code 1. SIGINT is caught
via a signal handler which calls `_exit(130)`. Confirmation-prompt refusal returns a
value that causes the command handler to exit with code 130.

**Edge Cases:**

- Nested SIGINT (Ctrl+C pressed during the SIGINT handler): `_exit` is non-reentrant
  but fast enough that this is not a practical risk.
- Async exception raised by the GHC runtime for `ThreadKilled`: this must not reach the
  user as an error message; the SIGINT handler must intercept before the runtime does.
- Long-running AWS polling interrupted by Ctrl+C: polling threads are killed before
  `_exit` is called; any partial output already written to stdout/stderr remains.

**Error Scenarios:**

- Command exits with code 1 when an AWS API call returns a retryable error after all
  retries are exhausted.

**Complexity Notes:**

Low for the exit-code assignments themselves. Medium for the SIGINT-to-`_exit(130)` path,
which must avoid runtime backtrace output while still terminating cleanly. Using `_exit`
bypasses output buffer flushing, so any buffered output may be lost; iidy uses
line-buffered output to mitigate this.

---

## Testing Requirements

1. **Snapshot tests** for each of the 6 enhanced preprocessing error variants with colors
   enabled and colors disabled; output must match the Rust reference snapshots
   byte-for-byte.
2. **Unit tests** for header formatting, source context (with carets), source context
   (without carets), available-vars section, available-keys section, and gutter padding
   — covering boundary line numbers (line 1, last line) and boundary column values
   (col 0, col past end).
3. **Unit tests** for error color detection covering all 7 combinations of `ColorChoice`,
   `NO_COLOR`, `FORCE_COLOR`, and TTY status.
4. **Unit tests** for error code lookup verifying the round-trip property for all 50
   codes and that unknown codes return no result.
5. **Unit tests** for error ID formatting verifying the `ERR_XXXX` format for each code.
6. **Integration tests** for the `explain` command covering the three accepted input
   formats (`ERR_XXXX`, `err_xxxx`, bare integer), a known code, and an unknown code.
7. **Property tests** for gutter padding: for all `n` in `[1..9999]`, the output is
   exactly 4 characters.
8. **Exit-code tests**: mock-based tests verifying that declined confirmation prompts
   produce exit code 130 and that preprocessing errors produce exit code 1.
9. All tests use mock fixtures; no real AWS calls, no real network I/O.

## Cross-References

- `DIVERGENCES.md` — documents the stderr-vs-stdout TTY check divergence from Rust
- PRD-08: AWS Integration — covers ERR_8001–ERR_8005 in the configuration context
- PRD-06: Output System — `OdError` output event type and rendering
