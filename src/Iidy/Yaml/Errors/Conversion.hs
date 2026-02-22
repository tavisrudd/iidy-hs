-- | Convert raw PreprocessError into formatted enhanced error text.
-- Pattern-matches on error message text to classify errors and produce
-- the Rust-compatible enhanced error format.
module Iidy.Yaml.Errors.Conversion
  ( formatPreprocessErrorEnhanced
  , formatParseErrorEnhanced
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import System.IO (hIsTerminalDevice, stderr)

import Iidy.Yaml.Engine (PreprocessError(..))
import Iidy.Yaml.Errors.Display (formatError, defaultColors, noColors)
import Iidy.Yaml.Errors.Enhanced
import Iidy.Yaml.Errors.Ids
import Iidy.Yaml.Handlebars.Engine (InterpolateError(..))
import Iidy.Yaml.Imports.Types (ImportError(..))
import Iidy.Yaml.Location (Position(..), SourceLocation(..))
import Iidy.Yaml.Resolution.Resolver (ResolveError(..))

-- | Format a PreprocessError with enhanced display (matching Rust output format).
formatPreprocessErrorEnhanced :: Text -> Text -> PreprocessError -> IO Text
formatPreprocessErrorEnhanced filePath source err = do
  isTty <- hIsTerminalDevice stderr
  let colors = if isTty then defaultColors else noColors
  let enhanced = convertToEnhanced filePath source err
  pure $ formatError colors source enhanced

-- | Format a ParseError with enhanced display.
formatParseErrorEnhanced :: Text -> Text -> Position -> Text -> IO Text
formatParseErrorEnhanced filePath source pos msg = do
  isTty <- hIsTerminalDevice stderr
  let colors = if isTty then defaultColors else noColors
      loc = posToSourceLocation filePath pos
      adjustedLoc = adjustLocationForTag source loc msg
      enhanced = classifyMessage adjustedLoc msg
  pure $ formatError colors source enhanced

-- | Convert PreprocessError to EnhancedPreprocessingError.
convertToEnhanced :: Text -> Text -> PreprocessError -> EnhancedPreprocessingError
convertToEnhanced filePath source = \case
  PeResolveError re -> classifyResolveError filePath source re
  PeImportError ie  -> classifyImportError filePath ie
  PeHandlebarsError (InterpolateError msg) -> classifyHandlebarsError filePath msg
  PeCycleError msg  -> YamlSyntaxError YamlSyntaxInfo
    { ysiErrorId      = ImportCircularDependency
    , ysiShortMessage = msg
    , ysiGuidance     = "circular import detected"
    , ysiLocation     = SourceLocation filePath 0 0 ""
    , ysiFixHint      = Nothing
    , ysiExample      = Nothing
    }

-- | Classify a ResolveError by pattern-matching on its message text.
-- Adjusts position to point at the tag (not value) by searching the source.
classifyResolveError :: Text -> Text -> ResolveError -> EnhancedPreprocessingError
classifyResolveError filePath source (ResolveError pos msg) =
  let loc = posToSourceLocation filePath pos
      -- Try to find the tag in the source and fix the position
      adjustedLoc = adjustLocationForTag source loc msg
  in classifyMessage adjustedLoc msg

-- | Pattern-match on error message to determine error type and produce
-- the appropriate EnhancedPreprocessingError variant.
classifyMessage :: SourceLocation -> Text -> EnhancedPreprocessingError
classifyMessage loc msg

  -- Variable not found: "Variable not found: path. Available: x, y"
  | "Variable not found: " `T.isPrefixOf` msg =
      let rest = T.drop (T.length "Variable not found: ") msg
          (varPath, avail) = T.breakOn ". Available: " rest
          availVars = if T.null avail
                      then []
                      else T.splitOn ", " (T.drop (T.length ". Available: ") avail)
      in VariableNotFoundError VariableNotFoundInfo
        { vnfErrorId       = VariableNotFound
        , vnfVariable      = varPath
        , vnfLocation      = loc
        , vnfAvailableVars = availVars
        , vnfSuggestions   = []
        }

  -- Missing field: "'field' missing in !$tag tag" (ERR_4002)
  | "' missing in " `T.isInfixOf` msg =
      let -- Extract field name: text before "' missing in"
          (fieldQuoted, rest) = T.breakOn "' missing in " msg
          field = T.drop 1 fieldQuoted  -- drop leading '
          -- Extract tag name: text after "' missing in "
          tagPart = T.drop (T.length "' missing in ") rest
          tagName = T.strip (T.takeWhile (/= ' ') tagPart)
      in TagParsingError TagParsingInfo
        { tpiErrorId     = MissingRequiredTagField
        , tpiTagName     = tagName
        , tpiMessage     = msg
        , tpiGuidance    = Just ("add '" <> field <> "' field to " <> tagName <> " tag")
        , tpiLocation    = loc
        , tpiSuggestion  = Just $ tagExample tagName
        , tpiCaretColumn = 0
        , tpiSpanLen     = 0
        }

  -- Missing required 'in' field (ERR_4002 for !$let)
  | "missing required 'in' field" == msg =
      TagParsingError TagParsingInfo
        { tpiErrorId     = MissingRequiredTagField
        , tpiTagName     = "!$let"
        , tpiMessage     = msg
        , tpiGuidance    = Just "add 'in' field containing the expression to evaluate"
        , tpiLocation    = loc
        , tpiSuggestion  = Just $ tagExample "!$let"
        , tpiCaretColumn = 0
        , tpiSpanLen     = 0
        }

  -- "must be a mapping ..." (ERR_4003)
  | "must be a mapping" `T.isPrefixOf` msg =
      let guidance = extractMustBeGuidance msg
      in TagParsingError TagParsingInfo
        { tpiErrorId     = InvalidTagFieldValue
        , tpiTagName     = ""
        , tpiMessage     = msg
        , tpiGuidance    = Just guidance
        , tpiLocation    = loc
        , tpiSuggestion  = guessExampleFromMustBe msg
        , tpiCaretColumn = 0
        , tpiSpanLen     = 0
        }

  -- "must be a sequence ..." (ERR_4003)
  | "must be a sequence" `T.isPrefixOf` msg =
      let guidance = extractMustBeGuidance msg
      in TagParsingError TagParsingInfo
        { tpiErrorId     = InvalidTagFieldValue
        , tpiTagName     = ""
        , tpiMessage     = msg
        , tpiGuidance    = Just guidance
        , tpiLocation    = loc
        , tpiSuggestion  = guessExampleFromMustBe msg
        , tpiCaretColumn = 0
        , tpiSpanLen     = 0
        }

  -- "must have exactly 2 elements to compare" (ERR_4003 for !$eq)
  | "must have exactly" `T.isPrefixOf` msg =
      TagParsingError TagParsingInfo
        { tpiErrorId     = InvalidTagFieldValue
        , tpiTagName     = "!$eq"
        , tpiMessage     = msg
        , tpiGuidance    = Just "use format: [value1, value2]"
        , tpiLocation    = loc
        , tpiSuggestion  = Just $ tagExample "!$eq"
        , tpiCaretColumn = 0
        , tpiSpanLen     = 0
        }

  -- "invalid format - must be string variable name" (ERR_4005)
  | "invalid format" `T.isPrefixOf` msg =
      TagParsingError TagParsingInfo
        { tpiErrorId     = TagSyntaxError
        , tpiTagName     = "!$"
        , tpiMessage     = msg
        , tpiGuidance    = Just "use string variable name"
        , tpiLocation    = loc
        , tpiSuggestion  = Just "!$ variable_name"
        , tpiCaretColumn = 0
        , tpiSpanLen     = 0
        }

  -- Runtime type mismatches from resolver (ERR_5001)
  -- "expected X, found Y" format (Rust-compatible messages from resolver)
  | "expected " `T.isPrefixOf` msg && ", found " `T.isInfixOf` msg =
      let (expPart, rest) = T.breakOn ", found " msg
          expected = T.drop (T.length "expected ") expPart
          found = T.drop (T.length ", found ") rest
      in TypeMismatchError TypeMismatchInfo
        { tmiErrorId  = TypeMismatchInOperation
        , tmiExpected = expected
        , tmiFound    = found
        , tmiLocation = loc
        , tmiContext  = msg
        , tmiHelp     = generateTypeConversionHelp expected found
        }

  -- Legacy resolver type mismatch messages (for backwards compat)
  | ("!$map items must be" `T.isPrefixOf` msg) ||
    ("!$merge: all sources" `T.isPrefixOf` msg) ||
    ("!$split requires string" `T.isPrefixOf` msg) ||
    ("!$join requires" `T.isPrefixOf` msg) ||
    ("!$mapValues items must" `T.isPrefixOf` msg) ||
    ("!$groupBy items must" `T.isPrefixOf` msg) ||
    ("!$fromPairs requires a sequence" `T.isPrefixOf` msg) ||
    ("!$fromPairs:" `T.isPrefixOf` msg) ||
    ("!$concatMap:" `T.isPrefixOf` msg) ||
    ("!$mergeMap:" `T.isPrefixOf` msg) ||
    ("!$mapListToHash:" `T.isPrefixOf` msg) ||
    ("!$parseYaml requires" `T.isPrefixOf` msg) ||
    ("!$parseJson requires" `T.isPrefixOf` msg) =
      TypeMismatchError TypeMismatchInfo
        { tmiErrorId  = TypeMismatchInOperation
        , tmiExpected = extractExpected msg
        , tmiFound    = extractFound msg
        , tmiLocation = loc
        , tmiContext  = msg
        , tmiHelp     = Nothing
        }

  -- JMESPath errors
  | "JMESPath error: " `T.isPrefixOf` msg =
      LookupQueryError LookupQueryInfo
        { lqiErrorId       = LookupQueryFailed
        , lqiVariablePath  = ""
        , lqiMessage       = msg
        , lqiLocation      = loc
        , lqiAvailableKeys = []
        }

  -- Handlebars errors
  | "Handlebars error: " `T.isPrefixOf` msg =
      let detail = T.drop (T.length "Handlebars error: ") msg
      in YamlSyntaxError YamlSyntaxInfo
        { ysiErrorId      = HandlebarsSyntaxError
        , ysiShortMessage = detail
        , ysiGuidance     = "template syntax error"
        , ysiLocation     = loc
        , ysiFixHint      = Nothing
        , ysiExample      = Nothing
        }

  -- Parse errors from !$parseYaml, !$parseJson, !$expand
  | "!$parseYaml: " `T.isPrefixOf` msg || "!$parseJson: " `T.isPrefixOf` msg ||
    "!$expand parse error: " `T.isPrefixOf` msg ||
    "!$expand: template '" `T.isPrefixOf` msg =
      YamlSyntaxError YamlSyntaxInfo
        { ysiErrorId      = InvalidYamlSyntax
        , ysiShortMessage = msg
        , ysiGuidance     = "parsing failed"
        , ysiLocation     = loc
        , ysiFixHint      = Nothing
        , ysiExample      = Nothing
        }

  -- YAML syntax: "invalid YAML structure" / "unexpected end of file"
  | "invalid YAML" `T.isPrefixOf` msg =
      YamlSyntaxError YamlSyntaxInfo
        { ysiErrorId      = InvalidYamlSyntax
        , ysiShortMessage = msg
        , ysiGuidance     = "tags cannot be chained - use list syntax"
        , ysiLocation     = loc
        , ysiFixHint      = Just "put the inner tag in a list to separate it from the outer tag"
        , ysiExample      = Just "!$not [!$eq [\"a\", \"b\"]]"
        }

  | "unexpected end" `T.isPrefixOf` msg =
      YamlSyntaxError YamlSyntaxInfo
        { ysiErrorId      = InvalidYamlSyntax
        , ysiShortMessage = msg
        , ysiGuidance     = "missing closing quote or bracket"
        , ysiLocation     = loc
        , ysiFixHint      = Nothing
        , ysiExample      = Nothing
        }

  -- Fallback: treat as generic tag error
  | otherwise =
      TagParsingError TagParsingInfo
        { tpiErrorId     = TagSyntaxError
        , tpiTagName     = ""
        , tpiMessage     = msg
        , tpiGuidance    = Nothing
        , tpiLocation    = loc
        , tpiSuggestion  = Nothing
        , tpiCaretColumn = 0
        , tpiSpanLen     = 0
        }

-- | Classify import errors.
classifyImportError :: Text -> ImportError -> EnhancedPreprocessingError
classifyImportError filePath ie =
  let loc = SourceLocation filePath 0 0 ""
      msg = T.pack (show ie)
  in YamlSyntaxError YamlSyntaxInfo
    { ysiErrorId      = ImportFileNotFound
    , ysiShortMessage = msg
    , ysiGuidance     = "import failed"
    , ysiLocation     = loc
    , ysiFixHint      = Nothing
    , ysiExample      = Nothing
    }

-- | Classify handlebars errors.
classifyHandlebarsError :: Text -> Text -> EnhancedPreprocessingError
classifyHandlebarsError filePath msg =
  YamlSyntaxError YamlSyntaxInfo
    { ysiErrorId      = HandlebarsSyntaxError
    , ysiShortMessage = msg
    , ysiGuidance     = "template syntax error"
    , ysiLocation     = SourceLocation filePath 0 0 ""
    , ysiFixHint      = Nothing
    , ysiExample      = Nothing
    }

-- | Convert Position to SourceLocation.
posToSourceLocation :: Text -> Position -> SourceLocation
posToSourceLocation filePath pos = SourceLocation
  { srcLocFile     = filePath
  , srcLocLine     = posLine pos
  , srcLocColumn   = posColumn pos
  , srcLocYamlPath = ""
  }

-- | Adjust the source location to point at the tag rather than the value.
-- HsYAML reports the position of the value (mapping content or scalar),
-- but Rust reports the position of the tag (e.g., !$map).
-- This function searches nearby source lines for the tag and adjusts.
adjustLocationForTag :: Text -> SourceLocation -> Text -> SourceLocation
adjustLocationForTag source loc msg =
  let allLines = T.lines source
      lineNum = srcLocLine loc  -- 1-based
      tagName = extractTagName msg
  in case tagName of
    Just tag ->
      -- Search current line, then previous line for the specific tag
      case findTagInLine allLines lineNum tag of
        Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
        Nothing ->
          case findTagInLine allLines (lineNum - 1) tag of
            Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
            Nothing ->
              case findTagInLine allLines (lineNum - 2) tag of
                Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
                Nothing -> loc
    Nothing
      -- Parse errors (must be/must have): Rust points at the tag
      | isParseStyleError msg ->
          case findAnyTagInLine allLines lineNum of
            Just (ln, col) | col < srcLocColumn loc ->
              loc { srcLocLine = ln, srcLocColumn = col }
            _ -> case findAnyTagInLine allLines (lineNum - 1) of
              Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
              Nothing -> loc
      -- Resolve errors (expected/found): Rust points at the tag for block,
      -- at the value for flow
      | srcLocColumn loc == 0 ->
          case findAnyTagInLine allLines (lineNum - 1) of
            Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
            Nothing -> loc
      | otherwise -> loc

-- | Find a tag in a specific source line. Returns (lineNum, 1-based column).
findTagInLine :: [Text] -> Int -> Text -> Maybe (Int, Int)
findTagInLine allLines lineNum tag
  | lineNum >= 1 && lineNum <= length allLines =
      let line = allLines !! (lineNum - 1)
      in case findSubstring tag line of
           Just col -> Just (lineNum, col + 1)  -- 1-based
           Nothing  -> Nothing
  | otherwise = Nothing

-- | Find any !$ tag on a source line. Returns (lineNum, 1-based column).
findAnyTagInLine :: [Text] -> Int -> Maybe (Int, Int)
findAnyTagInLine allLines lineNum
  | lineNum >= 1 && lineNum <= length allLines =
      let line = allLines !! (lineNum - 1)
      in case findSubstring "!$" line of
           Just col -> Just (lineNum, col + 1)  -- 1-based
           Nothing  -> Nothing
  | otherwise = Nothing

-- | Find a substring in a text, return 0-based column position.
findSubstring :: Text -> Text -> Maybe Int
findSubstring needle haystack
  | T.null needle = Nothing
  | needle `T.isInfixOf` haystack =
      let (before, _) = T.breakOn needle haystack
      in Just (T.length before)
  | otherwise = Nothing

-- | Check if this is a parse-time error (not a resolve-time type mismatch).
-- Parse errors need the position adjusted to point at the tag, not the value.
isParseStyleError :: Text -> Bool
isParseStyleError msg =
  "must be " `T.isPrefixOf` msg ||
  "must have " `T.isPrefixOf` msg ||
  "invalid format" `T.isPrefixOf` msg

-- | Extract the tag name from an error message.
-- Looks for patterns like "!$map", "!$join", "!$if", etc.
extractTagName :: Text -> Maybe Text
extractTagName msg
  -- "'field' missing in !$tag tag"
  | "' missing in " `T.isInfixOf` msg =
      let (_, rest) = T.breakOn "' missing in " msg
          afterMissing = T.drop (T.length "' missing in ") rest
          tag = T.takeWhile (\c -> c /= ' ' && c /= '\n') afterMissing
      in if T.null tag then Nothing else Just tag
  -- "missing required 'in' field" — it's !$let
  | "missing required 'in' field" == msg = Just "!$let"
  -- "must be a mapping/sequence" patterns — no tag info directly
  -- Try to find !$ in the message
  | "must be " `T.isPrefixOf` msg = Nothing
  | "must have " `T.isPrefixOf` msg = Nothing
  -- "expected X, found Y" — type mismatch, search for tag in context
  | "expected " `T.isPrefixOf` msg = Nothing
  -- Messages starting with "!$tag ..."
  | "!$" `T.isPrefixOf` msg =
      let tag = "!" <> T.takeWhile (\c -> c /= ' ' && c /= ':' && c /= '\n') (T.drop 1 msg)
      in Just tag
  | otherwise = Nothing

-- | Generate guidance text from "must be" error messages.
extractMustBeGuidance :: Text -> Text
extractMustBeGuidance msg
  | "must be a mapping with required 'test' and 'then' fields" `T.isInfixOf` msg =
      "use format: {test: condition, then: value, else: alternative}"
  | "must be a mapping with variable bindings" `T.isInfixOf` msg =
      "use format: {var1: value1, var2: value2, in: expression}"
  | "must be a mapping with 'items' and 'template'" `T.isInfixOf` msg =
      "use format: {items: array, template: mapping_template}"
  | "must be a mapping with 'items' and 'key'" `T.isInfixOf` msg =
      "use format: {items: array, key: grouping_key, var: item_name, template: result_template}"
  | "must be a mapping with 'template' and 'params'" `T.isInfixOf` msg =
      "use format: {template: name, params: {key: value}}"
  | "must be a sequence with format [delimiter, array]" `T.isInfixOf` msg =
      "use format: [delimiter, array]"
  | "must be a sequence with format [delimiter, string]" `T.isInfixOf` msg =
      "use format: [delimiter, string]"
  | "must be a sequence with format [value1, value2]" `T.isInfixOf` msg =
      "use format: [value1, value2]"
  | "must be a sequence of objects to merge" `T.isInfixOf` msg =
      "use format: [object1, object2, ...]"
  | "must be a sequence of arrays to concatenate" `T.isInfixOf` msg =
      "use format: [array1, array2, ...]"
  | otherwise = "check tag format"

-- | Guess an example block from a "must be" message by looking for tag-specific keywords.
guessExampleFromMustBe :: Text -> Maybe Text
guessExampleFromMustBe msg
  | "'test' and 'then'" `T.isInfixOf` msg = Just $ tagExample "!$if"
  | "variable bindings" `T.isInfixOf` msg = Just $ tagExample "!$let"
  | "'items' and 'template'" `T.isInfixOf` msg = Just $ tagExample "!$map"
  | "'items' and 'key'" `T.isInfixOf` msg = Just $ tagExample "!$groupBy"
  | "'template' and 'params'" `T.isInfixOf` msg = Just $ tagExample "!$expand"
  | "[delimiter, array]" `T.isInfixOf` msg = Just "!$join [\",\", [\"a\", \"b\", \"c\"]]"
  | "[delimiter, string]" `T.isInfixOf` msg = Just "!$split [\",\", \"a,b,c\"]"
  | "[value1, value2]" `T.isInfixOf` msg = Just "!$eq [\"{{env}}\", \"production\"]"
  | "objects to merge" `T.isInfixOf` msg = Just "!$merge\n   - {key1: value1}\n   - {key2: value2}"
  | "arrays to concatenate" `T.isInfixOf` msg = Just "!$concat\n   - [item1, item2]\n   - [item3, item4]"
  | otherwise = Nothing

-- | Extract expected type from error message (best effort).
extractExpected :: Text -> Text
extractExpected msg
  | "items must be a sequence" `T.isInfixOf` msg = "sequence"
  | "must be a mapping" `T.isInfixOf` msg || "must be mappings" `T.isInfixOf` msg = "object"
  | "requires string" `T.isInfixOf` msg = "string"
  | "requires [string, sequence]" `T.isInfixOf` msg = "string and sequence"
  | "requires a sequence" `T.isInfixOf` msg = "sequence"
  | otherwise = "correct type"

-- | Extract found type from error message (best effort).
extractFound :: Text -> Text
extractFound _ = "wrong type"

-- | Generate type conversion help text matching Rust's output.
-- Rust only provides hints for object/string conversions.
generateTypeConversionHelp :: Text -> Text -> Maybe Text
generateTypeConversionHelp expected found
  | expected == "object" && found == "string" =
      Just "try using !$parseJson or !$parseYaml to parse the string"
  | expected == "string" && found == "object" =
      Just "try using !$toJsonString or !$toYamlString to serialize the object"
  | otherwise = Nothing

-- | Generate example text for a tag.
tagExample :: Text -> Text
tagExample tag = case T.toLower tag of
  "!$map"  -> "!$map\n     items: [1, 2, 3]\n     template: \"{{item}}\""
  "!$if"   -> "!$if\n     test: !$eq [\"prod\", \"{{env}}\"]\n     then: \"production\"\n     else: \"development\""
  "!$let"  -> "!$let\n     var1: value1\n     var2: value2\n     in: \"{{var1}}-{{var2}}\""
  "!$maplisttohash" -> "!$mapListToHash\n     items: [{\"key\": \"a\", \"value\": 1}, {\"key\": \"b\", \"value\": 2}]\n     keyPath: key\n     valuePath: value"
  "!$mergemap" -> "!$mergeMap\n     items: [1, 2, 3]\n     template: \"{key: {{item}}}\""
  "!$mapvalues" -> "!$mapValues\n     items: {a: 1, b: 2}\n     template: \"prefix-{{value}}\""
  "!$groupby" -> "!$groupBy\n     items: [{type: a, val: 1}, {type: b, val: 2}]\n     key: type"
  "!$expand" -> "!$expand\n     template: my-template\n     params: {key: value}"
  "!$eq" -> "!$eq [\"{{env}}\", \"production\"]"
  _ -> ""
