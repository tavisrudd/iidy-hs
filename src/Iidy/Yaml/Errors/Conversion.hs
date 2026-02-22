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
-- Reads the source file content and converts to EnhancedPreprocessingError for display.
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
      enhanced = YamlSyntaxError YamlSyntaxInfo
        { ysiErrorId      = InvalidYamlSyntax
        , ysiShortMessage = msg
        , ysiGuidance     = "check YAML syntax"
        , ysiLocation     = loc
        , ysiFixHint      = Nothing
        , ysiExample      = Nothing
        }
  pure $ formatError colors source enhanced

-- | Convert PreprocessError to EnhancedPreprocessingError.
convertToEnhanced :: Text -> Text -> PreprocessError -> EnhancedPreprocessingError
convertToEnhanced filePath _source = \case
  PeResolveError re -> classifyResolveError filePath re
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
classifyResolveError :: Text -> ResolveError -> EnhancedPreprocessingError
classifyResolveError filePath (ResolveError pos msg) =
  let loc = posToSourceLocation filePath pos
  in classifyMessage loc msg

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
        , vnfSuggestions   = []  -- TODO: fuzzy matching
        }

  -- Tag: "'field' missing in !$tag tag" (from Rust, our parser may differ)
  | "' missing in " `T.isInfixOf` msg =
      let (_fieldPart, rest) = T.breakOn " missing in " msg
          tagName = T.strip (T.drop (T.length " missing in ") rest)
          tagNameClean = T.takeWhile (/= ' ') tagName
      in TagParsingError TagParsingInfo
        { tpiErrorId     = MissingRequiredTagField
        , tpiTagName     = tagNameClean
        , tpiMessage     = msg
        , tpiLocation    = loc
        , tpiSuggestion  = Just $ tagExample tagNameClean
        , tpiCaretColumn = 0
        , tpiSpanLen     = 0
        }

  -- Tag: "must be a mapping ..." (ERR_4003)
  | "must be a " `T.isPrefixOf` msg =
      TagParsingError TagParsingInfo
        { tpiErrorId     = InvalidTagFieldValue
        , tpiTagName     = ""
        , tpiMessage     = msg
        , tpiLocation    = loc
        , tpiSuggestion  = Nothing
        , tpiCaretColumn = 0
        , tpiSpanLen     = 0
        }

  -- Runtime type mismatches (ERR_5001): "!$tag items must be ...", "!$split requires string"
  -- Must come before the general "requires" pattern to avoid misclassification.
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

  -- Parse-time tag structure errors (ERR_4003): "!$tag requires ..."
  | "!$" `T.isPrefixOf` msg && " requires " `T.isInfixOf` msg =
      let tagName = "!" <> T.takeWhile (\c -> c /= ' ' && c /= ':') (T.drop 1 msg)
      in TagParsingError TagParsingInfo
        { tpiErrorId     = InvalidTagFieldValue
        , tpiTagName     = tagName
        , tpiMessage     = msg
        , tpiLocation    = loc
        , tpiSuggestion  = Just $ tagExample tagName
        , tpiCaretColumn = 0
        , tpiSpanLen     = 0
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

  -- Fallback: treat as generic tag error
  | otherwise =
      TagParsingError TagParsingInfo
        { tpiErrorId     = TagSyntaxError
        , tpiTagName     = ""
        , tpiMessage     = msg
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
extractFound _ = "wrong type"  -- Hard to extract from current messages

-- | Generate example text for a tag.
tagExample :: Text -> Text
tagExample tag = case T.toLower tag of
  "!$map"  -> "example:\n   !$map\n     items: [1, 2, 3]\n     template: \"{{item}}\""
  "!$if"   -> "example:\n   !$if\n     test: !$eq [\"prod\", \"{{env}}\"]\n     then: \"production\"\n     else: \"development\""
  "!$let"  -> "example:\n   !$let\n     var1: value1\n     var2: value2\n     in: \"{{var1}}-{{var2}}\""
  "!$maplisttohash" -> "example:\n   !$mapListToHash\n     items: [{\"key\": \"a\", \"value\": 1}, {\"key\": \"b\", \"value\": 2}]\n     keyPath: key\n     valuePath: value"
  "!$mergemap" -> "example:\n   !$mergeMap\n     items: [1, 2, 3]\n     template: \"{key: {{item}}}\""
  "!$mapvalues" -> "example:\n   !$mapValues\n     items: {a: 1, b: 2}\n     template: \"prefix-{{value}}\""
  "!$groupby" -> "example:\n   !$groupBy\n     items: [{type: a, val: 1}, {type: b, val: 2}]\n     key: type"
  "!$expand" -> "example:\n   !$expand\n     template: my-template\n     params: {key: value}"
  _ -> ""
