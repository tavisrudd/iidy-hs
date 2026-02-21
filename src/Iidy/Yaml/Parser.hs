module Iidy.Yaml.Parser
  ( parseYaml
  , parseYamlFile
  , ParseError(..)
  ) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Map as Map
import Data.Scientific (Scientific)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.YAML as Y
import Data.YAML.Event (Tag, tagToText)
import Iidy.Yaml.Ast
import Iidy.Yaml.Location (Position(..), zeroPosition)

data ParseError = ParseError
  { pePosition :: !Position
  , peMessage  :: !Text
  } deriving stock (Show, Eq)

type Parse a = Either ParseError a

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

parseYaml :: BL.ByteString -> Text -> Parse YamlAst
parseYaml input uri =
  case Y.decodeNode input of
    Left (pos, msg) -> Left (ParseError (convertPos pos) (T.pack msg))
    Right []        -> Right (AstNull (emptyMeta uri))
    Right (Y.Doc node : _) -> convertNode uri node

parseYamlFile :: FilePath -> IO (Parse YamlAst)
parseYamlFile path = do
  input <- BL.readFile path
  pure (parseYaml input (T.pack path))

------------------------------------------------------------------------
-- Position helpers
------------------------------------------------------------------------

convertPos :: Y.Pos -> Position
convertPos p = Position
  { posLine   = Y.posLine p
  , posColumn = Y.posColumn p
  , posOffset = Y.posByteOffset p
  }

emptyMeta :: Text -> SrcMeta
emptyMeta uri = SrcMeta uri zeroPosition zeroPosition

makeSrcMeta :: Text -> Y.Pos -> SrcMeta
makeSrcMeta uri pos = SrcMeta uri (convertPos pos) (convertPos pos)

parseErrorAt :: SrcMeta -> Text -> Parse a
parseErrorAt meta msg = Left (ParseError (smStart meta) msg)

------------------------------------------------------------------------
-- Node conversion
------------------------------------------------------------------------

convertNode :: Text -> Y.Node Y.Pos -> Parse YamlAst
convertNode uri = \case
  Y.Scalar pos scalar -> convertScalar uri pos scalar
  Y.Mapping pos tag pairs -> convertMapping uri pos tag (Map.toList pairs)
  Y.Sequence pos tag items -> convertSequence uri pos tag items
  Y.Anchor _pos _nid inner -> convertNode uri inner

convertScalar :: Text -> Y.Pos -> Y.Scalar -> Parse YamlAst
convertScalar uri pos = \case
  Y.SNull      -> pure $ AstNull meta
  Y.SBool b    -> pure $ AstBool b meta
  Y.SInt i     -> pure $ AstNumber (fromInteger i) meta
  Y.SFloat d   -> pure $ AstNumber (realToFrac d :: Scientific) meta
  Y.SStr text  -> pure $ classifyString meta text
  Y.SUnknown tag text -> case tagToText tag of
    Just t  -> classifyLocalTag meta t (AstPlainString text meta)
    Nothing -> pure $ classifyString meta text
  where
    meta = makeSrcMeta uri pos

convertMapping :: Text -> Y.Pos -> Tag -> [(Y.Node Y.Pos, Y.Node Y.Pos)] -> Parse YamlAst
convertMapping uri pos tag pairs = do
  let meta = makeSrcMeta uri pos
  converted <- traverse convertPair pairs
  case localTagText tag of
    Just t  -> classifyLocalTag meta t (AstMapping converted meta)
    Nothing -> pure $ AstMapping converted meta
  where
    convertPair (k, v) = (,) <$> convertNode uri k <*> convertNode uri v

convertSequence :: Text -> Y.Pos -> Tag -> [Y.Node Y.Pos] -> Parse YamlAst
convertSequence uri pos tag items = do
  let meta = makeSrcMeta uri pos
  converted <- traverse (convertNode uri) items
  case localTagText tag of
    Just t  -> classifyLocalTag meta t (AstSequence converted meta)
    Nothing -> pure $ AstSequence converted meta

------------------------------------------------------------------------
-- Tag helpers
------------------------------------------------------------------------

localTagText :: Tag -> Maybe Text
localTagText tag = case tagToText tag of
  Just t | "!" `T.isPrefixOf` t -> Just t
  _ -> Nothing

isPreprocessingTagName :: Text -> Bool
isPreprocessingTagName t = t == "!$" || "!$" `T.isPrefixOf` t

cfnTagNames :: [Text]
cfnTagNames =
  [ "!Ref", "!Sub", "!GetAtt", "!Join", "!Select", "!Split", "!Base64"
  , "!GetAZs", "!ImportValue", "!FindInMap", "!Cidr", "!Length"
  , "!ToJsonString", "!Transform", "!ForEach", "!If", "!Equals"
  , "!And", "!Or", "!Not"
  ]

isCfnTagName :: Text -> Bool
isCfnTagName t = t `elem` cfnTagNames

classifyLocalTag :: SrcMeta -> Text -> YamlAst -> Parse YamlAst
classifyLocalTag meta tagName value
  | isPreprocessingTagName tagName = parsePreprocessingTag meta tagName value
  | isCfnTagName tagName = pure $ AstCloudFormationTag (makeCfnTag tagName value) meta
  | otherwise = pure $ AstUnknownTag (UnknownTag tagName value) meta

classifyString :: SrcMeta -> Text -> YamlAst
classifyString meta text
  | "{{" `T.isInfixOf` text = AstTemplatedString text meta
  | otherwise = AstPlainString text meta

------------------------------------------------------------------------
-- CloudFormation tag construction
------------------------------------------------------------------------

makeCfnTag :: Text -> YamlAst -> CloudFormationTag
makeCfnTag = \case
  "!Ref"         -> CfnRef
  "!Sub"         -> CfnSub
  "!GetAtt"      -> CfnGetAtt
  "!Join"        -> CfnJoin
  "!Select"      -> CfnSelect
  "!Split"       -> CfnSplit
  "!Base64"      -> CfnBase64
  "!GetAZs"      -> CfnGetAZs
  "!ImportValue" -> CfnImportValue
  "!FindInMap"   -> CfnFindInMap
  "!Cidr"        -> CfnCidr
  "!Length"      -> CfnLength
  "!ToJsonString" -> CfnToJsonString
  "!Transform"   -> CfnTransform
  "!ForEach"     -> CfnForEach
  "!If"          -> CfnIf
  "!Equals"      -> CfnEquals
  "!And"         -> CfnAnd
  "!Or"          -> CfnOr
  "!Not"         -> CfnNot
  _              -> CfnRef  -- unreachable given isCfnTagName guard

------------------------------------------------------------------------
-- Preprocessing tag parsing
------------------------------------------------------------------------

parsePreprocessingTag :: SrcMeta -> Text -> YamlAst -> Parse YamlAst
parsePreprocessingTag meta tagName value = case tagName of
  "!$"              -> parseVarLookupTag meta value
  "!$include"       -> parseVarLookupTag meta value
  "!$if"            -> parseIfTag meta value
  "!$map"           -> parseMapLikeTag meta "!$map" mkMapTag value
  "!$merge"         -> parseSeqTag meta "!$merge" (PpMerge . MergeTag) value
  "!$concat"        -> parseSeqTag meta "!$concat" (PpConcat . ConcatTag) value
  "!$let"           -> parseLetTag meta value
  "!$eq"            -> parsePairTag meta "!$eq" (\a b -> PpEq (EqTag a b)) value
  "!$not"           -> parseNotTag meta value
  "!$split"         -> parsePairTag meta "!$split" (\a b -> PpSplit (SplitTag a b)) value
  "!$join"          -> parsePairTag meta "!$join" (\a b -> PpJoin (JoinTag a b)) value
  "!$concatMap"     -> parseMapLikeTag meta "!$concatMap" mkConcatMapTag value
  "!$mergeMap"      -> parseMergeMapTag meta value
  "!$mapListToHash" -> parseMapLikeTag meta "!$mapListToHash" mkMapListToHashTag value
  "!$mapValues"     -> parseMapValuesTag meta value
  "!$groupBy"       -> parseGroupByTag meta value
  "!$fromPairs"     -> wrapSingle meta (PpFromPairs . FromPairsTag) value
  "!$toYamlString"  -> wrapSingle meta (PpToYamlString . ToYamlStringTag) value
  "!$string"        -> wrapSingle meta (PpToYamlString . ToYamlStringTag) value
  "!$parseYaml"     -> wrapSingle meta (PpParseYaml . ParseYamlTag) value
  "!$toJsonString"  -> wrapSingle meta (PpToJsonString . ToJsonStringTag) value
  "!$parseJson"     -> wrapSingle meta (PpParseJson . ParseJsonTag) value
  "!$escape"        -> wrapSingle meta (PpEscape . EscapeTag) value
  "!$expand"        -> parseExpandTag meta value
  _                 -> pure $ AstUnknownTag (UnknownTag tagName value) meta

wrapSingle :: SrcMeta -> (YamlAst -> PreprocessingTag) -> YamlAst -> Parse YamlAst
wrapSingle meta mk value = pure $ AstPreprocessingTag (mk (unwrapSingle value)) meta

unwrapSingle :: YamlAst -> YamlAst
unwrapSingle (AstSequence [x] _) = x
unwrapSingle x = x

parsePairTag :: SrcMeta -> Text -> (YamlAst -> YamlAst -> PreprocessingTag) -> YamlAst -> Parse YamlAst
parsePairTag meta name mk = \case
  AstSequence [a, b] _ -> pure $ AstPreprocessingTag (mk a b) meta
  _ -> parseErrorAt meta (name <> " requires a 2-element sequence")

parseSeqTag :: SrcMeta -> Text -> ([YamlAst] -> PreprocessingTag) -> YamlAst -> Parse YamlAst
parseSeqTag meta name mk = \case
  AstSequence items _ -> pure $ AstPreprocessingTag (mk items) meta
  _ -> parseErrorAt meta (name <> " requires a sequence")

parseVarLookupTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseVarLookupTag meta = \case
  AstPlainString path _ ->
    pure $ AstPreprocessingTag (PpVarLookup (VarLookupTag path Nothing Nothing)) meta
  AstTemplatedString path _ ->
    pure $ AstPreprocessingTag (PpVarLookup (VarLookupTag path Nothing Nothing)) meta
  AstMapping pairs _ ->
    case getTextField "path" pairs of
      Just path -> pure $ AstPreprocessingTag
        (PpVarLookup (VarLookupTag path (getTextField "query" pairs) (getTextField "jmespath" pairs))) meta
      Nothing -> parseErrorAt meta "!$ requires 'path' field"
  _ -> parseErrorAt meta "!$ requires a string or mapping"

parseIfTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseIfTag meta = \case
  AstMapping pairs _ ->
    case (getField "test" pairs, getField "then" pairs) of
      (Just test, Just thenVal) ->
        pure $ AstPreprocessingTag
          (PpIf (IfTag test thenVal (getField "else" pairs))) meta
      _ -> parseErrorAt meta "!$if requires 'test' and 'then' fields"
  _ -> parseErrorAt meta "!$if requires a mapping"

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
      (Just items, Just templ) ->
        pure $ AstPreprocessingTag
          (mk items templ (getTextField "var" pairs) (getField "filter" pairs)) meta
      _ -> parseErrorAt meta (name <> " requires 'items' and 'template' fields")
  _ -> parseErrorAt meta (name <> " requires a mapping")

parseLetTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseLetTag meta = \case
  AstMapping pairs _ ->
    let bindings = [(t, v) | (k, v) <- pairs, Just t <- [getScalarText k], t /= "in"]
        expr = getField "in" pairs
    in case expr of
      Just e  -> pure $ AstPreprocessingTag (PpLet (LetTag bindings e)) meta
      Nothing -> parseErrorAt meta "!$let requires 'in' field"
  _ -> parseErrorAt meta "!$let requires a mapping"

parseNotTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseNotTag meta value =
  pure $ AstPreprocessingTag (PpNot (NotTag (unwrapSingle value))) meta

parseMergeMapTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseMergeMapTag meta = \case
  AstMapping pairs _ ->
    case (getField "items" pairs, getField "template" pairs) of
      (Just items, Just templ) ->
        pure $ AstPreprocessingTag
          (PpMergeMap (MergeMapTag items templ (getTextField "var" pairs))) meta
      _ -> parseErrorAt meta "!$mergeMap requires 'items' and 'template' fields"
  _ -> parseErrorAt meta "!$mergeMap requires a mapping"

parseMapValuesTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseMapValuesTag meta = \case
  AstMapping pairs _ ->
    case (getField "items" pairs, getField "template" pairs) of
      (Just items, Just templ) ->
        pure $ AstPreprocessingTag
          (PpMapValues (MapValuesTag items templ (getTextField "var" pairs))) meta
      _ -> parseErrorAt meta "!$mapValues requires 'items' and 'template' fields"
  _ -> parseErrorAt meta "!$mapValues requires a mapping"

parseGroupByTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseGroupByTag meta = \case
  AstMapping pairs _ ->
    case (getField "items" pairs, getField "key" pairs) of
      (Just items, Just key) ->
        pure $ AstPreprocessingTag
          (PpGroupBy (GroupByTag items key (getTextField "var" pairs) (getField "template" pairs))) meta
      _ -> parseErrorAt meta "!$groupBy requires 'items' and 'key' fields"
  _ -> parseErrorAt meta "!$groupBy requires a mapping"

parseExpandTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseExpandTag meta = \case
  AstMapping pairs _ ->
    case (getField "template" pairs, getField "params" pairs) of
      (Just templ, Just params) ->
        pure $ AstPreprocessingTag (PpExpand (ExpandTag templ params)) meta
      _ -> parseErrorAt meta "!$expand requires 'template' and 'params' fields"
  _ -> parseErrorAt meta "!$expand requires a mapping"

------------------------------------------------------------------------
-- Field extraction helpers
------------------------------------------------------------------------

getScalarText :: YamlAst -> Maybe Text
getScalarText (AstPlainString t _)     = Just t
getScalarText (AstTemplatedString t _) = Just t
getScalarText _                        = Nothing

getField :: Text -> [(YamlAst, YamlAst)] -> Maybe YamlAst
getField name pairs =
  case [v | (k, v) <- pairs, getScalarText k == Just name] of
    (v:_) -> Just v
    []    -> Nothing

getTextField :: Text -> [(YamlAst, YamlAst)] -> Maybe Text
getTextField name pairs = getField name pairs >>= getScalarText
