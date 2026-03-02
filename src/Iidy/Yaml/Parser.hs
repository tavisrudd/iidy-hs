module Iidy.Yaml.Parser
  ( parseYaml
  , parseYamlFile
  , ParseError(..)
  ) where

import qualified Data.ByteString.Lazy as BL
import Data.Char (isDigit)
import qualified Data.List as List
import Data.Functor.Identity (Identity(..))
import Data.Scientific (Scientific)
import qualified Data.Scientific as Sci
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.YAML as Y
import Data.YAML.Event (Tag, ScalarStyle(..), tagToText)
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
  let -- Ensure trailing newline for HsYAML compatibility
      input' = if BL.null input || BL.last input /= 0x0a
               then input <> "\n"
               else input
  in case runIdentity (Y.decodeLoader (yamlLoader uri) input') of
    Left (pos, msg) -> Left (ParseError (convertPos pos) (T.pack msg))
    Right []        -> Right (AstNull (emptyMeta uri))
    Right (node : _) -> Right node

parseYamlFile :: FilePath -> IO (Parse YamlAst)
parseYamlFile path = do
  input <- BL.readFile path
  pure (parseYaml input (T.pack path))

------------------------------------------------------------------------
-- Loader (preserves document key order)
------------------------------------------------------------------------

yamlLoader :: Text -> Y.Loader Identity YamlAst
yamlLoader uri = Y.Loader
  { Y.yScalar = \tag style text pos -> pure $
      resolveScalar uri pos tag style text
  , Y.ySequence = \tag items pos -> pure $
      let startP = convertPos pos
          endP = childrenEndPos startP (map astMeta items)
          meta = SrcMeta uri startP endP
      in applyTag meta tag (AstSequence items meta)
  , Y.yMapping = \tag kvs pos -> pure $
      let startP = convertPos pos
          endP = childrenEndPos startP (map (astMeta . snd) kvs)
          meta = SrcMeta uri startP endP
      in applyTag meta tag (AstMapping kvs meta)
  , Y.yAlias = \_ _ node _ -> pure $ Right node
  , Y.yAnchor = \_ node _ -> pure $ Right node
  }

------------------------------------------------------------------------
-- Scalar resolution (Core schema)
------------------------------------------------------------------------

resolveScalar :: Text -> Y.Pos -> Tag -> ScalarStyle -> Text -> Either (Y.Pos, String) YamlAst
resolveScalar uri pos tag style text =
  let meta = makeScalarMeta uri pos tag text
  in case tagToText tag of
    Just t | "!" `T.isPrefixOf` t ->
      -- Local tag on scalar: resolve the scalar type first, then apply tag
      let baseNode = case style of
            Plain -> resolvePlainScalar meta text
            _     -> classifyString meta text
      in mapLeft (\(ParseError p m) -> (unconvertPos p, T.unpack m)) $
        classifyLocalTag meta t baseNode
    _ ->
      -- Untagged or global-tagged: resolve type
      Right $ case style of
        Plain -> resolvePlainScalar meta text
        _     -> classifyString meta text

resolvePlainScalar :: SrcMeta -> Text -> YamlAst
resolvePlainScalar meta text
  | isNullLiteral text  = AstNull meta
  | text == "true"  || text == "True"  || text == "TRUE"  = AstBool True meta
  | text == "false" || text == "False" || text == "FALSE" = AstBool False meta
  | Just n <- parseInteger text = AstNumber (fromInteger n) meta
  | Just n <- parseFloat text   = AstNumber n meta
  | otherwise = classifyString meta text

isNullLiteral :: Text -> Bool
isNullLiteral t = t == "null" || t == "Null" || t == "NULL" || t == "~" || T.null t

parseInteger :: Text -> Maybe Integer
parseInteger t
  | T.null t = Nothing
  | T.isPrefixOf "0x" t || T.isPrefixOf "0X" t =
      readMaybe (T.unpack t)
  | T.isPrefixOf "0o" t || T.isPrefixOf "0O" t =
      readMaybe (T.unpack t)
  | T.isPrefixOf "-" t || T.isPrefixOf "+" t =
      let rest = T.drop 1 t
      in if not (T.null rest) && T.all isDigit rest
         then readMaybe (T.unpack t)
         else Nothing
  | T.all isDigit t = readMaybe (T.unpack t)
  | otherwise = Nothing

parseFloat :: Text -> Maybe Scientific
parseFloat t
  | t == ".inf" || t == ".Inf" || t == ".INF"   = Just (Sci.fromFloatDigits (1/0 :: Double))
  | t == "-.inf" || t == "-.Inf" || t == "-.INF" = Just (Sci.fromFloatDigits ((-1)/0 :: Double))
  | t == ".nan" || t == ".NaN" || t == ".NAN"   = Just (Sci.fromFloatDigits (0/0 :: Double))
  | hasFloatChars t = case reads (T.unpack t) :: [(Double, String)] of
      [(d, "")] -> Just (Sci.fromFloatDigits d)
      _ -> Nothing
  | otherwise = Nothing
  where
    hasFloatChars s = T.any (== '.') s || T.any (== 'e') s || T.any (== 'E') s

readMaybe :: Read a => String -> Maybe a
readMaybe s = case reads s of
  [(a, "")] -> Just a
  _         -> Nothing

------------------------------------------------------------------------
-- Tag handling
------------------------------------------------------------------------

applyTag :: SrcMeta -> Tag -> YamlAst -> Either (Y.Pos, String) YamlAst
applyTag meta tag node = case tagToText tag of
  Just t | "!" `T.isPrefixOf` t ->
    mapLeft (\(ParseError p m) -> (unconvertPos p, T.unpack m)) $
      classifyLocalTag meta t node
  _ -> Right node

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
-- Position helpers
------------------------------------------------------------------------

convertPos :: Y.Pos -> Position
convertPos p = Position
  { posLine   = Y.posLine p
  , posColumn = Y.posColumn p
  , posOffset = Y.posByteOffset p
  }

unconvertPos :: Position -> Y.Pos
unconvertPos p = Y.Pos
  { Y.posLine       = posLine p
  , Y.posColumn     = posColumn p
  , Y.posByteOffset = posOffset p
  , Y.posCharOffset = posOffset p
  }

emptyMeta :: Text -> SrcMeta
emptyMeta uri = SrcMeta uri zeroPosition zeroPosition

-- | Create SrcMeta for a scalar value with end position computed from text length.
-- The end position accounts for the tag prefix (e.g., "!Ref ") if present.
makeScalarMeta :: Text -> Y.Pos -> Tag -> Text -> SrcMeta
makeScalarMeta uri pos tag text =
  let startP = convertPos pos
      tagLen = case tagToText tag of
        Just t | "!" `T.isPrefixOf` t -> T.length t + 1  -- tag + space
        _ -> 0
      textLen = T.length text
      endP = startP { posColumn = posColumn startP + tagLen + textLen
                     , posOffset = posOffset startP + tagLen + textLen
                     }
  in SrcMeta uri startP endP

-- | Compute end position from a list of child node metadata.
-- Uses the end position of the last child, or falls back to the start position.
childrenEndPos :: Position -> [SrcMeta] -> Position
childrenEndPos startP metas = List.foldl' (\_ x -> smEnd x) startP metas

parseErrorAt :: SrcMeta -> Text -> Parse a
parseErrorAt meta msg = Left (ParseError (smStart meta) msg)

------------------------------------------------------------------------
-- Error mapping
------------------------------------------------------------------------

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f (Left a) = Left (f a)
mapLeft _ (Right c) = Right c

------------------------------------------------------------------------
-- Tag classification
------------------------------------------------------------------------

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
  "!$merge"         -> parseSeqTag meta "!$merge" "of objects to merge" (PpMerge . MergeTag) value
  "!$concat"        -> parseSeqTag meta "!$concat" "of arrays to concatenate" (PpConcat . ConcatTag) value
  "!$let"           -> parseLetTag meta value
  "!$eq"            -> parsePairTag meta "!$eq" "[value1, value2]" (\a b -> PpEq (EqTag a b)) value
  "!$not"           -> parseNotTag meta value
  "!$split"         -> parsePairTag meta "!$split" "[delimiter, string]" (\a b -> PpSplit (SplitTag a b)) value
  "!$join"          -> parsePairTag meta "!$join" "[delimiter, array]" (\a b -> PpJoin (JoinTag a b)) value
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
  _                 -> parseErrorAt meta ("'" <> tagName <> "' is not a valid iidy tag")

wrapSingle :: SrcMeta -> (YamlAst -> PreprocessingTag) -> YamlAst -> Parse YamlAst
wrapSingle meta mk value = pure $ AstPreprocessingTag (mk (unwrapSingle value)) meta

unwrapSingle :: YamlAst -> YamlAst
unwrapSingle (AstSequence [x] _) = x
unwrapSingle x = x

parsePairTag :: SrcMeta -> Text -> Text -> (YamlAst -> YamlAst -> PreprocessingTag) -> YamlAst -> Parse YamlAst
parsePairTag meta name format mk = \case
  AstSequence [a, b] _ -> pure $ AstPreprocessingTag (mk a b) meta
  AstSequence _ _ -> parseErrorAt meta (if name == "!$eq"
    then "must have exactly 2 elements to compare"
    else "must be a sequence with format " <> format)
  _ -> parseErrorAt meta (if name == "!$eq"
    then "must be a sequence with exactly 2 elements"
    else "must be a sequence with format " <> format)

parseSeqTag :: SrcMeta -> Text -> Text -> ([YamlAst] -> PreprocessingTag) -> YamlAst -> Parse YamlAst
parseSeqTag meta _name desc mk = \case
  AstSequence items _ -> pure $ AstPreprocessingTag (mk items) meta
  _ -> parseErrorAt meta ("must be a sequence " <> desc)

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
          _ -> pure $ AstPreprocessingTag
            (PpVarLookup (VarLookupTag path queryField jmespathField)) meta
      Nothing -> parseErrorAt meta "'path' missing in !$ tag"
  _ -> parseErrorAt meta "invalid format - must be string variable name"

parseIfTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseIfTag meta = \case
  AstMapping pairs _ ->
    case (getField "test" pairs, getField "then" pairs) of
      (Just test, Just thenVal) -> do
        validateFields ["test", "then"] ["else"] pairs
        pure $ AstPreprocessingTag
          (PpIf (IfTag test thenVal (getField "else" pairs))) meta
      (Nothing, _) -> parseErrorAt meta "'test' missing in !$if tag"
      (_, Nothing) -> parseErrorAt meta "'then' missing in !$if tag"
  _ -> parseErrorAt meta "must be a mapping with required 'test' and 'then' fields"

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
        pure $ AstPreprocessingTag
          (mk items templ (getTextField "var" pairs) (getField "filter" pairs)) meta
      (Nothing, _) -> parseErrorAt meta ("'items' missing in " <> name <> " tag")
      (_, Nothing) -> parseErrorAt meta ("'template' missing in " <> name <> " tag")
  _ -> parseErrorAt meta ("must be a mapping with 'items' and 'template' fields")

parseLetTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseLetTag meta = \case
  AstMapping pairs _ ->
    let bindings = [(t, v) | (k, v) <- pairs, Just t <- [getScalarText k], t /= "in"]
        expr = getField "in" pairs
    in case expr of
      Just e  -> pure $ AstPreprocessingTag (PpLet (LetTag bindings e)) meta
      Nothing -> parseErrorAt meta "missing required 'in' field"
  _ -> parseErrorAt meta "must be a mapping with variable bindings and 'in' field"

parseNotTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseNotTag meta value =
  pure $ AstPreprocessingTag (PpNot (NotTag (unwrapSingle value))) meta

parseMergeMapTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseMergeMapTag meta = \case
  AstMapping pairs _ ->
    case (getField "items" pairs, getField "template" pairs) of
      (Just items, Just templ) -> do
        validateFields ["items", "template"] ["var"] pairs
        pure $ AstPreprocessingTag
          (PpMergeMap (MergeMapTag items templ (getTextField "var" pairs))) meta
      (Nothing, _) -> parseErrorAt meta ("'items' missing in !$mergeMap tag")
      (_, Nothing) -> parseErrorAt meta ("'template' missing in !$mergeMap tag")
  _ -> parseErrorAt meta "must be a mapping with 'items' and 'template' fields"

parseMapValuesTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseMapValuesTag meta = \case
  AstMapping pairs _ ->
    case (getField "items" pairs, getField "template" pairs) of
      (Just items, Just templ) -> do
        validateFields ["items", "template"] ["var"] pairs
        pure $ AstPreprocessingTag
          (PpMapValues (MapValuesTag items templ (getTextField "var" pairs))) meta
      (Nothing, _) -> parseErrorAt meta ("'items' missing in !$mapValues tag")
      (_, Nothing) -> parseErrorAt meta ("'template' missing in !$mapValues tag")
  _ -> parseErrorAt meta "must be a mapping with 'items' and 'template' fields"

parseGroupByTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseGroupByTag meta = \case
  AstMapping pairs _ ->
    case (getField "items" pairs, getField "key" pairs) of
      (Just items, Just key) -> do
        validateFields ["items", "key"] ["var", "template"] pairs
        pure $ AstPreprocessingTag
          (PpGroupBy (GroupByTag items key (getTextField "var" pairs) (getField "template" pairs))) meta
      (Nothing, _) -> parseErrorAt meta ("'items' missing in !$groupBy tag")
      (_, Nothing) -> parseErrorAt meta ("'key' missing in !$groupBy tag")
  _ -> parseErrorAt meta "must be a mapping with 'items' and 'key' fields"

parseExpandTag :: SrcMeta -> YamlAst -> Parse YamlAst
parseExpandTag meta = \case
  AstMapping pairs _ ->
    case (getField "template" pairs, getField "params" pairs) of
      (Just templ, Just params) -> do
        validateFields ["template", "params"] [] pairs
        pure $ AstPreprocessingTag (PpExpand (ExpandTag templ params)) meta
      (Nothing, _) -> parseErrorAt meta ("'template' missing in !$expand tag")
      (_, Nothing) -> parseErrorAt meta ("'params' missing in !$expand tag")
  _ -> parseErrorAt meta "must be a mapping with 'template' and 'params' fields"

------------------------------------------------------------------------
-- Field validation
------------------------------------------------------------------------

-- | Check for unknown fields in a tag mapping. Errors on the first unknown field.
validateFields :: [Text] -> [Text] -> [(YamlAst, YamlAst)] -> Parse ()
validateFields required optional pairs =
  let allValid = required ++ optional
      unknowns = [(t, astMeta k) | (k, _) <- pairs, Just t <- [getScalarText k], t `notElem` allValid]
  in case unknowns of
    ((unknown, keyMeta):_) ->
      let optFormatted = map (\o -> o <> " (optional)") optional
          allFormatted = required ++ optFormatted
      in parseErrorAt keyMeta $
        "unexpected field '" <> unknown <> "'\n\nValid fields are: " <> T.intercalate ", " allFormatted
    [] -> pure ()

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

splitVarQuery :: Text -> (Text, Maybe Text)
splitVarQuery raw = case T.breakOn "?" raw of
  (path, rest)
    | T.null rest -> (path, Nothing)
    | otherwise   -> (path, Just (T.drop 1 rest))
