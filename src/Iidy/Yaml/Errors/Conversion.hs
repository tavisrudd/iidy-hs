-- | Convert raw PreprocessError into formatted enhanced error text.
-- Pattern-matches on error message text to classify errors and produce
-- the Rust-compatible enhanced error format.
module Iidy.Yaml.Errors.Conversion
  ( formatPreprocessErrorEnhanced
  , formatParseErrorEnhanced
  , classifyMessage
  ) where

import Control.Applicative ((<|>))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Iidy.Types (ColorChoice(..))
import Iidy.Yaml.Engine (PreprocessError(..))
import Iidy.Yaml.Errors.Display (formatError, detectErrorColors)
import Iidy.Yaml.Errors.Enhanced
import Iidy.Yaml.Errors.Ids
import Iidy.Yaml.Handlebars.Engine (InterpolateError(..))
import Iidy.Yaml.Imports.Types (ImportError(..))
import Iidy.Yaml.Location (Position(..), SourceLocation(..))
import Iidy.Yaml.Resolution.Resolver (ResolveError(..), ResolveErrorKind(..))

-- | Format a PreprocessError with enhanced display (matching Rust output format).
formatPreprocessErrorEnhanced :: ColorChoice -> Text -> Text -> PreprocessError -> IO Text
formatPreprocessErrorEnhanced colorChoice filePath source err = do
  colors <- detectErrorColors colorChoice
  let enhanced = convertToEnhanced filePath source err
  pure $ formatError colors source enhanced

-- | Format a ParseError with enhanced display.
formatParseErrorEnhanced :: ColorChoice -> Text -> Text -> Position -> Text -> IO Text
formatParseErrorEnhanced colorChoice filePath source pos msg = do
  colors <- detectErrorColors colorChoice
  let -- Translate HsYAML-specific parse errors to Rust-compatible format
      (adjustedMsg, adjustedPos) = translateParseError source pos msg
      adjustedLoc = adjustLocationForTag source (posToSourceLocation filePath adjustedPos) adjustedMsg
      enhanced = classifyMessage source adjustedLoc adjustedMsg
  pure $ formatError colors source enhanced

-- | Translate HsYAML parse errors to Rust-compatible messages.
-- HsYAML and serde_yaml report certain errors differently.
translateParseError :: Text -> Position -> Text -> (Text, Position)
translateParseError source pos msg
  -- HsYAML "Lexical error" with chained tags: Rust sees "invalid YAML structure"
  | "Lexical error" `T.isPrefixOf` msg =
      let allLines = T.lines source
          lineNum = posLine pos
          line = safeLine allLines lineNum
          hasChainedTags = case line of
            Just l -> length (findAllSubstring "!$" l) >= 2
            Nothing -> False
      in if hasChainedTags
         then case line of
           Just l -> case findSecondTag l of
             Just col -> ("invalid YAML structure", pos { posColumn = col + 1 })
             Nothing -> ("invalid YAML structure", pos)
           Nothing -> ("invalid YAML structure", pos)
         else (msg, pos)
  -- HsYAML "Unexpected '<newline>'" with unterminated string: Rust sees "unexpected end of file"
  | "Unexpected '" `T.isPrefixOf` msg && T.any (== '\n') msg =
      let allLines = T.lines source
          nextLine = posLine pos + 1
          nextCol = case safeLine allLines nextLine of
            Just l  -> T.length l + 1
            Nothing -> 0
      in ("unexpected end of file", pos { posLine = nextLine, posColumn = nextCol })
  | otherwise = (msg, pos)

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

-- | Classify a ResolveError using its structured kind.
-- Falls back to string-based classification only for REGeneric.
classifyResolveError :: Text -> Text -> ResolveError -> EnhancedPreprocessingError
classifyResolveError filePath source (ResolveError pos msg kind) =
  let loc = posToSourceLocation filePath pos
      adjustedLoc = adjustLocationForTag source loc msg
      allLines = T.lines source
  in case kind of
    REVariableNotFound path available ->
      VariableNotFoundError VariableNotFoundInfo
        { vnfErrorId       = VariableNotFound
        , vnfVariable      = path
        , vnfLocation      = adjustedLoc
        , vnfAvailableVars = available
        , vnfSuggestions   = []
        }

    REJmesPath _expr _detail varPath ->
      let displayMsg = case T.breakOn ". Variable: " msg of
            (before, rest) | not (T.null rest) -> before
            _ -> msg
      in LookupQueryError LookupQueryInfo
        { lqiErrorId       = LookupQueryFailed
        , lqiVariablePath  = varPath
        , lqiMessage       = displayMsg
        , lqiLocation      = adjustedLoc
        , lqiAvailableKeys = []
        }

    REPropertyNotFound _key varPath availKeys ->
      let propName = case T.stripPrefix "property '" msg of
            Just rest -> T.takeWhile (/= '\'') rest
            Nothing -> ""
      in LookupQueryError LookupQueryInfo
        { lqiErrorId       = LookupQueryFailed
        , lqiVariablePath  = varPath
        , lqiMessage       = "property '" <> propName <> "' not found in mapping"
        , lqiLocation      = adjustedLoc { srcLocColumn = 0 }
        , lqiAvailableKeys = availKeys
        }

    RETypeMismatch expected found ctx ->
      let cleanMsg = "expected " <> expected <> ", found " <> found
      in TypeMismatchError TypeMismatchInfo
        { tmiErrorId  = TypeMismatchInOperation
        , tmiExpected = expected
        , tmiFound    = found
        , tmiLocation = adjustedLoc
        , tmiContext  = case ctx of
            Nothing  -> cleanMsg
            Just tag -> cleanMsg <> " [" <> tag <> "]"
        , tmiHelp     = generateTypeConversionHelp expected found
        }

    RECfnValidation cfnTag ->
      CfnValidationError CfnValidationInfo
        { cviErrorId  = InvalidCloudFormationIntrinsic
        , cviTagName  = cfnTag
        , cviMessage  = msg
        , cviLocation = adjustedLoc
        , cviHelpText = cfnHelpText cfnTag msg
        }

    REHandlebars ->
      let detail = fromMaybe msg (T.stripPrefix "Handlebars error: " msg)
      in YamlSyntaxError YamlSyntaxInfo
        { ysiErrorId      = HandlebarsSyntaxError
        , ysiShortMessage = detail
        , ysiGuidance     = "template syntax error"
        , ysiLocation     = adjustedLoc
        , ysiFixHint      = Nothing
        , ysiExample      = Nothing
        }

    RETagSyntax tagName ->
      TagParsingError TagParsingInfo
        { tpiErrorId     = TagSyntaxError
        , tpiTagName     = fromMaybe "" tagName
        , tpiMessage     = msg
        , tpiGuidance    = Nothing
        , tpiLocation    = adjustedLoc
        , tpiSuggestion  = Nothing
        , tpiSpanLen     = 0
        }

    REExpandNotFound _templateName ->
      YamlSyntaxError YamlSyntaxInfo
        { ysiErrorId      = InvalidYamlSyntax
        , ysiShortMessage = msg
        , ysiGuidance     = "parsing failed"
        , ysiLocation     = adjustedLoc
        , ysiFixHint      = Nothing
        , ysiExample      = Nothing
        }

    REParseSyntax ->
      YamlSyntaxError YamlSyntaxInfo
        { ysiErrorId      = InvalidYamlSyntax
        , ysiShortMessage = msg
        , ysiGuidance     = "parsing failed"
        , ysiLocation     = adjustedLoc
        , ysiFixHint      = Nothing
        , ysiExample      = Nothing
        }

    REGeneric ->
      -- Fall back to string-based classification for unstructured errors
      classifyMessage' allLines adjustedLoc msg

-- | Pattern-match on error message to determine error type and produce
-- the appropriate EnhancedPreprocessingError variant.
classifyMessage :: Text -> SourceLocation -> Text -> EnhancedPreprocessingError
classifyMessage source loc msg = classifyMessage' allLines loc msg
  where allLines = T.lines source

-- | Internal classifier that takes pre-split lines to avoid repeated T.lines.
classifyMessage' :: [Text] -> SourceLocation -> Text -> EnhancedPreprocessingError
classifyMessage' allLines loc msg

  -- Unknown preprocessing tag: "'!$mapp' is not a valid iidy tag" (ERR_4001)
  | "' is not a valid iidy tag" `T.isSuffixOf` msg =
      let unknownTagName = T.takeWhile (/= '\'') (T.drop 1 msg)  -- extract between quotes
      in TagParsingError TagParsingInfo
        { tpiErrorId     = UnknownPreprocessingTag
        , tpiTagName     = unknownTagName
        , tpiMessage     = msg
        , tpiGuidance    = Just "check tag spelling or see documentation for valid tags"
        , tpiLocation    = loc
        , tpiSuggestion  = Nothing
        , tpiSpanLen     = T.length unknownTagName
        }

  -- Unexpected field: "unexpected field 'xxx'\n\nValid fields are: ..." (ERR_4005)
  | "unexpected field '" `T.isPrefixOf` msg =
      TagParsingError TagParsingInfo
        { tpiErrorId     = TagSyntaxError
        , tpiTagName     = ""
        , tpiMessage     = msg
        , tpiGuidance    = Just "check field spelling and tag documentation"
        , tpiLocation    = loc
        , tpiSuggestion  = findTagExampleForUnexpectedField allLines loc
        , tpiSpanLen     = 0
        }

  -- Query/jmespath mutual exclusivity: (ERR_4005)
  | "'query' and 'jmespath' are mutually exclusive" == msg =
      TagParsingError TagParsingInfo
        { tpiErrorId     = TagSyntaxError
        , tpiTagName     = "!$"
        , tpiMessage     = msg
        , tpiGuidance    = Just "use one or the other, not both"
        , tpiLocation    = loc
        , tpiSuggestion  = Just "!$ variable_name"
        , tpiSpanLen     = 0
        }

  -- Property not found in mapping (lookup query) (ERR_2006)
  | "property '" `T.isPrefixOf` msg && "' not found in mapping" `T.isInfixOf` msg =
      let propName = T.takeWhile (/= '\'') (fromMaybe msg (T.stripPrefix "property '" msg))
          -- Extract variable path: "... Variable: config. Keys: ..."
          varPath = case T.breakOn "Variable: " msg of
            (_, rest) ->
              T.takeWhile (/= '.') (fromMaybe rest (T.stripPrefix "Variable: " rest))
          -- Extract available keys: "... Keys: host, port"
          availKeys = case T.breakOn "Keys: " msg of
            (_, rest) | not (T.null rest) ->
              T.splitOn ", " (fromMaybe rest (T.stripPrefix "Keys: " rest))
            _ -> []
      in LookupQueryError LookupQueryInfo
        { lqiErrorId       = LookupQueryFailed
        , lqiVariablePath  = varPath
        , lqiMessage       = "property '" <> propName <> "' not found in mapping"
        , lqiLocation      = loc
        , lqiAvailableKeys = availKeys
        }

  -- CloudFormation validation errors (ERR_7001)
  | isCfnValidationMessage msg =
      let (cfnTag, _) = parseCfnValidationMessage msg
      in CfnValidationError CfnValidationInfo
        { cviErrorId  = InvalidCloudFormationIntrinsic
        , cviTagName  = cfnTag
        , cviMessage  = msg
        , cviLocation = loc
        , cviHelpText = cfnHelpText cfnTag msg
        }

  -- Variable not found: "Variable not found: path. Available: x, y"
  | "Variable not found: " `T.isPrefixOf` msg =
      let rest = fromMaybe msg (T.stripPrefix "Variable not found: " msg)
          (varPath, avail) = T.breakOn ". Available: " rest
          availVars = if T.null avail
                      then []
                      else T.splitOn ", " (fromMaybe avail (T.stripPrefix ". Available: " avail))
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
          tagPart = fromMaybe rest (T.stripPrefix "' missing in " rest)
          tagName = T.strip (T.takeWhile (/= ' ') tagPart)
      in TagParsingError TagParsingInfo
        { tpiErrorId     = MissingRequiredTagField
        , tpiTagName     = tagName
        , tpiMessage     = msg
        , tpiGuidance    = Just ("add '" <> field <> "' field to " <> tagName <> " tag")
        , tpiLocation    = loc
        , tpiSuggestion  = Just $ tagExample tagName
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
        , tpiSpanLen     = 0
        }

  -- "must be a mapping ..." (ERR_4003)
  | "must be a mapping" `T.isPrefixOf` msg =
      let guidance = extractMustBeGuidance msg
          foundTag = findTagOnSourceLine allLines loc
          example = case foundTag of
            Just t  -> let ex = tagExample t in if T.null ex then guessExampleFromMustBe msg else Just ex
            Nothing -> guessExampleFromMustBe msg
      in TagParsingError TagParsingInfo
        { tpiErrorId    = InvalidTagFieldValue
        , tpiTagName    = fromMaybe "" foundTag
        , tpiMessage    = msg
        , tpiGuidance   = Just guidance
        , tpiLocation   = loc
        , tpiSuggestion = example
        , tpiSpanLen    = 0
        }

  -- "must be a sequence ..." (ERR_4003)
  | "must be a sequence" `T.isPrefixOf` msg =
      let guidance = extractMustBeGuidance msg
          foundTag = findTagOnSourceLine allLines loc
          example = case foundTag of
            Just t  -> let ex = tagExample t in if T.null ex then guessExampleFromMustBe msg else Just ex
            Nothing -> guessExampleFromMustBe msg
      in TagParsingError TagParsingInfo
        { tpiErrorId    = InvalidTagFieldValue
        , tpiTagName    = fromMaybe "" foundTag
        , tpiMessage    = msg
        , tpiGuidance   = Just guidance
        , tpiLocation   = loc
        , tpiSuggestion = example
        , tpiSpanLen    = 0
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
        , tpiSpanLen     = 0
        }

  -- Runtime type mismatches from resolver (ERR_5001)
  -- "expected X, found Y" format (Rust-compatible messages from resolver)
  | "expected " `T.isPrefixOf` msg && ", found " `T.isInfixOf` msg =
      let (expPart, rest) = T.breakOn ", found " msg
          expected = fromMaybe expPart (T.stripPrefix "expected " expPart)
          rawFound = fromMaybe rest (T.stripPrefix ", found " rest)
          -- Strip context tags like " [delimiter]" from found type
          found = T.strip $ fst $ T.breakOn " [" rawFound
          -- Clean message for display (no context tags)
          cleanMsg = "expected " <> expected <> ", found " <> found
      in TypeMismatchError TypeMismatchInfo
        { tmiErrorId  = TypeMismatchInOperation
        , tmiExpected = expected
        , tmiFound    = found
        , tmiLocation = loc
        , tmiContext  = cleanMsg
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

  -- JMESPath errors: "Invalid JMESPath expression 'expr': detail. Variable: path"
  | "Invalid JMESPath expression " `T.isPrefixOf` msg =
      let -- Extract variable path from ". Variable: path" suffix
          varPath = case T.breakOn ". Variable: " msg of
            (_, rest) | not (T.null rest) ->
              fromMaybe rest (T.stripPrefix ". Variable: " rest)
            _ -> ""
          -- Strip the ". Variable: path" suffix for display message
          displayMsg = case T.breakOn ". Variable: " msg of
            (before, rest) | not (T.null rest) -> before
            _ -> msg
      in LookupQueryError LookupQueryInfo
        { lqiErrorId       = LookupQueryFailed
        , lqiVariablePath  = varPath
        , lqiMessage       = displayMsg
        , lqiLocation      = loc
        , lqiAvailableKeys = []
        }

  -- Handlebars errors
  | "Handlebars error: " `T.isPrefixOf` msg =
      let detail = fromMaybe msg (T.stripPrefix "Handlebars error: " msg)
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
        { tpiErrorId    = TagSyntaxError
        , tpiTagName    = ""
        , tpiMessage    = msg
        , tpiGuidance   = Nothing
        , tpiLocation   = loc
        , tpiSuggestion = Nothing
        , tpiSpanLen    = 0
        }

-- | Classify import errors.
classifyImportError :: Text -> ImportError -> EnhancedPreprocessingError
classifyImportError filePath (ImportError msg) =
  let loc = SourceLocation filePath 0 0 ""
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
      -- Type mismatch errors: use Rust-style find_tag_column logic
      | isTypeMismatchError msg ->
          adjustForTypeMismatch allLines loc msg
      -- Variable not found: search for variable reference pattern
      | "Variable not found: " `T.isPrefixOf` msg ->
          let rest = fromMaybe msg (T.stripPrefix "Variable not found: " msg)
              varPath = fst (T.breakOn ". Available: " rest)
          in case findVariableColumn allLines lineNum varPath of
            Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
            Nothing -> loc
      -- Unknown tag: "'!$mapp' is not a valid iidy tag"
      | "' is not a valid iidy tag" `T.isSuffixOf` msg ->
          let unknownTag = T.takeWhile (/= '\'') (T.drop 1 msg)
          in case findTagInLine allLines lineNum unknownTag of
            Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
            Nothing -> case findTagInLine allLines (lineNum - 1) unknownTag of
              Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
              Nothing -> loc
      -- Unexpected field: position needs +1 for 1-based column
      | "unexpected field '" `T.isPrefixOf` msg ->
          loc { srcLocColumn = srcLocColumn loc + 1 }
      -- Query/jmespath mutual exclusivity: search for !$ tag
      | "'query' and 'jmespath'" `T.isPrefixOf` msg ->
          case findAnyTagInLine allLines lineNum of
            Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
            _ -> case findAnyTagInLine allLines (lineNum - 1) of
              Just (ln, col) -> loc { srcLocLine = ln, srcLocColumn = col }
              Nothing -> loc
      -- CFN validation: +1 for 1-based column
      | isCfnValidationMessage msg ->
          loc { srcLocColumn = srcLocColumn loc + 1 }
      -- Property not found in query: column 0 suppresses caret (matching Rust)
      | "property '" `T.isPrefixOf` msg ->
          loc { srcLocColumn = 0 }
      | otherwise -> loc

-- | Check if message is a type mismatch error
isTypeMismatchError :: Text -> Bool
isTypeMismatchError msg = "expected " `T.isPrefixOf` msg && ", found " `T.isInfixOf` msg

-- | Adjust location for type mismatch errors.
-- Searches for the tag on the source line, then uses tag-specific logic
-- to find the correct column (matching Rust's find_tag_column behavior).
adjustForTypeMismatch :: [Text] -> SourceLocation -> Text -> SourceLocation
adjustForTypeMismatch allLines loc msg =
  let lineNum = srcLocLine loc
      -- First: find which line has the tag
      tagInfo = findAnyTagOnLine allLines lineNum
            <|> findAnyTagOnLine allLines (lineNum - 1)
  in case tagInfo of
    Just (tagLn, tagCol0, tagText) ->
      -- Try searching for field keyword on subsequent lines (block-style)
      -- Skip field search for template-result errors (they should use tag fallback)
      let isItemsError = "expected sequence" `T.isPrefixOf` msg
                       || "expected object" `T.isPrefixOf` msg
          fieldResult = if isItemsError
                        then findFieldColumn allLines tagLn tagText
                        else Nothing
          fallback = loc { srcLocLine = tagLn, srcLocColumn = tagCol0 + tagFallbackOffset tagText }
      in case fieldResult of
        Just (fieldLn, fieldCol) -> loc { srcLocLine = fieldLn, srcLocColumn = fieldCol }
        Nothing ->
          -- Try flow-style position adjustment on the tag line
          case safeLine allLines tagLn of
            Just tagLine -> case findFlowColumn tagLine tagText msg of
              Just flowCol -> loc { srcLocLine = tagLn, srcLocColumn = flowCol }
              Nothing -> fallback
            Nothing -> fallback
    Nothing -> loc

-- | Get the fallback offset for a tag, matching Rust's tag_fallback patterns.
-- Rust matches tag families in order: !$split, !$join, !$groupBy, !$mapListToHash,
-- !$fromPairs, !$merge, !$map. Each uses find(short_tag) + offset.
-- The offset = short_tag_length + 1.
tagFallbackOffset :: Text -> Int
tagFallbackOffset tagText
  | "!$split" `T.isPrefixOf` tt     = 8    -- !$split (7) + 1
  | "!$join" `T.isPrefixOf` tt      = 7    -- !$join (6) + 1
  | "!$groupBy" `T.isPrefixOf` tt   = 9    -- !$groupBy (9) + 0
  | "!$mapListToHash" `T.isPrefixOf` tt = 15 -- !$mapListToHash (15) + 0
  | "!$fromPairs" `T.isPrefixOf` tt = 12   -- !$fromPairs (11) + 1
  | "!$merge" `T.isPrefixOf` tt     = 8    -- !$merge (7) + 1 (matches !$mergeMap)
  | "!$map" `T.isPrefixOf` tt       = 6    -- !$map (5) + 1 (matches !$mapValues)
  | otherwise = T.length tagText + 1
  where tt = tagText

-- | Find a !$ tag on a line, returning (lineNum, 0-based col, tag text).
findAnyTagOnLine :: [Text] -> Int -> Maybe (Int, Int, Text)
findAnyTagOnLine allLines lineNum = do
  line <- safeLine allLines lineNum
  col0 <- findSubstring "!$" line
  let rest = T.drop col0 line
      tag = T.takeWhile (\c -> c /= ' ' && c /= '\n' && c /= '\t' && c /= '{' && c /= '[' && c /= ':') rest
  if T.length tag > 2 then Just (lineNum, col0, tag) else Nothing

-- | Search subsequent lines after a tag for field keywords.
-- Returns (lineNum, column) matching Rust's find_after_keyword logic.
findFieldColumn :: [Text] -> Int -> Text -> Maybe (Int, Int)
findFieldColumn allLines tagLn tagText
  | tagLower == "!$groupby" = searchField "items:"
  | tagLower == "!$maplisttohash" = searchField "items:"
  | tagLower == "!$mapvalues" = searchField "items:"
  | tagLower == "!$frompairs" = searchField "source:"
  | otherwise = Nothing
  where
    tagLower = T.toLower tagText
    searchField keyword =
      -- Search lines after the tag for the keyword
      let nextLines = drop tagLn (zip [1..] (map Just allLines))
      in case [(n, findAfterKeyword line keyword) | (n, Just line) <- take 3 nextLines
              , keyword `T.isInfixOf` line] of
        ((n, Just col):_) -> Just (n, col)
        _ -> Nothing

-- | Find the column for flow-style tag arguments on the same line.
-- Handles !$join [delim, array] and !$split [delim, string] patterns.
findFlowColumn :: Text -> Text -> Text -> Maybe Int
findFlowColumn tagLine tagText msg
  | tagLower == "!$join" =
      if "[delimiter]" `T.isSuffixOf` msg
      then -- Delimiter (first arg): find '[' + 1
           fmap (+ 1) (findSubstring "[" tagLine)
      else if "expected sequence" `T.isPrefixOf` msg
      then -- Sequence (second arg): find after first comma
           findSecondBracketArg tagLine
      else -- Item error: use tag fallback (returns Nothing)
           Nothing
  | otherwise = Nothing
  where
    tagLower = T.toLower tagText

-- | Find the second argument in a bracket expression [first, second].
-- Returns 1-based column of the second argument.
findSecondBracketArg :: Text -> Maybe Int
findSecondBracketArg line = do
  bracketPos <- findSubstring "[" line
  let after = T.drop (bracketPos + 1) line
      commaIdx = findUnquotedComma after
  case commaIdx of
    Just ci ->
      let afterComma = T.drop (ci + 1) after
          ws = T.length (T.takeWhile (== ' ') afterComma)
      in Just (bracketPos + 1 + ci + 1 + ws + 1)  -- 1-based
    Nothing -> Nothing

-- | Find unquoted comma position in text.
findUnquotedComma :: Text -> Maybe Int
findUnquotedComma = go 0 False
  where
    go i inQ t = case T.uncons t of
      Nothing -> Nothing
      Just (c, rest)
        | inQ       -> go (i+1) (c /= '"') rest
        | c == ','  -> Just i
        | c == '"'  -> go (i+1) True rest
        | otherwise -> go (i+1) False rest


-- | Find the position of a variable reference in source lines.
-- Searches for patterns like "!$ variable", "!$variable", "{{variable}}".
-- Returns (lineNum, column) matching Rust's find_variable_column.
findVariableColumn :: [Text] -> Int -> Text -> Maybe (Int, Int)
findVariableColumn allLines lineNum varPath = do
  line <- safeLine allLines lineNum
  case findSubstring ("!$ " <> varPath) line of
    Just col -> Just (lineNum, col + 4)  -- skip "!$ " + 1 for Rust compat
    Nothing -> case findSubstring ("!$" <> varPath) line of
      Just col -> Just (lineNum, col + 3)
      Nothing -> case findSubstring ("{{" <> varPath <> "}}") line of
        Just col -> Just (lineNum, col + 2)
        Nothing -> Nothing

-- | Find the column after a keyword and whitespace (Rust-compatible).
findAfterKeyword :: Text -> Text -> Maybe Int
findAfterKeyword line keyword =
  case findSubstring keyword line of
    Just pos ->
      let afterKw = T.drop (pos + T.length keyword) line
          ws = T.length (T.takeWhile (== ' ') afterKw)
      in Just (pos + T.length keyword + ws + 1)  -- +1 matches Rust
    Nothing -> Nothing

-- | Find a tag in a specific source line. Returns (lineNum, 1-based column).
findTagInLine :: [Text] -> Int -> Text -> Maybe (Int, Int)
findTagInLine allLines lineNum tag = do
  line <- safeLine allLines lineNum
  col <- findSubstring tag line
  Just (lineNum, col + 1)  -- 1-based

-- | Find any !$ tag on a source line. Returns (lineNum, 1-based column).
findAnyTagInLine :: [Text] -> Int -> Maybe (Int, Int)
findAnyTagInLine allLines lineNum = do
  line <- safeLine allLines lineNum
  col <- findSubstring "!$" line
  Just (lineNum, col + 1)  -- 1-based

-- | Safe 1-based line access into a list of lines.
safeLine :: [Text] -> Int -> Maybe Text
safeLine lns n
  | n >= 1 = case drop (n - 1) lns of
      (x:_) -> Just x
      _     -> Nothing
  | otherwise = Nothing

-- | Find a substring in a text, return 0-based column position.
findSubstring :: Text -> Text -> Maybe Int
findSubstring needle haystack
  | T.null needle = Nothing
  | needle `T.isInfixOf` haystack =
      let (before, _) = T.breakOn needle haystack
      in Just (T.length before)
  | otherwise = Nothing

-- | Find all occurrences of a substring, returning 0-based positions.
findAllSubstring :: Text -> Text -> [Int]
findAllSubstring needle haystack = go 0 haystack
  where
    nLen = T.length needle
    go _ t | T.null t = []
    go offset t = case findSubstring needle t of
      Nothing -> []
      Just pos -> (offset + pos) : go (offset + pos + nLen) (T.drop (pos + nLen) t)

-- | Find the second !$ tag on a line, returning its 0-based column position.
findSecondTag :: Text -> Maybe Int
findSecondTag line =
  case findAllSubstring "!$" line of
    (_:second:_) -> Just second
    _ -> Nothing

-- | Find the full tag name (e.g., "!$mapListToHash") on the source line at the given location.
findTagOnSourceLine :: [Text] -> SourceLocation -> Maybe Text
findTagOnSourceLine allLines loc = do
  line <- safeLine allLines (srcLocLine loc)
  col <- findSubstring "!$" line
  let rest = T.drop col line
      tag = T.takeWhile (\c -> c /= ' ' && c /= '\n' && c /= '\t' && c /= '{' && c /= '[' && c /= ':') rest
  if T.length tag > 2 then Just tag else Nothing

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
          afterMissing = fromMaybe rest (T.stripPrefix "' missing in " rest)
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
  | "must be a sequence with exactly 2 elements" `T.isInfixOf` msg =
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
  | "exactly 2 elements" `T.isInfixOf` msg = Just "!$eq [\"{{env}}\", \"production\"]"
  | "objects to merge" `T.isInfixOf` msg = Just "!$merge\n     - {key1: value1}\n     - {key2: value2}\n     - {key3: value3}"
  | "arrays to concatenate" `T.isInfixOf` msg = Just "!$concat\n     - [item1, item2]\n     - [item3, item4]\n     - [item5]"
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
extractFound msg
  | "found a string" `T.isInfixOf` msg = "string"
  | "found a sequence" `T.isInfixOf` msg = "sequence"
  | "found a mapping" `T.isInfixOf` msg || "found an object" `T.isInfixOf` msg = "object"
  | "found a number" `T.isInfixOf` msg = "number"
  | "found a boolean" `T.isInfixOf` msg = "boolean"
  | "found null" `T.isInfixOf` msg = "null"
  | otherwise = "wrong type"

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
  "!$mapvalues" -> "!$mapValues\n     <check documentation for proper syntax>"
  "!$groupby" -> "!$groupBy\n     items: [{name: \"a\", type: \"x\"}, {name: \"b\", type: \"x\"}]\n     key: type\n     var: group\n     template: \"{{group.key}}: {{#each group.items}}{{name}}{{/each}}\""
  "!$expand" -> "!$expand\n     template: my-template\n     params: {key: value}"
  "!$eq" -> "!$eq [\"{{env}}\", \"production\"]"
  _ -> ""

-- | Check if a message is a CloudFormation validation error.
isCfnValidationMessage :: Text -> Bool
isCfnValidationMessage msg = any (\p -> p `T.isPrefixOf` msg) cfnValidationPrefixes
  where
    cfnValidationPrefixes :: [Text]
    cfnValidationPrefixes =
      [ "!Ref ", "!Sub ", "!GetAtt ", "!Join ", "!Select ", "!Split "
      , "!FindInMap ", "!Base64 ", "!GetAZs ", "!ImportValue "
      , "!Cidr ", "!Length ", "!ToJsonString ", "!Transform ", "!ForEach "
      , "!If ", "!Equals ", "!And ", "!Or ", "!Not "
      ]

-- | Extract CFN tag name from validation message.
parseCfnValidationMessage :: Text -> (Text, Text)
parseCfnValidationMessage msg =
  let tag = "!" <> T.takeWhile (/= ' ') (T.drop 1 msg)
  in (tag, msg)

-- | Generate help text for CloudFormation validation errors.
cfnHelpText :: Text -> Text -> Text
cfnHelpText tag _msg
  | tag == "!Ref" =
      "!Ref expects a string (resource or parameter name)\n" <>
      "   example: BucketName: !Ref MyBucket\n" <>
      "   example: Environment: !Ref EnvironmentParam"
  | tag == "!Base64" =
      "!Base64 expects a non-null string value\n" <>
      "   example: UserData: !Base64 'echo Hello'\n" <>
      "   example: Script: !Base64 !Sub 'echo ${Parameter}'"
  | tag == "!Join" =
      "!Join expects [delimiter, array] with exactly 2 elements\n" <>
      "   example: Name: !Join ['-', [!Ref 'AWS::StackName', 'suffix']]"
  | tag == "!Select" =
      "!Select expects [index, array] with exactly 2 elements\n" <>
      "   example: AZ: !Select [0, !GetAZs '']"
  | tag == "!FindInMap" =
      "!FindInMap expects [map, key1, key2] with exactly 3 elements\n" <>
      "   example: AMI: !FindInMap [RegionMap, !Ref 'AWS::Region', AMI]"
  | tag == "!Sub" =
      "!Sub expects a string or [string, variables_map]\n" <>
      "   example: Name: !Sub '${AWS::StackName}-resource'\n" <>
      "   example: Name: !Sub ['${Param}-suffix', {Param: !Ref MyParam}]"
  | tag == "!GetAtt" =
      "!GetAtt expects 'Resource.Attribute' or [resource, attribute]\n" <>
      "   example: Arn: !GetAtt MyBucket.Arn\n" <>
      "   example: Arn: !GetAtt [MyBucket, Arn]"
  | tag == "!Split" =
      "!Split expects [delimiter, string] with exactly 2 elements\n" <>
      "   example: Parts: !Split [',', 'a,b,c']"
  | tag == "!If" =
      "!If expects [condition, true_value, false_value] with exactly 3 elements\n" <>
      "   example: Value: !If [IsProduction, 'prod', 'dev']"
  | tag == "!Equals" =
      "!Equals expects [value1, value2] with exactly 2 elements\n" <>
      "   example: !Equals [!Ref EnvParam, 'production']"
  | tag == "!Not" =
      "!Not expects a 1-element array containing a condition\n" <>
      "   example: !Not [!Equals [!Ref EnvParam, 'production']]"
  | otherwise = tag <> " usage error"

-- | Find a tag example for unexpected field errors by looking at the source line.
findTagExampleForUnexpectedField :: [Text] -> SourceLocation -> Maybe Text
findTagExampleForUnexpectedField allLines loc =
  let lineNum = srcLocLine loc
  in case findTagOnSourceLine allLines (loc { srcLocLine = max 1 (lineNum - 3) }) of
    Just t  -> let ex = tagExample t in if T.null ex then Nothing else Just ex
    Nothing -> findTagInNearbyLines allLines lineNum

-- | Search nearby lines (before the error position) for a tag.
findTagInNearbyLines :: [Text] -> Int -> Maybe Text
findTagInNearbyLines allLines lineNum =
  let searchRange = [max 1 (lineNum - 5) .. lineNum]
      findTag ln = do
        line <- safeLine allLines ln
        col <- findSubstring "!$" line
        let rest = T.drop col line
            tag = T.takeWhile (\c -> c /= ' ' && c /= '\n' && c /= '\t' && c /= '{' && c /= '[' && c /= ':') rest
        if T.length tag > 2 then Just tag else Nothing
  in case concatMap (\ln -> maybe [] (:[]) (findTag ln)) searchRange of
    (t:_) -> let ex = tagExample t in if T.null ex then Nothing else Just ex
    [] -> Nothing
