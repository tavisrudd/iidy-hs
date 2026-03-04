{- | Convert raw PreprocessError into formatted enhanced error text.
Pattern-matches on error message text to classify errors and produce
the Rust-compatible enhanced error format.
-}
module Iidy.Yaml.Errors.Conversion (
    formatPreprocessErrorEnhanced,
    formatParseErrorEnhanced,
    classifyMessage,
) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Iidy.Types (ColorChoice (..))
import Iidy.Yaml.Engine (PreprocessError (..))
import Iidy.Yaml.Errors.Conversion.Guidance (
    cfnHelpText,
    extractMustBeGuidance,
    generateTypeConversionHelp,
    guessExampleFromMustBe,
    isCfnValidationMessage,
    parseCfnValidationMessage,
 )
import Iidy.Yaml.Errors.Conversion.LineSearch (
    findAllSubstring,
    findSecondTag,
    findTagExampleForUnexpectedField,
    findTagOnSourceLine,
    safeLine,
    tagExample,
 )
import Iidy.Yaml.Errors.Conversion.Location (
    adjustLocationForTag,
    posToSourceLocation,
 )
import Iidy.Yaml.Errors.Display (detectErrorColors, formatError)
import Iidy.Yaml.Errors.Enhanced
import Iidy.Yaml.Errors.Ids
import Iidy.Yaml.Handlebars.Engine (InterpolateError (..))
import Iidy.Yaml.Imports.Types (ImportError (..))
import Iidy.Yaml.Location (Position (..), SourceLocation (..))
import Iidy.Yaml.Resolution.Resolver (ResolveError (..), ResolveErrorKind (..))

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
    let
        -- Translate HsYAML-specific parse errors to Rust-compatible format
        (adjustedMsg, adjustedPos) = translateParseError source pos msg
        adjustedLoc = adjustLocationForTag source (posToSourceLocation filePath adjustedPos) adjustedMsg
        enhanced = classifyMessage source adjustedLoc adjustedMsg
    pure $ formatError colors source enhanced

{- | Translate HsYAML parse errors to Rust-compatible messages.
HsYAML and serde_yaml report certain errors differently.
-}
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
                        Just col -> ("invalid YAML structure", pos{posColumn = col + 1})
                        Nothing -> ("invalid YAML structure", pos)
                    Nothing -> ("invalid YAML structure", pos)
                else (msg, pos)
    -- HsYAML "Unexpected '<newline>'" with unterminated string: Rust sees "unexpected end of file"
    | "Unexpected '" `T.isPrefixOf` msg && T.any (== '\n') msg =
        let allLines = T.lines source
            nextLine = posLine pos + 1
            nextCol = case safeLine allLines nextLine of
                Just l -> T.length l + 1
                Nothing -> 0
         in ("unexpected end of file", pos{posLine = nextLine, posColumn = nextCol})
    | otherwise = (msg, pos)

-- | Convert PreprocessError to EnhancedPreprocessingError.
convertToEnhanced :: Text -> Text -> PreprocessError -> EnhancedPreprocessingError
convertToEnhanced filePath source = \case
    PeResolveError re -> classifyResolveError filePath source re
    PeImportError ie -> classifyImportError filePath ie
    PeHandlebarsError (InterpolateError msg) -> classifyHandlebarsError filePath msg
    PeCycleError msg ->
        YamlSyntaxError
            YamlSyntaxInfo
                { ysiErrorId = ImportCircularDependency
                , ysiShortMessage = msg
                , ysiGuidance = "circular import detected"
                , ysiLocation = SourceLocation filePath 0 0 ""
                , ysiFixHint = Nothing
                , ysiExample = Nothing
                }

{- | Classify a ResolveError using its structured kind.
Falls back to string-based classification only for REGeneric.
-}
classifyResolveError :: Text -> Text -> ResolveError -> EnhancedPreprocessingError
classifyResolveError filePath source (ResolveError pos msg kind) =
    let loc = posToSourceLocation filePath pos
        adjustedLoc = adjustLocationForTag source loc msg
        allLines = T.lines source
     in case kind of
            REVariableNotFound path available ->
                VariableNotFoundError
                    VariableNotFoundInfo
                        { vnfErrorId = VariableNotFound
                        , vnfVariable = path
                        , vnfLocation = adjustedLoc
                        , vnfAvailableVars = available
                        , vnfSuggestions = []
                        }
            REJmesPath _expr _detail varPath ->
                let displayMsg = case T.breakOn ". Variable: " msg of
                        (before, rest) | not (T.null rest) -> before
                        _noVariableSuffix -> msg
                 in LookupQueryError
                        LookupQueryInfo
                            { lqiErrorId = LookupQueryFailed
                            , lqiVariablePath = varPath
                            , lqiMessage = displayMsg
                            , lqiLocation = adjustedLoc
                            , lqiAvailableKeys = []
                            }
            REPropertyNotFound _key varPath availKeys ->
                let propName = case T.stripPrefix "property '" msg of
                        Just rest -> T.takeWhile (/= '\'') rest
                        Nothing -> ""
                 in LookupQueryError
                        LookupQueryInfo
                            { lqiErrorId = LookupQueryFailed
                            , lqiVariablePath = varPath
                            , lqiMessage = "property '" <> propName <> "' not found in mapping"
                            , lqiLocation = adjustedLoc{srcLocColumn = 0}
                            , lqiAvailableKeys = availKeys
                            }
            RETypeMismatch expected found ctx ->
                let cleanMsg = "expected " <> expected <> ", found " <> found
                 in TypeMismatchError
                        TypeMismatchInfo
                            { tmiErrorId = TypeMismatchInOperation
                            , tmiExpected = expected
                            , tmiFound = found
                            , tmiLocation = adjustedLoc
                            , tmiContext = case ctx of
                                Nothing -> cleanMsg
                                Just tag -> cleanMsg <> " [" <> tag <> "]"
                            , tmiHelp = generateTypeConversionHelp expected found
                            }
            RECfnValidation cfnTag ->
                CfnValidationError
                    CfnValidationInfo
                        { cviErrorId = InvalidCloudFormationIntrinsic
                        , cviTagName = cfnTag
                        , cviMessage = msg
                        , cviLocation = adjustedLoc
                        , cviHelpText = cfnHelpText cfnTag msg
                        }
            REHandlebars ->
                let detail = fromMaybe msg (T.stripPrefix "Handlebars error: " msg)
                 in YamlSyntaxError
                        YamlSyntaxInfo
                            { ysiErrorId = HandlebarsSyntaxError
                            , ysiShortMessage = detail
                            , ysiGuidance = "template syntax error"
                            , ysiLocation = adjustedLoc
                            , ysiFixHint = Nothing
                            , ysiExample = Nothing
                            }
            RETagSyntax tagName ->
                TagParsingError
                    TagParsingInfo
                        { tpiErrorId = TagSyntaxError
                        , tpiTagName = fromMaybe "" tagName
                        , tpiMessage = msg
                        , tpiGuidance = Nothing
                        , tpiLocation = adjustedLoc
                        , tpiSuggestion = Nothing
                        , tpiSpanLen = 0
                        }
            REExpandNotFound _templateName ->
                YamlSyntaxError
                    YamlSyntaxInfo
                        { ysiErrorId = InvalidYamlSyntax
                        , ysiShortMessage = msg
                        , ysiGuidance = "parsing failed"
                        , ysiLocation = adjustedLoc
                        , ysiFixHint = Nothing
                        , ysiExample = Nothing
                        }
            RECircularExpansion _templateName ->
                YamlSyntaxError
                    YamlSyntaxInfo
                        { ysiErrorId = ImportCircularDependency
                        , ysiShortMessage = msg
                        , ysiGuidance = "circular template expansion detected"
                        , ysiLocation = adjustedLoc
                        , ysiFixHint = Just "break the cycle by removing one of the circular !$expand references"
                        , ysiExample = Nothing
                        }
            REParseSyntax ->
                YamlSyntaxError
                    YamlSyntaxInfo
                        { ysiErrorId = InvalidYamlSyntax
                        , ysiShortMessage = msg
                        , ysiGuidance = "parsing failed"
                        , ysiLocation = adjustedLoc
                        , ysiFixHint = Nothing
                        , ysiExample = Nothing
                        }
            REGeneric ->
                -- Fall back to string-based classification for unstructured errors
                classifyMessage' allLines adjustedLoc msg

{- | Pattern-match on error message to determine error type and produce
the appropriate EnhancedPreprocessingError variant.
-}
classifyMessage :: Text -> SourceLocation -> Text -> EnhancedPreprocessingError
classifyMessage source loc msg = classifyMessage' allLines loc msg
  where
    allLines = T.lines source

-- | Internal classifier that takes pre-split lines to avoid repeated T.lines.
classifyMessage' :: [Text] -> SourceLocation -> Text -> EnhancedPreprocessingError
classifyMessage' allLines loc msg
    -- Unknown preprocessing tag: "'!$mapp' is not a valid iidy tag" (ERR_4001)
    | "' is not a valid iidy tag" `T.isSuffixOf` msg =
        let unknownTagName = T.takeWhile (/= '\'') (T.drop 1 msg) -- extract between quotes
         in TagParsingError
                TagParsingInfo
                    { tpiErrorId = UnknownPreprocessingTag
                    , tpiTagName = unknownTagName
                    , tpiMessage = msg
                    , tpiGuidance = Just "check tag spelling or see documentation for valid tags"
                    , tpiLocation = loc
                    , tpiSuggestion = Nothing
                    , tpiSpanLen = T.length unknownTagName
                    }
    -- Unexpected field: "unexpected field 'xxx'\n\nValid fields are: ..." (ERR_4005)
    | "unexpected field '" `T.isPrefixOf` msg =
        TagParsingError
            TagParsingInfo
                { tpiErrorId = TagSyntaxError
                , tpiTagName = ""
                , tpiMessage = msg
                , tpiGuidance = Just "check field spelling and tag documentation"
                , tpiLocation = loc
                , tpiSuggestion = findTagExampleForUnexpectedField allLines loc
                , tpiSpanLen = 0
                }
    -- Query/jmespath mutual exclusivity: (ERR_4005)
    | "'query' and 'jmespath' are mutually exclusive" == msg =
        TagParsingError
            TagParsingInfo
                { tpiErrorId = TagSyntaxError
                , tpiTagName = "!$"
                , tpiMessage = msg
                , tpiGuidance = Just "use one or the other, not both"
                , tpiLocation = loc
                , tpiSuggestion = Just "!$ variable_name"
                , tpiSpanLen = 0
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
                (_, rest)
                    | not (T.null rest) ->
                        T.splitOn ", " (fromMaybe rest (T.stripPrefix "Keys: " rest))
                _noKeysSuffix -> []
         in LookupQueryError
                LookupQueryInfo
                    { lqiErrorId = LookupQueryFailed
                    , lqiVariablePath = varPath
                    , lqiMessage = "property '" <> propName <> "' not found in mapping"
                    , lqiLocation = loc
                    , lqiAvailableKeys = availKeys
                    }
    -- CloudFormation validation errors (ERR_7001)
    | isCfnValidationMessage msg =
        let (cfnTag, _) = parseCfnValidationMessage msg
         in CfnValidationError
                CfnValidationInfo
                    { cviErrorId = InvalidCloudFormationIntrinsic
                    , cviTagName = cfnTag
                    , cviMessage = msg
                    , cviLocation = loc
                    , cviHelpText = cfnHelpText cfnTag msg
                    }
    -- Variable not found: "Variable not found: path. Available: x, y"
    | "Variable not found: " `T.isPrefixOf` msg =
        let rest = fromMaybe msg (T.stripPrefix "Variable not found: " msg)
            (varPath, avail) = T.breakOn ". Available: " rest
            availVars =
                if T.null avail
                    then []
                    else T.splitOn ", " (fromMaybe avail (T.stripPrefix ". Available: " avail))
         in VariableNotFoundError
                VariableNotFoundInfo
                    { vnfErrorId = VariableNotFound
                    , vnfVariable = varPath
                    , vnfLocation = loc
                    , vnfAvailableVars = availVars
                    , vnfSuggestions = []
                    }
    -- Missing field: "'field' missing in !$tag tag" (ERR_4002)
    | "' missing in " `T.isInfixOf` msg =
        let
            -- Extract field name: text before "' missing in"
            (fieldQuoted, rest) = T.breakOn "' missing in " msg
            field = T.drop 1 fieldQuoted -- drop leading '
            -- Extract tag name: text after "' missing in "
            tagPart = fromMaybe rest (T.stripPrefix "' missing in " rest)
            tagName = T.strip (T.takeWhile (/= ' ') tagPart)
         in
            TagParsingError
                TagParsingInfo
                    { tpiErrorId = MissingRequiredTagField
                    , tpiTagName = tagName
                    , tpiMessage = msg
                    , tpiGuidance = Just ("add '" <> field <> "' field to " <> tagName <> " tag")
                    , tpiLocation = loc
                    , tpiSuggestion = Just $ tagExample tagName
                    , tpiSpanLen = 0
                    }
    -- Missing required 'in' field (ERR_4002 for !$let)
    | "missing required 'in' field" == msg =
        TagParsingError
            TagParsingInfo
                { tpiErrorId = MissingRequiredTagField
                , tpiTagName = "!$let"
                , tpiMessage = msg
                , tpiGuidance = Just "add 'in' field containing the expression to evaluate"
                , tpiLocation = loc
                , tpiSuggestion = Just $ tagExample "!$let"
                , tpiSpanLen = 0
                }
    -- "must be a mapping ..." (ERR_4003)
    | "must be a mapping" `T.isPrefixOf` msg =
        let guidance = extractMustBeGuidance msg
            foundTag = findTagOnSourceLine allLines loc
            example = case foundTag of
                Just t -> let ex = tagExample t in if T.null ex then guessExampleFromMustBe msg else Just ex
                Nothing -> guessExampleFromMustBe msg
         in TagParsingError
                TagParsingInfo
                    { tpiErrorId = InvalidTagFieldValue
                    , tpiTagName = fromMaybe "" foundTag
                    , tpiMessage = msg
                    , tpiGuidance = Just guidance
                    , tpiLocation = loc
                    , tpiSuggestion = example
                    , tpiSpanLen = 0
                    }
    -- "must be a sequence ..." (ERR_4003)
    | "must be a sequence" `T.isPrefixOf` msg =
        let guidance = extractMustBeGuidance msg
            foundTag = findTagOnSourceLine allLines loc
            example = case foundTag of
                Just t -> let ex = tagExample t in if T.null ex then guessExampleFromMustBe msg else Just ex
                Nothing -> guessExampleFromMustBe msg
         in TagParsingError
                TagParsingInfo
                    { tpiErrorId = InvalidTagFieldValue
                    , tpiTagName = fromMaybe "" foundTag
                    , tpiMessage = msg
                    , tpiGuidance = Just guidance
                    , tpiLocation = loc
                    , tpiSuggestion = example
                    , tpiSpanLen = 0
                    }
    -- "must have exactly 2 elements to compare" (ERR_4003 for !$eq)
    | "must have exactly" `T.isPrefixOf` msg =
        TagParsingError
            TagParsingInfo
                { tpiErrorId = InvalidTagFieldValue
                , tpiTagName = "!$eq"
                , tpiMessage = msg
                , tpiGuidance = Just "use format: [value1, value2]"
                , tpiLocation = loc
                , tpiSuggestion = Just $ tagExample "!$eq"
                , tpiSpanLen = 0
                }
    -- "invalid format - must be string variable name" (ERR_4005)
    | "invalid format" `T.isPrefixOf` msg =
        TagParsingError
            TagParsingInfo
                { tpiErrorId = TagSyntaxError
                , tpiTagName = "!$"
                , tpiMessage = msg
                , tpiGuidance = Just "use string variable name"
                , tpiLocation = loc
                , tpiSuggestion = Just "!$ variable_name"
                , tpiSpanLen = 0
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
         in TypeMismatchError
                TypeMismatchInfo
                    { tmiErrorId = TypeMismatchInOperation
                    , tmiExpected = expected
                    , tmiFound = found
                    , tmiLocation = loc
                    , tmiContext = cleanMsg
                    , tmiHelp = generateTypeConversionHelp expected found
                    }
    -- JMESPath errors: "Invalid JMESPath expression 'expr': detail. Variable: path"
    | "Invalid JMESPath expression " `T.isPrefixOf` msg =
        let
            -- Extract variable path from ". Variable: path" suffix
            varPath = case T.breakOn ". Variable: " msg of
                (_, rest)
                    | not (T.null rest) ->
                        fromMaybe rest (T.stripPrefix ". Variable: " rest)
                _noVariableSuffix -> ""
            -- Strip the ". Variable: path" suffix for display message
            displayMsg = case T.breakOn ". Variable: " msg of
                (before, rest) | not (T.null rest) -> before
                _noVariableSuffix -> msg
         in
            LookupQueryError
                LookupQueryInfo
                    { lqiErrorId = LookupQueryFailed
                    , lqiVariablePath = varPath
                    , lqiMessage = displayMsg
                    , lqiLocation = loc
                    , lqiAvailableKeys = []
                    }
    -- Handlebars errors
    | "Handlebars error: " `T.isPrefixOf` msg =
        let detail = fromMaybe msg (T.stripPrefix "Handlebars error: " msg)
         in YamlSyntaxError
                YamlSyntaxInfo
                    { ysiErrorId = HandlebarsSyntaxError
                    , ysiShortMessage = detail
                    , ysiGuidance = "template syntax error"
                    , ysiLocation = loc
                    , ysiFixHint = Nothing
                    , ysiExample = Nothing
                    }
    -- Parse errors from !$parseYaml, !$parseJson, !$expand
    | "!$parseYaml: " `T.isPrefixOf` msg
        || "!$parseJson: " `T.isPrefixOf` msg
        || "!$expand parse error: " `T.isPrefixOf` msg
        || "!$expand: template '" `T.isPrefixOf` msg =
        YamlSyntaxError
            YamlSyntaxInfo
                { ysiErrorId = InvalidYamlSyntax
                , ysiShortMessage = msg
                , ysiGuidance = "parsing failed"
                , ysiLocation = loc
                , ysiFixHint = Nothing
                , ysiExample = Nothing
                }
    -- YAML syntax: "invalid YAML structure" / "unexpected end of file"
    | "invalid YAML" `T.isPrefixOf` msg =
        YamlSyntaxError
            YamlSyntaxInfo
                { ysiErrorId = InvalidYamlSyntax
                , ysiShortMessage = msg
                , ysiGuidance = "tags cannot be chained - use list syntax"
                , ysiLocation = loc
                , ysiFixHint = Just "put the inner tag in a list to separate it from the outer tag"
                , ysiExample = Just "!$not [!$eq [\"a\", \"b\"]]"
                }
    | "unexpected end" `T.isPrefixOf` msg =
        YamlSyntaxError
            YamlSyntaxInfo
                { ysiErrorId = InvalidYamlSyntax
                , ysiShortMessage = msg
                , ysiGuidance = "missing closing quote or bracket"
                , ysiLocation = loc
                , ysiFixHint = Nothing
                , ysiExample = Nothing
                }
    -- Fallback: treat as generic tag error
    | otherwise =
        TagParsingError
            TagParsingInfo
                { tpiErrorId = TagSyntaxError
                , tpiTagName = ""
                , tpiMessage = msg
                , tpiGuidance = Nothing
                , tpiLocation = loc
                , tpiSuggestion = Nothing
                , tpiSpanLen = 0
                }

-- | Classify import errors.
classifyImportError :: Text -> ImportError -> EnhancedPreprocessingError
classifyImportError filePath (ImportError msg) =
    let loc = SourceLocation filePath 0 0 ""
     in YamlSyntaxError
            YamlSyntaxInfo
                { ysiErrorId = ImportFileNotFound
                , ysiShortMessage = msg
                , ysiGuidance = "import failed"
                , ysiLocation = loc
                , ysiFixHint = Nothing
                , ysiExample = Nothing
                }

-- | Classify handlebars errors.
classifyHandlebarsError :: Text -> Text -> EnhancedPreprocessingError
classifyHandlebarsError filePath msg =
    YamlSyntaxError
        YamlSyntaxInfo
            { ysiErrorId = HandlebarsSyntaxError
            , ysiShortMessage = msg
            , ysiGuidance = "template syntax error"
            , ysiLocation = SourceLocation filePath 0 0 ""
            , ysiFixHint = Nothing
            , ysiExample = Nothing
            }
