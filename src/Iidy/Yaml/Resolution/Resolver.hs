module Iidy.Yaml.Resolution.Resolver
  ( resolveAst
  , astToValueRaw
  , ResolveError(..)
  ) where

import Control.Monad (foldM)
import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Iidy.Yaml.Ast
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Handlebars.Engine (interpolate, defaultHelpers, InterpolateError(..))
import Iidy.Yaml.JMESPath (applyJmesPath, JMESPathError(..))
import Iidy.Yaml.Location (Position)
import Iidy.Yaml.OValue
import Iidy.Yaml.Parser (parseYaml, ParseError(..))
import Iidy.Yaml.Resolution.Context

data ResolveError = ResolveError
  { rePosition :: !Position
  , reMessage  :: !Text
  } deriving stock (Show, Eq)

type Resolve a = Either ResolveError a

resolveError :: SrcMeta -> Text -> Resolve a
resolveError meta msg = Left (ResolveError (smStart meta) msg)

------------------------------------------------------------------------
-- Main resolution
------------------------------------------------------------------------

resolveAst :: TagContext -> YamlAst -> Resolve OValue
resolveAst ctx = \case
  AstNull _            -> pure ONull
  AstBool b _          -> pure (OBool b)
  AstNumber n _        -> pure (ONumber n)
  AstPlainString s _   -> pure (OString s)
  AstTemplatedString s meta -> resolveTemplateString ctx meta s
  AstSequence items _  -> resolveSequence ctx items
  AstMapping pairs _   -> resolveMapping ctx pairs
  AstPreprocessingTag tag meta -> resolvePreprocessingTag ctx meta tag
  AstCloudFormationTag tag meta -> resolveCfnTag ctx meta tag
  AstUnknownTag (UnknownTag name inner) _meta -> do
    val <- resolveAst ctx inner
    pure $ OObject [(name, val)]
  AstImportedDocument (ImportedDocumentNode _ _ content _) _ ->
    resolveAst ctx content

------------------------------------------------------------------------
-- Sequences & mappings
------------------------------------------------------------------------

resolveSequence :: TagContext -> [YamlAst] -> Resolve OValue
resolveSequence ctx items = do
  vals <- traverse (resolveAst ctx) items
  pure $ OArray vals

resolveMapping :: TagContext -> [(YamlAst, YamlAst)] -> Resolve OValue
resolveMapping ctx pairs = do
  resolved <- traverse resolvePair pairs
  let filtered = [(k, v) | (k, v) <- resolved, not (isSpecialKey k)]
  pure $ OObject filtered
  where
    resolvePair (keyAst, valAst) = do
      kv <- resolveAst ctx keyAst
      let k = oValueToText kv
      vv <- resolveAst ctx valAst
      pure (k, vv)
    isSpecialKey k = k `elem` ["$imports", "$defs", "$envValues", "$params"]

------------------------------------------------------------------------
-- Template strings (handlebars)
------------------------------------------------------------------------

resolveTemplateString :: TagContext -> SrcMeta -> Text -> Resolve OValue
resolveTemplateString ctx meta template =
  let ctxValue = Object (KM.fromList
        [(Key.fromText k, v) | (k, v) <- Map.toList (tcVariables ctx)])
  in case interpolate defaultHelpers ctxValue template of
       Right s -> pure (OString s)
       Left (InterpolateError msg) -> resolveError meta ("Handlebars error: " <> msg)

------------------------------------------------------------------------
-- CloudFormation tags
------------------------------------------------------------------------

resolveCfnTag :: TagContext -> SrcMeta -> CloudFormationTag -> Resolve OValue
resolveCfnTag ctx _meta tag = do
  let (name, inner) = cfnTagParts tag
  resolved <- resolveAst ctx inner
  pure $ OObject [(name, resolved)]

cfnTagParts :: CloudFormationTag -> (Text, YamlAst)
cfnTagParts = \case
  CfnRef v         -> ("!Ref", v)
  CfnSub v         -> ("!Sub", v)
  CfnGetAtt v      -> ("!GetAtt", v)
  CfnJoin v        -> ("!Join", v)
  CfnSelect v      -> ("!Select", v)
  CfnSplit v       -> ("!Split", v)
  CfnBase64 v      -> ("!Base64", v)
  CfnGetAZs v      -> ("!GetAZs", v)
  CfnImportValue v -> ("!ImportValue", v)
  CfnFindInMap v   -> ("!FindInMap", v)
  CfnCidr v        -> ("!Cidr", v)
  CfnLength v      -> ("!Length", v)
  CfnToJsonString v -> ("!ToJsonString", v)
  CfnTransform v   -> ("!Transform", v)
  CfnForEach v     -> ("!ForEach", v)
  CfnIf v          -> ("!If", v)
  CfnEquals v      -> ("!Equals", v)
  CfnAnd v         -> ("!And", v)
  CfnOr v          -> ("!Or", v)
  CfnNot v         -> ("!Not", v)

------------------------------------------------------------------------
-- Preprocessing tag resolution
------------------------------------------------------------------------

resolvePreprocessingTag :: TagContext -> SrcMeta -> PreprocessingTag -> Resolve OValue
resolvePreprocessingTag ctx meta = \case
  PpVarLookup tag     -> resolveVarLookup ctx meta tag
  PpIf tag            -> resolveIf ctx meta tag
  PpMap tag           -> resolveMap ctx meta tag
  PpMerge tag         -> resolveMerge ctx meta tag
  PpConcat tag        -> resolveConcat ctx meta tag
  PpLet tag           -> resolveLet ctx meta tag
  PpEq tag            -> resolveEq ctx meta tag
  PpNot tag           -> resolveNot ctx meta tag
  PpSplit tag         -> resolveSplit ctx meta tag
  PpJoin tag          -> resolveJoin ctx meta tag
  PpConcatMap tag     -> resolveConcatMap ctx meta tag
  PpMergeMap tag      -> resolveMergeMap ctx meta tag
  PpMapListToHash tag -> resolveMapListToHash ctx meta tag
  PpMapValues tag     -> resolveMapValues ctx meta tag
  PpGroupBy tag       -> resolveGroupBy ctx meta tag
  PpFromPairs tag     -> resolveFromPairs ctx meta tag
  PpToYamlString tag  -> resolveToYamlString ctx meta tag
  PpParseYaml tag     -> resolveParseYaml ctx meta tag
  PpToJsonString tag  -> resolveToJsonString ctx meta tag
  PpParseJson tag     -> resolveParseJson ctx meta tag
  PpEscape tag        -> resolveEscape ctx meta tag
  PpExpand tag        -> resolveExpand ctx meta tag

------------------------------------------------------------------------
-- Individual tag resolvers
------------------------------------------------------------------------

resolveVarLookup :: TagContext -> SrcMeta -> VarLookupTag -> Resolve OValue
resolveVarLookup ctx meta (VarLookupTag path query jmesPathExpr) = do
  baseVal <- case resolveDotPath path ctx of
    Just val -> pure val
    Nothing -> resolveError meta $
      "Variable not found: " <> path <> ". Available: " <>
      T.intercalate ", " (contextVariableNames ctx)
  let queriedVal = case query of
        Nothing -> baseVal
        Just q -> applyDotQuery q baseVal
  case jmesPathExpr of
    Nothing -> pure (fromValue queriedVal)
    Just expr -> case applyJmesPath expr queriedVal of
      Right v -> pure (fromValue v)
      Left (JMESPathError msg) -> resolveError meta $ "JMESPath error: " <> msg

applyDotQuery :: Text -> Value -> Value
applyDotQuery q val =
  let segments = filter (not . T.null) (T.splitOn "." q)
  in case traversePath segments val of
       Just v  -> v
       Nothing -> Null

resolveDotPath :: Text -> TagContext -> Maybe Value
resolveDotPath path ctx =
  let segments = T.splitOn "." path
  in case segments of
    [] -> Nothing
    (root:rest) -> case getVariable root ctx of
      Nothing -> Nothing
      Just val -> traversePath rest val

traversePath :: [Text] -> Value -> Maybe Value
traversePath [] val = Just val
traversePath (seg:rest) val = case val of
  Object obj -> case KM.lookup (Key.fromText seg) obj of
    Just v  -> traversePath rest v
    Nothing -> Nothing
  Array arr  -> case reads (T.unpack seg) of
    [(i, "")] | i >= 0 && i < V.length arr -> traversePath rest (arr V.! i)
    _ -> Nothing
  _ -> Nothing

resolveIf :: TagContext -> SrcMeta -> IfTag -> Resolve OValue
resolveIf ctx _meta (IfTag test thenVal elseVal) = do
  testResult <- resolveAst ctx test
  if oIsTruthy testResult
    then resolveAst ctx thenVal
    else case elseVal of
      Just e  -> resolveAst ctx e
      Nothing -> pure ONull

resolveLet :: TagContext -> SrcMeta -> LetTag -> Resolve OValue
resolveLet ctx _meta (LetTag bindings expr) = do
  newCtx <- foldBindings ctx bindings
  resolveAst newCtx expr
  where
    foldBindings c [] = pure c
    foldBindings c ((name, ast):rest) = do
      val <- resolveAst c ast
      foldBindings (withVariable name (toValue val) c) rest

resolveMap :: TagContext -> SrcMeta -> MapTag -> Resolve OValue
resolveMap ctx meta (MapTag items template var filterExpr) =
  resolveMapItems ctx meta items template (fromMaybeVar var) filterExpr

resolveMapItems :: TagContext -> SrcMeta -> YamlAst -> YamlAst -> Text -> Maybe YamlAst -> Resolve OValue
resolveMapItems ctx meta itemsAst templateAst varName filterExpr = do
  itemsVal <- resolveAst ctx itemsAst
  case itemsVal of
    OArray arr -> do
      results <- imapMaybeM (\i item -> do
        let bindings = Map.fromList
              [ (varName, toValue item)
              , (varName <> "Idx", Number (fromIntegral i))
              ]
            itemCtx = withBindings bindings ctx
        case filterExpr of
          Just fExpr -> do
            fVal <- resolveAst itemCtx fExpr
            if oIsTruthy fVal
              then Just <$> resolveAst itemCtx templateAst
              else pure Nothing
          Nothing -> Just <$> resolveAst itemCtx templateAst
        ) arr
      pure $ OArray results
    _ -> resolveError meta "!$map items must be a sequence"

resolveMerge :: TagContext -> SrcMeta -> MergeTag -> Resolve OValue
resolveMerge ctx meta (MergeTag sources) = do
  vals <- traverse (resolveAst ctx) sources
  let merge acc v = case v of
        OObject kvs -> pure $ mergeOObjects acc kvs
        _ -> resolveError meta "!$merge: all sources must be mappings"
  foldM merge (OObject []) vals

mergeOObjects :: OValue -> [(Text, OValue)] -> OValue
mergeOObjects (OObject base) overlay =
  let overlayKeys = map fst overlay
      keptBase = filter (\(k, _) -> k `notElem` overlayKeys) base
  in OObject (keptBase ++ overlay)
mergeOObjects _ overlay = OObject overlay

resolveConcat :: TagContext -> SrcMeta -> ConcatTag -> Resolve OValue
resolveConcat ctx _meta (ConcatTag sources) = do
  vals <- traverse (resolveAst ctx) sources
  let flatten v = case v of
        OArray arr -> arr
        other      -> [other]
  pure $ OArray $ concatMap flatten vals

resolveEq :: TagContext -> SrcMeta -> EqTag -> Resolve OValue
resolveEq ctx _meta (EqTag left right) = do
  l <- resolveAst ctx left
  r <- resolveAst ctx right
  pure $ OBool (oValuesEqual l r)

resolveNot :: TagContext -> SrcMeta -> NotTag -> Resolve OValue
resolveNot ctx _meta (NotTag expr) = do
  val <- resolveAst ctx expr
  pure $ OBool (not (oIsTruthy val))

resolveSplit :: TagContext -> SrcMeta -> SplitTag -> Resolve OValue
resolveSplit ctx meta (SplitTag delimAst strAst) = do
  delimVal <- resolveAst ctx delimAst
  strVal <- resolveAst ctx strAst
  case (delimVal, strVal) of
    (OString d, OString s) ->
      pure $ OArray $ map OString $ T.splitOn d s
    _ -> resolveError meta "!$split requires string arguments"

resolveJoin :: TagContext -> SrcMeta -> JoinTag -> Resolve OValue
resolveJoin ctx meta (JoinTag delimAst arrAst) = do
  delimVal <- resolveAst ctx delimAst
  arrVal <- resolveAst ctx arrAst
  case (delimVal, arrVal) of
    (OString d, OArray arr) ->
      pure $ OString $ T.intercalate d [oValueToText v | v <- arr]
    _ -> resolveError meta "!$join requires [string, sequence]"

resolveConcatMap :: TagContext -> SrcMeta -> ConcatMapTag -> Resolve OValue
resolveConcatMap ctx meta (ConcatMapTag items template var filterExpr) = do
  result <- resolveMapItems ctx meta items template (fromMaybeVar var) filterExpr
  case result of
    OArray arr -> pure $ OArray $ concatMap flattenItem arr
    _ -> resolveError meta "!$concatMap: unexpected result"
  where
    flattenItem (OArray inner) = inner
    flattenItem other = [other]

resolveMergeMap :: TagContext -> SrcMeta -> MergeMapTag -> Resolve OValue
resolveMergeMap ctx meta (MergeMapTag items template var) = do
  result <- resolveMapItems ctx meta items template (fromMaybeVar var) Nothing
  case result of
    OArray arr -> do
      let merge acc v = case v of
            OObject kvs -> pure $ mergeOObjects acc kvs
            _ -> resolveError meta "!$mergeMap: items must resolve to mappings"
      foldM merge (OObject []) arr
    _ -> resolveError meta "!$mergeMap: unexpected result"

resolveMapListToHash :: TagContext -> SrcMeta -> MapListToHashTag -> Resolve OValue
resolveMapListToHash ctx meta (MapListToHashTag items template var filterExpr) = do
  result <- resolveMapItems ctx meta items template (fromMaybeVar var) filterExpr
  case result of
    OArray arr -> do
      pairs <- traverse extractPair arr
      pure $ OObject pairs
    _ -> resolveError meta "!$mapListToHash: unexpected result"
  where
    extractPair (OArray pair)
      | length pair == 2 = pure (oValueToText (pair !! 0), pair !! 1)
    extractPair (OObject kvs)
      | Just k <- lookupO "key" kvs, Just v <- lookupO "value" kvs =
          pure (oValueToText k, v)
    extractPair (OObject kvs) = case kvs of
      [(k, v)] -> pure (k, v)
      _ -> resolveError meta "!$mapListToHash: object item must have exactly one key"
    extractPair v = resolveError meta $ "!$mapListToHash: invalid item: " <> T.pack (show v)

resolveMapValues :: TagContext -> SrcMeta -> MapValuesTag -> Resolve OValue
resolveMapValues ctx meta (MapValuesTag itemsAst templateAst var) = do
  itemsVal <- resolveAst ctx itemsAst
  case itemsVal of
    OObject kvs -> do
      pairs <- traverse (\(k, v) -> do
        let bindings = Map.singleton (fromMaybeVar var) $
              Object $ KM.fromList [("key", String k), ("value", toValue v)]
            itemCtx = withBindings bindings ctx
        resolved <- resolveAst itemCtx templateAst
        pure (k, resolved)
        ) kvs
      pure $ OObject pairs
    _ -> resolveError meta "!$mapValues items must be a mapping"

resolveGroupBy :: TagContext -> SrcMeta -> GroupByTag -> Resolve OValue
resolveGroupBy ctx meta (GroupByTag itemsAst keyAst var _templateAst) = do
  itemsVal <- resolveAst ctx itemsAst
  case itemsVal of
    OArray arr -> do
      groups <- foldM (\acc item -> do
        let itemCtx = withVariable (fromMaybeVar var) (toValue item) ctx
        keyVal <- resolveAst itemCtx keyAst
        let k = oValueToText keyVal
            existing = case lookupO k acc of
              Just (OArray v) -> v
              _ -> []
        pure $ insertO k (OArray (existing ++ [item])) acc
        ) [] arr
      pure $ OObject groups
    _ -> resolveError meta "!$groupBy items must be a sequence"

resolveFromPairs :: TagContext -> SrcMeta -> FromPairsTag -> Resolve OValue
resolveFromPairs ctx meta (FromPairsTag sourceAst) = do
  sourceVal <- resolveAst ctx sourceAst
  case sourceVal of
    OArray arr -> do
      pairs <- traverse extractPair arr
      pure $ OObject pairs
    _ -> resolveError meta "!$fromPairs requires a sequence"
  where
    extractPair (OArray pair)
      | length pair == 2 =
          pure (oValueToText (pair !! 0), pair !! 1)
    extractPair _ = resolveError meta "!$fromPairs: each item must be a 2-element sequence"

resolveToYamlString :: TagContext -> SrcMeta -> ToYamlStringTag -> Resolve OValue
resolveToYamlString ctx _meta (ToYamlStringTag dataAst) = do
  val <- resolveAst ctx dataAst
  pure $ OString $ emitYaml val

resolveParseYaml :: TagContext -> SrcMeta -> ParseYamlTag -> Resolve OValue
resolveParseYaml ctx meta (ParseYamlTag strAst) = do
  val <- resolveAst ctx strAst
  case val of
    OString s ->
      case parseYaml (BL.fromStrict (TE.encodeUtf8 s)) "<parseYaml>" of
        Right ast -> Right (fromValue (astToValueRaw ast))
        Left (ParseError _ msg) -> resolveError meta $ "!$parseYaml: " <> msg
    _ -> resolveError meta "!$parseYaml requires a string"

resolveToJsonString :: TagContext -> SrcMeta -> ToJsonStringTag -> Resolve OValue
resolveToJsonString ctx _meta (ToJsonStringTag dataAst) = do
  val <- resolveAst ctx dataAst
  pure $ OString $ TE.decodeUtf8 $ BL.toStrict $ Aeson.encode (toValue val)

resolveParseJson :: TagContext -> SrcMeta -> ParseJsonTag -> Resolve OValue
resolveParseJson ctx meta (ParseJsonTag strAst) = do
  val <- resolveAst ctx strAst
  case val of
    OString s -> case Aeson.eitherDecodeStrict' (TE.encodeUtf8 s) of
      Right v  -> pure (fromValue v)
      Left err -> resolveError meta $ "!$parseJson: " <> T.pack err
    _ -> resolveError meta "!$parseJson requires a string"

resolveEscape :: TagContext -> SrcMeta -> EscapeTag -> Resolve OValue
resolveEscape _ctx _meta (EscapeTag contentAst) =
  pure $ fromValue $ astToValueRaw contentAst

resolveExpand :: TagContext -> SrcMeta -> ExpandTag -> Resolve OValue
resolveExpand _ctx meta (ExpandTag _templateAst _paramsAst) =
  resolveError meta "!$expand not yet implemented"

------------------------------------------------------------------------
-- Raw AST to Value (for !$escape — no resolution)
------------------------------------------------------------------------

astToValueRaw :: YamlAst -> Value
astToValueRaw = \case
  AstNull _              -> Null
  AstBool b _            -> Bool b
  AstNumber n _          -> Number n
  AstPlainString s _     -> String s
  AstTemplatedString s _ -> String s
  AstSequence items _    -> Array $ V.fromList $ map astToValueRaw items
  AstMapping pairs _     -> Object $ KM.fromList
    [(Key.fromText (rawKeyText k), astToValueRaw v) | (k, v) <- pairs]
  AstPreprocessingTag _ _ -> String "!$escaped"
  AstCloudFormationTag tag _ ->
    let (name, inner) = cfnTagParts tag
    in Object $ KM.singleton (Key.fromText name) (astToValueRaw inner)
  AstUnknownTag (UnknownTag name inner) _ ->
    Object $ KM.singleton (Key.fromText name) (astToValueRaw inner)
  AstImportedDocument (ImportedDocumentNode _ _ content _) _ ->
    astToValueRaw content

rawKeyText :: YamlAst -> Text
rawKeyText (AstPlainString t _) = t
rawKeyText (AstTemplatedString t _) = t
rawKeyText _ = ""

------------------------------------------------------------------------
-- OValue list helpers
------------------------------------------------------------------------

lookupO :: Text -> [(Text, OValue)] -> Maybe OValue
lookupO k kvs = case [v | (k', v) <- kvs, k' == k] of
  (v:_) -> Just v
  []    -> Nothing

insertO :: Text -> OValue -> [(Text, OValue)] -> [(Text, OValue)]
insertO k v [] = [(k, v)]
insertO k v ((k', v'):rest)
  | k == k' = (k, v) : rest
  | otherwise = (k', v') : insertO k v rest

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

fromMaybeVar :: Maybe Text -> Text
fromMaybeVar = maybe "item" id

imapMaybeM :: Monad m => (Int -> a -> m (Maybe b)) -> [a] -> m [b]
imapMaybeM f xs = go 0 xs
  where
    go _ [] = pure []
    go i (a:as) = do
      mb <- f i a
      rest <- go (i + 1) as
      pure $ case mb of
        Just b  -> b : rest
        Nothing -> rest
