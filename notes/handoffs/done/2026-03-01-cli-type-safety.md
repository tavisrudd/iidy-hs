# CLI Flag Type Safety -- Refactoring

**Status**: DONE
**Date**: 2026-03-01
**Session**: `00cdf3e0-e600-42b8-8b73-07f9dcd707ad`

## Context

Several CLI flags use raw `textReader` (returns `Text`) where a sum type with a custom
`ReadM` instance would be more type-safe. The project already has 6 custom ReadM instances
following the `eitherReader` pattern — extending this to the remaining text-typed flags
is straightforward.

## Flags to Convert

### `--type` for param-set (ParamSetArgs.psaType)

Currently `Text`, validated at runtime in `textToParameterType` (Client.hs:81-86).

**Target**: `ParameterType` sum type with ReadM.
```haskell
data ParamType = ParamString | ParamSecureString | ParamStringList

paramTypeReader :: ReadM ParamType
paramTypeReader = eitherReader $ \s -> case T.toLower (T.pack s) of
  "string"       -> Right ParamString
  "securestring" -> Right ParamSecureString
  "stringlist"   -> Right ParamStringList
  _              -> Left $ "Unknown parameter type: " <> s <> ". Expected: String|SecureString|StringList"
```

Then `textToParameterType` can be replaced by a direct pattern match on `ParamType`.

### `--format` for param commands (ParamGetArgs.pgaFormat, ParamGetByPathArgs.gpbFormat)

Currently `Text`. Used to select output format in Main.hs.

**Target**: `ParamFormat` sum type.
```haskell
data ParamFormat = ParamFormatRaw | ParamFormatJson | ParamFormatYaml
```

### `completion` shell argument

Currently `Maybe Text`. Valid values: bash, zsh, fish.

**Target**: `ShellType` sum type.
```haskell
data ShellType = ShellBash | ShellZsh | ShellFish
```

## Codebase Reference

| What              | Where                                       |
|-------------------|---------------------------------------------|
| textReader        | `src/Iidy/Cli/Parser.hs:585-586`           |
| Existing ReadMs   | `src/Iidy/Cli/Parser.hs:588-628`           |
| CLI arg types     | `src/Iidy/Cli.hs:226-237`                  |
| textToParameterType | `src/Iidy/Params/Client.hs:81-86`        |
| Callers in Main.hs | `app/Main.hs` (param commands)            |

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet — mechanical, follows existing pattern
- **Note**: Touch CLI types, parser, and callers. May change test expectations if any tests check format strings.

## Progress

- [ ] Add ParamType, ParamFormat, ShellType sum types to Cli.hs
- [ ] Add ReadM instances to Cli/Parser.hs
- [ ] Update ParamSetArgs, ParamGetArgs, ParamGetByPathArgs field types
- [ ] Update callers in Main.hs and Client.hs
- [ ] Remove textToParameterType (replaced by sum type)
- [ ] Build clean, all tests pass

## Handoff Notes

(to be filled by implementing session)

## Status Notes
Completed in commit 7a1a18f ("Add type-safe CLI flags for param type, format, and shell completion"). Follow-on in a4ab630 ("Replace stringly-typed OutputFormat with RenderFormat ADT").
