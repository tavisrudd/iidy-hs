# API Design Review: Rusty Russell Lens

_"Good APIs don't just prevent mistakes -- they make the right thing the only thing." -- Rusty Russell_

Russell's scale rates APIs from 1 (impossible to get wrong) to 10 (read the implementation).
His core question: **How hard is it for a reasonable person to use this correctly?**

---

## 1. mapOnFailure Silently Drops Invalid Values (Rating: 7/10)

```haskell
mapOnFailure :: Maybe Text -> Maybe CF.OnFailure
mapOnFailure Nothing = Nothing
mapOnFailure (Just t) = case T.toUpper t of
  "DELETE"     -> Just CF.OnFailure_DELETE
  "ROLLBACK"  -> Just CF.OnFailure_ROLLBACK
  "DO_NOTHING" -> Just CF.OnFailure_DO_NOTHING
  _            -> Nothing    -- <-- silently drops garbage
```

A user writes `OnFailure: rollbck` in their stack-args.yaml. The typo doesn't match any case.
`mapOnFailure` returns `Nothing`. CloudFormation applies its own default (ROLLBACK). The user
never learns their directive was ignored. The stack proceeds with behavior they did not intend.

The same pattern infects `mapCapabilities`:

```haskell
mapCapabilities (Just caps) =
  let mapped = catMaybes (map mapCapability caps)
  in if null mapped then Nothing else Just mapped
```

If a user writes `Capabilities: [CAPBILITY_IAM]`, the typo gets `catMaybes`-d into oblivion.
The stack creation might fail because IAM capabilities weren't asserted -- but the error message
from CloudFormation says "Requires capabilities: [CAPABILITY_IAM]", giving no indication that the
user *thought* they'd provided it.

**The problem:** Invalid enum values vanish without trace. The user's explicit intent is silently
discarded, replaced by a system default they may not know about.

**Russell rating:** 7 -- "The obvious use is wrong." The obvious thing is to pass what the
user wrote. The actual behavior is to quietly ignore what doesn't parse. A reasonable person
would assume their configuration is being applied.

**Fix:** Return `Either Text CF.OnFailure` and propagate the error. Or validate during
`StackArgsLoader` parsing (which is earlier and can produce a better error with file/line info).
Better still: use an ADT at the YAML parsing layer so the type system prevents the bad string
from ever entering the pipeline.

---

## 2. getStackName Falls Back to "unnamed-stack" (Rating: 9/10)

```haskell
getStackName :: StackArgs -> Text
getStackName args = fromMaybe "unnamed-stack" (saStackName args)
```

If a user forgets `StackName:` in their stack-args.yaml, iidy doesn't error. It creates a
CloudFormation stack literally named "unnamed-stack". In the user's AWS account. With their
money.

This function is called in every request builder:

```haskell
buildCreateStackRequest ctx args _ _ _ = do
  let sName = getStackName args   -- could be "unnamed-stack"
  -- ... proceeds to create the stack
```

The only way a user discovers this is by checking the AWS console and finding a stack named
"unnamed-stack" that they definitely didn't intend to create. If they run `create-or-update`
multiple times, they get updates to the same accidental stack.

**The problem:** A missing required field silently gets a default value that is never correct.
No user in the history of CloudFormation has wanted a stack named "unnamed-stack".

**Russell rating:** 9 -- "Read the manual or you'll get it wrong." Actually worse: reading
the manual won't save you if you make a typo in the YAML key name. `Stack_Name:` doesn't
match `StackName:`, so `saStackName` is `Nothing`, and off we go to unnamed-stack land.

**Fix:** `getStackName` should not exist. `saStackName` should be validated as non-empty in
`StackArgsLoader` before any operation proceeds. For operations that require a stack name
(which is all of them except lint-template and render), the absence of a stack name should be
an error, not a default.

---

## 3. getStrList Silently Drops Non-String Array Elements (Rating: 7/10)

```haskell
getStrList :: KM.KeyMap Value -> Text -> Maybe [Text]
getStrList obj key = case KM.lookup (Key.fromText key) obj of
  Just (Array arr) -> Just [t | String t <- foldr (:) [] arr]
  _                -> Nothing
```

That list comprehension with `String t <-` is a pattern match filter. It silently discards
any array element that isn't a string. A user writes:

```yaml
Capabilities:
  - CAPABILITY_IAM
  - 42
  - true
```

They get `Just ["CAPABILITY_IAM"]`. The number and boolean are silently dropped. No error.
No warning. The user sees three items in their YAML and assumes all three are applied.

Similarly, `NotificationARNs: [123456789]` (a number, not a string) produces `Just []`,
which effectively means "no notification ARNs." The user specified one and got zero.

**The problem:** Type coercion failure in a list is silent. A mixed-type array is common
when YAML 1.1 auto-resolves `true` to a boolean or `012` to an octal number.

**Russell rating:** 7 -- "The obvious use is wrong." A user writing items in a YAML list
naturally expects all items to be included. The filtering behavior is invisible.

**Fix:** Validate each element and error on non-strings. Or coerce non-strings to their
text representation (which is what the user probably intended). Either is better than
silent filtering.

---

## 4. StackArgs: The 21-Maybe Record With No Validation (Rating: 9/10)

```haskell
data StackArgs = StackArgs
  { saStackName                   :: !(Maybe Text)
  , saTemplate                    :: !(Maybe Text)
  , saDisableRollback             :: !(Maybe Bool)
  , saOnFailure                   :: !(Maybe Text)
  , saTimeoutInMinutes            :: !(Maybe Int)
  , saEnableTerminationProtection :: !(Maybe Bool)
  , ...  -- 21 fields, all Maybe
  }
```

Every field is `Maybe`. There is no validation that the right fields are present for the
operation being performed. `create-stack` without `saTemplate` and `saStackName` is
representable and not caught until the AWS API rejects the request -- with an error
message about the AWS API, not about your stack-args.yaml.

Worse: unknown YAML keys are silently ignored. `valueToStackArgs` only extracts known
keys from the `KM.KeyMap Value`. If a user writes `StackNme: my-stack` (typo), the key
doesn't match `StackName`, so `saStackName` is `Nothing`. Combined with finding #2 above,
the stack gets created as "unnamed-stack" because the user made a one-character typo.

**The problem:** The type admits every combination of present/absent fields, and no code
validates that the combination makes sense for the operation at hand. Unknown keys are
never flagged.

**Russell rating:** 9 -- "Read the manual or you'll get it wrong." But even reading the
manual doesn't help with typos. The system must validate, and it doesn't.

**Fix:** Two changes. First: reject unknown keys in `valueToStackArgs` by comparing
the parsed object's keys against a known set. Second: per-operation validation --
`create-stack` requires at least `StackName` and `Template`; `delete-stack` requires
`StackName`.

---

## 5. oIsTruthy: JavaScript-Grade Truthiness in a YAML Preprocessor (Rating: 6/10)

```haskell
oIsTruthy :: OValue -> Bool
oIsTruthy = \case
  ONull     -> False
  OBool b   -> b
  OString s -> not (T.null s)
  ONumber n -> n /= 0
  OArray a  -> not (null a)
  OObject o -> not (null o)
```

This is used by `!$if` and `!$not` and `!$map` filter expressions. It defines truthiness
for every OValue type. The user writes:

```yaml
!$if:
  test: !$ item_count
  then: "has items"
  else: "no items"
```

If `item_count` is `0`, the `else` branch fires. If `item_count` is `"0"`, the `then`
branch fires (non-empty string is truthy). If `item_count` is `0.0`, the `else` branch
fires. If `item_count` is `false`, the `else` branch fires.

This is JavaScript-style implicit truthiness. Mixing it with YAML 1.1's auto-boolean
resolution (where `yes`, `on`, `True` all become `OBool True`) creates a combinatorial
explosion of surprising behavior. The string `"no"` is truthy (non-empty string). The
YAML bareword `no` is falsy (YAML 1.1 resolves it to `OBool False`).

**The problem:** Truthiness rules are undocumented and interact badly with YAML 1.1
type resolution. The behavior of `!$if` depends on which YAML spec version is active
and whether the user quoted their value.

**Russell rating:** 6 -- "The name tells you nothing." `oIsTruthy` operates on all
six value types. The user must understand both YAML's type resolution rules AND the
truthiness table to predict what `!$if` will do with their value.

**Fix:** At minimum, document the truthiness table prominently. Better: restrict
`!$if test:` to boolean values and error on non-booleans, forcing the user to be
explicit. (This would be a behavior change from Rust, but it's the right thing.)

---

## 6. TemplateLoader Uses `fail` for Errors (Rating: 10/10)

```haskell
loadCfnTemplate (Just tmplSpec) argsfilePath env mAwsEnv
  | Just renderPath <- T.stripPrefix "render:" tmplSpec = do
      -- ...
      case parseYaml rawContent baseLocation of
        Left (ParseError _pos msg) ->
          fail $ "Parse error in rendered template ..."
        Right ast -> do
          result <- preprocessYaml11 ...
          case result of
            Left err ->
              fail $ "Preprocess error in rendered template ..."
```

`fail` in IO throws an `IOError` (specifically, `userError`). This exception propagates
up the call stack and is caught by `Main.hs`'s top-level `handleUncaughtException`:

```haskell
handleUncaughtException :: SomeException -> IO ()
handleUncaughtException e
  | Just ioe <- fromException e = do
      let msg = displayException (ioe :: IOException)
      hPutStrLn stderr $ "ERROR: " <> firstLine msg
      hPutStrLn stderr "  * Check the AWS CloudFormation console for more details"
```

A YAML parse error in the user's template produces the message: "Check the AWS CloudFormation
console for more details." The template never touched CloudFormation. The CloudFormation
console has nothing to check. The user is told to look somewhere that has no relevant
information.

Meanwhile, the *same* category of error in `StackArgsLoader` is handled with
`Either Text` and produces a clean, context-rich error message. Two modules, two error
mechanisms, two user experiences for the same kind of mistake.

**The problem:** `fail` throws an exception type that the top-level handler cannot
distinguish from an actual IO failure. The error message given to the user is wrong.

**Russell rating:** 10 -- "Read the implementation or you'll get it wrong." You'd have
to trace the exception through three modules (TemplateLoader -> Main.handleUncaughtException)
to understand why a YAML parse error suggests checking the CloudFormation console.

**Fix:** `loadCfnTemplate` should return `Either Text TemplateResult`, matching
`loadStackArgs`. The caller in `RequestBuilder` should propagate the error. The top-level
handler in Main.hs should never see template loading errors as IOExceptions.

---

## 7. GlobalConfig Silently Swallows All Errors (Rating: 7/10)

```haskell
applyGlobalConfiguration :: Amazonka.Env -> StackArgs -> IO StackArgs
applyGlobalConfiguration awsEnv stackArgs = do
  result <- try @SomeException (fetchParametersByPath awsEnv "/iidy/")
  case result of
    Left _ex ->
      -- Silently continue -- missing permissions or SSM unavailable
      pure stackArgs
    Right params ->
      applyParams stackArgs params
```

If SSM is misconfigured, or permissions are wrong, or the network is down, or the
parameter path has a typo, or the response is malformed -- all produce the same result:
silence. The user's global notification ARN or template approval override isn't applied,
and they have no way to know.

The comment says "Silently continue -- missing permissions or SSM unavailable." But
`SomeException` catches everything. If `applyParams` throws a `PatternMatchError` due to
a code bug, that's also silently swallowed. If `fetchParametersByPath` encounters a
`ThreadKilled` async exception, that's swallowed too. The error boundary is too wide.

**The problem:** A `catch-all` makes debugging impossible. When global config silently
doesn't apply and the user's stack creation fails for lack of notification ARNs, the
actual cause (SSM permission error) is invisible.

**Russell rating:** 7 -- "The obvious use is wrong." A user who configures
`/iidy/default-notification-arn` in SSM reasonably expects it to be applied. When it
silently isn't, they debug the wrong thing.

**Fix:** Narrow the catch to `Amazonka.Error`. Log a warning to stderr when SSM is
unreachable ("Warning: could not load global config from SSM: <reason>"). Never catch
`SomeException` -- it catches async exceptions like `ThreadKilled` and `StackOverflow`,
which must propagate.

---

## 8. Terminal Statuses Are Stringly Typed (Rating: 7/10)

```haskell
allTerminalStatuses :: [Text]
allTerminalStatuses =
  [ "CREATE_COMPLETE", "CREATE_FAILED"
  , "DELETE_COMPLETE", "DELETE_FAILED"
  , ...
  ]
```

Every comparison of stack status is a string equality check:

```haskell
if currentStatus `elem` terminalStatuses
```

Amazonka provides `CF.StackStatus` as a proper sum type. But the codebase converts it to
`Text` at the boundary (`CF.fromStackStatus`) and then works with strings throughout.
The comment in `Context.hs` documents 14 terminal statuses, with careful notes about
`UPDATE_FAILED` being excluded. This comment is the only thing preventing a typo in the
string list from causing incorrect polling behavior.

If someone adds `"UPATE_ROLLBACK_COMPLETE"` (missing a D), the poller never terminates
for update rollbacks. The compiler won't help. The test suite might not catch it unless
there's a test exercising that specific transition. The bug would manifest as a CI job
that hangs forever.

**The problem:** The compiler cannot verify completeness or correctness of status string
sets. The domain's state machine is implicit in scattered `elem` checks against hand-typed
string literals.

**Russell rating:** 7 -- "The obvious use is wrong." The obvious thing to do when
Amazonka gives you a `StackStatus` sum type is to keep it as a sum type. Converting to
`Text` immediately throws away the type safety that the library provides.

**Fix:** Keep `CF.StackStatus` (or a project-local mirror type) throughout the pipeline.
Pattern match instead of `elem`. The compiler enforces exhaustiveness. Every status list
change becomes a compile error, not a runtime hang.

---

## 9. PollConfig: Eight Callbacks, No Types (Rating: 6/10)

```haskell
data PollConfig = PollConfig
  { pcIntervalSeconds       :: !Int
  , pcTimeoutSeconds        :: !(Maybe Int)
  , pcInactivityTimeoutSecs :: !(Maybe Int)
  , pcStartTime             :: !(Maybe UTCTime)
  , pcWaitForStatusChange   :: !Bool
  , pcOnNewEvents           :: [CF.StackEvent] -> IO ()
  , pcOnOperationComplete   :: OperationCompleteInfo -> IO ()
  , pcOnInactivityTimeout   :: InactivityTimeoutInfo -> IO ()
  , pcOnPollTick            :: IO ()
  }
```

Every callback defaults to `const (pure ())`:

```haskell
defaultPollConfig = PollConfig
  { pcOnNewEvents         = const (pure ())
  , pcOnOperationComplete = const (pure ())
  , pcOnInactivityTimeout = const (pure ())
  , pcOnPollTick          = pure ()
  , ...
  }
```

A caller constructs a PollConfig by starting from `defaultPollConfig` and overriding the
callbacks they care about. If they forget `pcOnOperationComplete`, the operation completes
silently. If they forget `pcOnNewEvents`, events are fetched and discarded. The type system
does not indicate which callbacks are mandatory for correct operation.

The `pcWaitForStatusChange` boolean interacts with `pcInactivityTimeoutSecs` in a way that
requires reading the polling loop implementation to understand:

```haskell
case pcInactivityTimeoutSecs config of
  Just timeout | timeout > 0 && null newEvents && inactivityElapsed > timeout
               , not (pcWaitForStatusChange config) || hasSeenNewEvents -> ...
```

That conditional has three nested guards and a short-circuit on `pcWaitForStatusChange`.
The interaction between "wait for status change" and "inactivity timeout" is an implicit
semantic coupling that the types don't capture.

**The problem:** The record of callbacks has no contract about which ones matter. The
boolean flag alters timeout semantics in a way only the implementation reveals.

**Russell rating:** 6 -- "The name tells you nothing." `pcWaitForStatusChange` tells you
vaguely what it does but not how it changes timeout behavior. You have to read the polling
loop to know that it suppresses inactivity timeout until at least one event has been seen.

**Fix:** Split PollConfig into a "configuration" half (intervals, timeouts) and a
"handler" half (callbacks). Make the handler a proper interface (record of functions or
typeclass) where the caller must provide all callbacks. Remove the boolean flag and
instead have two constructors: `WatchPollConfig` (waits for events) and
`OperationPollConfig` (doesn't wait).

---

## 10. Unknown YAML Keys in stack-args.yaml Are Silently Ignored (Rating: 8/10)

```haskell
valueToStackArgs :: Value -> Either Text StackArgs
valueToStackArgs (Object obj) = do
  tags   <- getStrMapValidated obj "Tags"
  params <- getStrMapValidated obj "Parameters"
  pure StackArgs
    { saStackName  = getStr obj "StackName"
    , saTemplate   = getStr obj "Template"
    , ...
    }
valueToStackArgs _ = Left "Stack args must be a YAML mapping"
```

This function extracts known keys. Unknown keys are not detected. A user writes:

```yaml
StakName: my-stack      # typo: StakName instead of StackName
Template: render:cfn.yaml
Capabilties:            # typo: missing 'i'
  - CAPABILITY_IAM
```

Both typos silently pass. `saStackName` is `Nothing` (falls back to "unnamed-stack").
`saCapabilities` is `Nothing` (no capabilities asserted). The user's stack creation
either creates a stack with the wrong name or fails because capabilities weren't provided,
with an error message from AWS that doesn't mention the typo.

This interacts with finding #2 (unnamed-stack default) and #4 (no required-field validation)
to create a cascade where a single typo in a YAML key can cause an operation to silently do
the wrong thing.

**The problem:** The parser is permissive in a context where strictness prevents errors.
YAML keys are identifiers. Identifiers that don't match anything should be flagged.

**Russell rating:** 8 -- "The compiler/type system won't let you get it right." Actually
the compiler is fine -- the *parser* won't let you get it right. It accepts anything and
silently ignores what it doesn't understand.

**Fix:** Collect the known keys into a `Set`. Compare against the actual keys in the
parsed object. Error on any key not in the known set (with a "did you mean?" suggestion
using edit distance). This is how every good configuration parser works.

---

## 11. applyDotQueryValidated Returns ONull on Path Miss (Rating: 7/10)

```haskell
applyDotQueryValidated :: SrcMeta -> Text -> Text -> OValue -> Resolve OValue
applyDotQueryValidated meta varPath q val
  | T.isInfixOf "," q = ...  -- comma case validates
  | otherwise =
      let segments = filter (not . T.null) (T.splitOn "." q)
      in pure $ case traversePathO segments val of
           Just v  -> v
           Nothing -> ONull     -- <-- silently returns null
```

When a user does `!$ config.database.host` and `database` exists but `host` doesn't, the
result is `ONull`. No error. No warning. The user's CloudFormation template gets `null`
where they expected a string, and CloudFormation rejects it with an error about an
invalid property value -- at deploy time, potentially minutes after the template was
preprocessed.

Note the asymmetry: the comma-separated path (`!$ config.{host,port}`) validates that
every key exists and errors on missing ones. But the dot-path (`!$ config.host`) silently
returns null. Same conceptual operation, two different error behaviors.

**The problem:** A missing property in a dot-path query silently produces null instead
of erroring. The user gets a confusing CloudFormation error instead of a clear
preprocessing error.

**Russell rating:** 7 -- "The obvious use is wrong." The obvious expectation when
traversing `config.database.host` is that you get the host or an error. Getting `null`
silently is a debugging trap.

**Fix:** Return an error when `traversePathO` returns `Nothing` in the single-key
dot-path case, matching the comma-separated behavior. Both paths should be strict.

---

## 12. Two Incompatible Error Presentation Paths (Rating: 6/10)

YAML preprocessing errors go through the enhanced error display pipeline:

```haskell
formatPreprocessErrorEnhanced :: ColorChoice -> Text -> Text -> PreprocessError -> IO Text
```

This produces beautiful, Rust-compatible error output with source context, carets,
colored headers, error IDs, and "For more info: iidy explain ERR_XXXX" footers.

But template loading errors go through `fail`:

```haskell
fail $ "Parse error in rendered template " <> ...
```

Which surfaces as:

```
ERROR: user error (Parse error in rendered template ...)
  * Check the AWS CloudFormation console for more details
```

And AWS API errors go through yet another path:

```haskell
handleAwsError (Amazonka.ServiceError se) = do
  hPutStrLn stderr $ "ERROR: " <> errMsg
  hPutStrLn stderr "  * Check the AWS CloudFormation console for more details"
```

A user encounters three different error presentation styles depending on which
module triggered the error: enhanced display (preprocessing), bare text (template
loading), or AWS error format (API calls). The `handleUncaughtException` path
appends a CloudFormation console suggestion to *every* error, including ones that
have nothing to do with CloudFormation.

**The problem:** Three error presentation styles, no consistent format, and a
generic "check the console" message that's wrong half the time.

**Russell rating:** 6 -- "The name tells you nothing." The user cannot predict
what an error will look like or what actionable information it will contain.

**Fix:** Route all errors through a single formatting function. Differentiate
the "check the console" hint -- only emit it for actual AWS API errors. Give
template loading errors the same enhanced display treatment as preprocessing
errors (they're literally the same kind of error, just from a different module).

---

## 13. The --environment Default Is "development" (Rating: 5/10)

```haskell
globalOptsParser :: Parser GlobalOpts
globalOptsParser = GlobalOpts
  <$> option textReader
      ( long "environment"
      <> short 'e'
      <> value "development"
      <> ...
      )
```

If a user forgets `--environment production`, they deploy to development. This is a
defensible default (development is the safer failure mode). But it interacts with
environment maps:

```yaml
Region:
  development: us-east-1
  production: eu-west-1
```

If the user is deploying to production and forgets `-e production`, the stack goes to
`us-east-1` instead of `eu-west-1`. The user's production stack ends up in the wrong
region. Silently.

There is no warning when the environment changes operational parameters (region, profile,
role ARN). The command metadata at the top of output shows the environment, but a user
running a familiar command might not read it.

**The problem:** A default that silently selects a different region/profile is dangerous.
"Safe default" and "silent default for a parameter that changes where infrastructure is
deployed" are different things.

**Russell rating:** 5 -- "Do it right or it breaks at runtime." The user must remember
to pass `--environment` for every command that touches a non-development environment.
Forgetting is a runtime error (wrong region), not a compile-time or parse-time error.

**Fix:** Require `--environment` for write operations (create, update, delete). Only
default to "development" for read-only operations (describe, list, render). Or: if
the stack-args.yaml has environment-specific maps, require `--environment` to be specified
explicitly (error if it's missing rather than defaulting).

---

## 14. oValuesEqual Is a Lie (Rating: 4/10)

```haskell
oValuesEqual :: OValue -> OValue -> Bool
oValuesEqual (ONumber a) (ONumber b) = a == b
oValuesEqual a b = a == b
```

This function claims to be a custom equality check but does exactly the same thing as
`(==)` from the `Eq` instance. The `ONumber` case uses `Scientific`'s `Eq` instance,
which is also what the derived `Eq` instance does. The function is not wrong, but it's
misleading -- it suggests there's something special about number comparison that the
derived instance doesn't handle.

It's used by `!$eq`:

```haskell
resolveEq ctx _meta (EqTag left right) = do
  l <- resolveAst ctx left
  r <- resolveAst ctx right
  pure $ OBool (oValuesEqual l r)
```

A user writing `!$eq [1, "1"]` gets `False` because `ONumber 1` and `OString "1"` are
different constructors. This might surprise someone coming from JavaScript or loosely-typed
YAML where `1` and `"1"` are interchangeable. But the behavior is actually correct -- strict
equality is the right choice for a typed value comparison. The function just has a misleading
name that suggests it does something non-obvious.

**The problem:** A function that looks like a custom comparison but is just `(==)` with
extra steps. Not a bug, but a source of confusion for future readers.

**Russell rating:** 4 -- "The name tells you how to use it." The name says "equal" and
it does equality. Fine. But the existence of a separate function (rather than using `==`
directly) implies there's a reason for it, and there isn't.

**Fix:** Delete `oValuesEqual` and use `(==)` directly. If cross-type comparison is
desired in the future, add it then with a clear name like `oValuesCoerce`.

---

## 15. CLI --format Has Three Different Domains (Rating: 6/10)

```haskell
data TemplateFormat = FormatJson | FormatYaml | FormatOriginal
data RenderFormat   = RenderJson | RenderYaml | RenderCfnYaml
data ParamFormat    = ParamFormatRaw | ParamFormatJson | ParamFormatYaml
```

The `--format` flag on different commands accepts different values:

| Command              | Valid values                    | Default    |
|----------------------|---------------------------------|------------|
| get-stack-template   | json, yaml, original            | original   |
| render               | json, yaml, yaml-cloudformation | yaml       |
| get-import           | json, yaml                      | yaml       |
| param get            | raw, json, yaml                 | raw        |

All four use `--format`. The flag name is the same, but the valid values change per
command. A user who learns `--format yaml-cloudformation` from `render` and tries it on
`get-import` gets an error. A user who uses `--format raw` on `param get` and tries it
on `render` gets an error.

The types are separate (good -- the compiler prevents confusion internally). But the
user-facing interface reuses `--format` for four different value domains.

**The problem:** Same flag name, different valid values across commands. The user must
consult per-command help to know which formats are valid.

**Russell rating:** 6 -- "The name tells you nothing." `--format` tells you that you're
specifying a format, but not which formats are valid. You need `--help` for each command.

**Fix:** Use command-specific flag names where the valid set differs: `--template-format`,
`--render-format`, `--param-format`. Or: unify the format domain so all commands accept
the same set (where inapplicable formats are no-ops or aliased). The former is more
explicit; the latter is more ergonomic.

---

## 16. Error Classification via String Matching (Rating: 8/10)

```haskell
classifyMessage' :: [Text] -> SourceLocation -> Text -> EnhancedPreprocessingError
classifyMessage' allLines loc msg
  | "' is not a valid iidy tag" `T.isSuffixOf` msg = ...
  | "unexpected field '" `T.isPrefixOf` msg = ...
  | "'query' and 'jmespath' are mutually exclusive" == msg = ...
  | "property '" `T.isPrefixOf` msg && "' not found in mapping" `T.isInfixOf` msg = ...
  | isCfnValidationMessage msg = ...
  | "Variable not found: " `T.isPrefixOf` msg = ...
  | "' missing in " `T.isInfixOf` msg = ...
  | "must be a mapping" `T.isPrefixOf` msg = ...
  | "expected " `T.isPrefixOf` msg && ", found " `T.isInfixOf` msg = ...
  | ...
```

This is a 200+ line function that classifies errors by pattern-matching on their message
text. If a resolver changes its error message wording -- say, from "Variable not found:"
to "Unknown variable:" -- the classification silently falls through to the generic
`TagParsingError` catch-all. The enhanced error display degrades from a helpful
"variable error" with available variables to a bare "Tag error" with no context.

To be fair: the module also has a `classifyResolveError` path that uses the structured
`ResolveErrorKind` type. The string matching is the fallback for `REGeneric` and for
parse errors from HsYAML. But the fallback handles a significant number of real error
paths, and those paths are coupled to the exact wording of error messages produced by
other modules.

**The problem:** Error classification depends on the exact text of error messages
produced by separate modules. Changing an error message in one module silently breaks
error display in another. There is no test that catches this regression (beyond the
snapshot tests, which test specific fixtures).

**Russell rating:** 8 -- "The compiler/type system won't let you get it right." The
compiler cannot tell you that changing a message in `Resolver.hs` breaks a pattern
match in `Conversion.hs`. You'd need to read the implementation of both to understand
the coupling.

**Fix:** Extend `ResolveErrorKind` to cover all cases currently handled by string
matching. Make `REGeneric` carry a sub-classification enum rather than falling through
to string matching. For HsYAML parse errors, wrap them in a structured type at the
parser boundary rather than classifying them by message text downstream.

---

## Summary

| #  | Finding                                                | Rating | Scale Description                                  |
|----|--------------------------------------------------------|--------|----------------------------------------------------|
| 2  | getStackName falls back to "unnamed-stack"             | 9      | Read the manual or you'll get it wrong              |
| 4  | StackArgs: 21-Maybe bag, no validation, no unknown-key | 9      | Read the manual or you'll get it wrong              |
| 6  | TemplateLoader uses `fail` for recoverable errors      | 10     | Read the implementation or you'll get it wrong      |
| 10 | Unknown YAML keys silently ignored                     | 8      | The compiler/type system won't let you get it right |
| 16 | Error classification via string matching               | 8      | The compiler/type system won't let you get it right |
| 1  | mapOnFailure silently drops invalid values             | 7      | The obvious use is wrong                            |
| 3  | getStrList silently drops non-string elements           | 7      | The obvious use is wrong                            |
| 7  | GlobalConfig silently swallows all errors               | 7      | The obvious use is wrong                            |
| 8  | Terminal statuses are stringly typed                    | 7      | The obvious use is wrong                            |
| 11 | Dot-path query returns ONull on miss                   | 7      | The obvious use is wrong                            |
| 5  | oIsTruthy: JavaScript-grade truthiness                 | 6      | The name tells you nothing                          |
| 9  | PollConfig: 8 callbacks, no contracts                  | 6      | The name tells you nothing                          |
| 12 | Three incompatible error presentation paths            | 6      | The name tells you nothing                          |
| 15 | --format has three different value domains              | 6      | The name tells you nothing                          |
| 13 | --environment defaults to "development"                | 5      | Do it right or it breaks at runtime                 |
| 14 | oValuesEqual is just (==)                              | 4      | The name tells you how to use it                    |

---

## What's Actually Good

Rusty doesn't just complain. Credit where it's earned.

- **ResolveErrorKind is a proper sum type** (rating: 2). When it's used, the compiler
  forces you to handle every error variant. The `classifyResolveError` path that uses it
  is excellent API design. The problem is the fallback path, not the primary one.

- **CLI types are pure ADTs** (rating: 2). `Commands`, `StackFileArgs`, `RenderArgs` --
  all proper types, no strings, no dynamic dispatch. The optparse-applicative parser
  produces values that the compiler guarantees are well-formed. You literally cannot
  construct a `CreateStackArgs` missing the argsfile path.

- **The format reader functions reject invalid input** (rating: 3). `colorChoiceReader`,
  `themeReader`, `outputModeReader` -- these all return `Left` with a helpful error
  message on invalid input. The CLI layer does the right thing. The StackArgs layer does
  not.

- **resolveAst is pure** (rating: 2). The core resolver takes a `TagContext` and a
  `YamlAst` and returns `Either ResolveError OValue`. No IO, no mutation, no callbacks.
  The type signature tells you everything. This is level 2 on the scale.

- **CloudFormation tag validation is thorough** (rating: 3). `validateCfnTag` checks
  every intrinsic function's argument structure and produces specific error messages.
  `!Ref` with a null value, `!Sub` with wrong array length, `!GetAtt` without dot
  notation -- all caught with clear messages. The obvious use is correct.

The pattern: the pure core (resolver, CLI types, tag validation) is level 2-3 on the
scale. The IO boundaries (StackArgsLoader, TemplateLoader, GlobalConfig, RequestBuilder)
are level 6-10. The quality of the API design drops sharply when you cross from pure
code to effectful code. That's the systemic issue. Fix the boundaries.
