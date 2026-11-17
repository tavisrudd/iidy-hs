-- | Turning a local YAML tag and its parsed argument into a tagged AST node.
module Iidy.Yaml.Parser.Tags (
    ParseError (..),
    Parse,
    classifyLocalTag,
) where

import Data.Text (Text)
import Data.Text qualified as T
import Iidy.Yaml.Ast
import Iidy.Yaml.Location (Position (..))

data ParseError = ParseError
    { pePosition :: !Position
    , peMessage :: !Text
    }
    deriving stock (Show, Eq)

type Parse a = Either ParseError a

parseErrorAt :: SrcMeta -> Text -> Parse a
parseErrorAt meta msg = Left (ParseError (smStart meta) msg)

classifyLocalTag :: SrcMeta -> Text -> YamlAst -> Parse YamlAst
classifyLocalTag meta tagName value
    | isPreprocessingTagName tagName = parsePreprocessingTag meta tagName value
    | isCfnTagName tagName = pure $ AstCloudFormationTag (makeCfnTag tagName value) meta
    | otherwise = pure $ AstUnknownTag (UnknownTag tagName value) meta

------------------------------------------------------------------------
-- Tag classification
------------------------------------------------------------------------

isPreprocessingTagName :: Text -> Bool
isPreprocessingTagName t = t == "!$" || "!$" `T.isPrefixOf` t

cfnTagNames :: [Text]
cfnTagNames =
    [ "!Ref"
    , "!Sub"
    , "!GetAtt"
    , "!Join"
    , "!Select"
    , "!Split"
    , "!Base64"
    , "!GetAZs"
    , "!ImportValue"
    , "!FindInMap"
    , "!Cidr"
    , "!Length"
    , "!ToJsonString"
    , "!Transform"
    , "!ForEach"
    , "!If"
    , "!Equals"
    , "!And"
    , "!Or"
    , "!Not"
    ]

isCfnTagName :: Text -> Bool
isCfnTagName t = t `elem` cfnTagNames

------------------------------------------------------------------------
-- CloudFormation tag construction
------------------------------------------------------------------------

makeCfnTag :: Text -> YamlAst -> CloudFormationTag
makeCfnTag = \case
    "!Ref" -> CfnRef
    "!Sub" -> CfnSub
    "!GetAtt" -> CfnGetAtt
    "!Join" -> CfnJoin
    "!Select" -> CfnSelect
    "!Split" -> CfnSplit
    "!Base64" -> CfnBase64
    "!GetAZs" -> CfnGetAZs
    "!ImportValue" -> CfnImportValue
    "!FindInMap" -> CfnFindInMap
    "!Cidr" -> CfnCidr
    "!Length" -> CfnLength
    "!ToJsonString" -> CfnToJsonString
    "!Transform" -> CfnTransform
    "!ForEach" -> CfnForEach
    "!If" -> CfnIf
    "!Equals" -> CfnEquals
    "!And" -> CfnAnd
    "!Or" -> CfnOr
    "!Not" -> CfnNot
    _unreachable -> CfnRef -- unreachable given isCfnTagName guard

------------------------------------------------------------------------
-- Preprocessing tag parsing
------------------------------------------------------------------------

parsePreprocessingTag :: SrcMeta -> Text -> YamlAst -> Parse YamlAst
parsePreprocessingTag meta tagName value = case tagName of
    "!$" -> parseVarLookupTag meta value
    "!$include" -> parseVarLookupTag meta value
    "!$if" -> parseIfTag meta value
    "!$map" -> parseMapLikeTag meta "!$map" mkMapTag value
    "!$merge" -> parseSeqTag meta "!$merge" "of objects to merge" (PpMerge . MergeTag) value
    "!$concat" -> parseSeqTag meta "!$concat" "of arrays to concatenate" (PpConcat . ConcatTag) value
    "!$let" -> parseLetTag meta value
    "!$eq" -> parsePairTag meta "!$eq" "[value1, value2]" (\a b -> PpEq (EqTag a b)) value
    "!$not" -> parseNotTag meta value
    "!$split" -> parsePairTag meta "!$split" "[delimiter, string]" (\a b -> PpSplit (SplitTag a b)) value
    "!$join" -> parsePairTag meta "!$join" "[delimiter, array]" (\a b -> PpJoin (JoinTag a b)) value
    "!$concatMap" -> parseMapLikeTag meta "!$concatMap" mkConcatMapTag value
    "!$mergeMap" -> parseMergeMapTag meta value
    "!$mapListToHash" -> parseMapLikeTag meta "!$mapListToHash" mkMapListToHashTag value
    "!$mapValues" -> parseMapValuesTag meta value
    "!$groupBy" -> parseGroupByTag meta value
    "!$fromPairs" -> wrapSingle meta (PpFromPairs . FromPairsTag) value
    "!$toYamlString" -> wrapSingle meta (PpToYamlString . ToYamlStringTag) value
    "!$string" -> wrapSingle meta (PpToYamlString . ToYamlStringTag) value
    "!$parseYaml" -> wrapSingle meta (PpParseYaml . ParseYamlTag) value
    "!$toJsonString" -> wrapSingle meta (PpToJsonString . ToJsonStringTag) value
    "!$parseJson" -> wrapSingle meta (PpParseJson . ParseJsonTag) value
    "!$escape" -> wrapSingle meta (PpEscape . EscapeTag) value
    "!$expand" -> parseExpandTag meta value
    _unknownTag -> parseErrorAt meta ("'" <> tagName <> "' is not a valid iidy tag")

wrapSingle :: SrcMeta -> (YamlAst -> PreprocessingTag) -> YamlAst -> Parse YamlAst
wrapSingle meta mk value = pure $ AstPreprocessingTag (mk (unwrapSingle value)) meta

unwrapSingle :: YamlAst -> YamlAst
unwrapSingle (AstSequence [x] _) = x
unwrapSingle x = x

parsePairTag :: SrcMeta -> Text -> Text -> (YamlAst -> YamlAst -> PreprocessingTag) -> YamlAst -> Parse YamlAst
parsePairTag meta name format mk = \case
    AstSequence [a, b] _ -> pure $ AstPreprocessingTag (mk a b) meta
    AstSequence _ _ ->
        parseErrorAt
            meta
            ( if name == "!$eq"
                then "must have exactly 2 elements to compare"
                else "must be a sequence with format " <> format
            )
    _nonSequence ->
        parseErrorAt
            meta
            ( if name == "!$eq"
                then "must be a sequence with exactly 2 elements"
                else "must be a sequence with format " <> format
            )

parseSeqTag :: SrcMeta -> Text -> Text -> ([YamlAst] -> PreprocessingTag) -> YamlAst -> Parse YamlAst
parseSeqTag meta _name desc mk = \case
    AstSequence items _ -> pure $ AstPreprocessingTag (mk items) meta
    _nonSequence -> parseErrorAt meta ("must be a sequence " <> desc)

parseVarLookupTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseVarLookupTag meta = \case
    AstPlainString raw _ ->
        let (path, query) = splitVarQuery raw
         in pure $ AstPreprocessingTag (PpVarLookup (VarLookupTag path query Nothing)) meta
    AstTemplatedString raw _ ->
        let (path, query) = splitVarQuery raw
         in pure $ AstPreprocessingTag (PpVarLookup (VarLookupTag path query Nothing)) meta
    AstMapping pairs _ -> do
        validateFields ["path"] ["query", "jmespath"] pairs
        case getTextField "path" pairs of
            Just path -> do
                let queryField = getTextField "query" pairs
                    jmespathField = getTextField "jmespath" pairs
                case (queryField, jmespathField) of
                    (Just _, Just _) -> parseErrorAt meta "'query' and 'jmespath' are mutually exclusive"
                    _notBothPresent ->
                        pure $
                            AstPreprocessingTag
                                (PpVarLookup (VarLookupTag path queryField jmespathField))
                                meta
            Nothing -> parseErrorAt meta "'path' missing in !$ tag"
    _nonStringOrMapping -> parseErrorAt meta "invalid format - must be string variable name"

parseIfTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseIfTag meta = \case
    AstMapping pairs _ ->
        case (getField "test" pairs, getField "then" pairs) of
            (Just test, Just thenVal) -> do
                validateFields ["test", "then"] ["else"] pairs
                pure $
                    AstPreprocessingTag
                        (PpIf (IfTag test thenVal (getField "else" pairs)))
                        meta
            (Nothing, _) -> parseErrorAt meta "'test' missing in !$if tag"
            (_, Nothing) -> parseErrorAt meta "'then' missing in !$if tag"
    _nonMapping -> parseErrorAt meta "must be a mapping with required 'test' and 'then' fields"

type MkMapLike = YamlAst -> YamlAst -> Maybe Text -> Maybe YamlAst -> PreprocessingTag

mkMapTag :: MkMapLike
mkMapTag items templ var filt = PpMap (MapTag items templ var filt)

mkConcatMapTag :: MkMapLike
mkConcatMapTag items templ var filt = PpConcatMap (ConcatMapTag items templ var filt)

mkMapListToHashTag :: MkMapLike
mkMapListToHashTag items templ var filt = PpMapListToHash (MapListToHashTag items templ var filt)

parseMapLikeTag :: SrcMeta -> Text -> MkMapLike -> YamlAst -> Parse YamlAst
parseMapLikeTag meta name mk = \case
    AstMapping pairs _ ->
        case (getField "items" pairs, getField "template" pairs) of
            (Just items, Just templ) -> do
                validateFields ["items", "template"] ["var", "filter"] pairs
                pure $
                    AstPreprocessingTag
                        (mk items templ (getTextField "var" pairs) (getField "filter" pairs))
                        meta
            (Nothing, _) -> parseErrorAt meta ("'items' missing in " <> name <> " tag")
            (_, Nothing) -> parseErrorAt meta ("'template' missing in " <> name <> " tag")
    _nonMapping -> parseErrorAt meta "must be a mapping with 'items' and 'template' fields"

parseLetTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseLetTag meta = \case
    AstMapping pairs _ ->
        let bindings = [(t, v) | (k, v) <- pairs, Just t <- [getScalarText k], t /= "in"]
            expr = getField "in" pairs
         in case expr of
                Just e -> pure $ AstPreprocessingTag (PpLet (LetTag bindings e)) meta
                Nothing -> parseErrorAt meta "missing required 'in' field"
    _nonMapping -> parseErrorAt meta "must be a mapping with variable bindings and 'in' field"

parseNotTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseNotTag meta value =
    pure $ AstPreprocessingTag (PpNot (NotTag (unwrapSingle value))) meta

parseMergeMapTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseMergeMapTag meta = \case
    AstMapping pairs _ ->
        case (getField "items" pairs, getField "template" pairs) of
            (Just items, Just templ) -> do
                validateFields ["items", "template"] ["var"] pairs
                pure $
                    AstPreprocessingTag
                        (PpMergeMap (MergeMapTag items templ (getTextField "var" pairs)))
                        meta
            (Nothing, _) -> parseErrorAt meta "'items' missing in !$mergeMap tag"
            (_, Nothing) -> parseErrorAt meta "'template' missing in !$mergeMap tag"
    _nonMapping -> parseErrorAt meta "must be a mapping with 'items' and 'template' fields"

parseMapValuesTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseMapValuesTag meta = \case
    AstMapping pairs _ ->
        case (getField "items" pairs, getField "template" pairs) of
            (Just items, Just templ) -> do
                validateFields ["items", "template"] ["var"] pairs
                pure $
                    AstPreprocessingTag
                        (PpMapValues (MapValuesTag items templ (getTextField "var" pairs)))
                        meta
            (Nothing, _) -> parseErrorAt meta "'items' missing in !$mapValues tag"
            (_, Nothing) -> parseErrorAt meta "'template' missing in !$mapValues tag"
    _nonMapping -> parseErrorAt meta "must be a mapping with 'items' and 'template' fields"

parseGroupByTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseGroupByTag meta = \case
    AstMapping pairs _ ->
        case (getField "items" pairs, getField "key" pairs) of
            (Just items, Just key) -> do
                validateFields ["items", "key"] ["var", "template"] pairs
                pure $
                    AstPreprocessingTag
                        (PpGroupBy (GroupByTag items key (getTextField "var" pairs) (getField "template" pairs)))
                        meta
            (Nothing, _) -> parseErrorAt meta "'items' missing in !$groupBy tag"
            (_, Nothing) -> parseErrorAt meta "'key' missing in !$groupBy tag"
    _nonMapping -> parseErrorAt meta "must be a mapping with 'items' and 'key' fields"

parseExpandTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseExpandTag meta = \case
    AstMapping pairs _ ->
        case (getField "template" pairs, getField "params" pairs) of
            (Just templ, Just params) -> do
                validateFields ["template", "params"] [] pairs
                pure $ AstPreprocessingTag (PpExpand (ExpandTag templ params)) meta
            (Nothing, _) -> parseErrorAt meta "'template' missing in !$expand tag"
            (_, Nothing) -> parseErrorAt meta "'params' missing in !$expand tag"
    _nonMapping -> parseErrorAt meta "must be a mapping with 'template' and 'params' fields"

------------------------------------------------------------------------
-- Field validation
------------------------------------------------------------------------

-- | Check for unknown fields in a tag mapping. Errors on the first unknown field.
validateFields :: [Text] -> [Text] -> [(YamlAst, YamlAst)] -> Parse ()
validateFields required optional pairs =
    let allValid = required ++ optional
        unknowns = [(t, astMeta k) | (k, _) <- pairs, Just t <- [getScalarText k], t `notElem` allValid]
     in case unknowns of
            ((unknown, keyMeta) : _) ->
                let optFormatted = map (<> " (optional)") optional
                    allFormatted = required ++ optFormatted
                 in parseErrorAt keyMeta $
                        "unexpected field '" <> unknown <> "'\n\nValid fields are: " <> T.intercalate ", " allFormatted
            [] -> pure ()

------------------------------------------------------------------------
-- Field extraction helpers
------------------------------------------------------------------------

getScalarText :: YamlAst -> Maybe Text
getScalarText (AstPlainString t _) = Just t
getScalarText (AstTemplatedString t _) = Just t
getScalarText _ = Nothing

getField :: Text -> [(YamlAst, YamlAst)] -> Maybe YamlAst
getField name pairs =
    case [v | (k, v) <- pairs, getScalarText k == Just name] of
        (v : _) -> Just v
        [] -> Nothing

getTextField :: Text -> [(YamlAst, YamlAst)] -> Maybe Text
getTextField name pairs = getField name pairs >>= getScalarText

splitVarQuery :: Text -> (Text, Maybe Text)
splitVarQuery raw = case T.breakOn "?" raw of
    (path, rest)
        | T.null rest -> (path, Nothing)
        | otherwise -> (path, Just (T.drop 1 rest))
