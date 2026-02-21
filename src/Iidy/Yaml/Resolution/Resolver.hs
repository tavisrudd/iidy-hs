module Iidy.Yaml.Resolution.Resolver
  ( resolveAst
  , ResolveError(..)
  ) where

import Control.Monad (foldM)
import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Iidy.Yaml.Ast
import Iidy.Yaml.Location (Position)
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

resolveAst :: TagContext -> YamlAst -> Resolve Value
resolveAst ctx = \case
  AstNull _            -> pure Null
  AstBool b _          -> pure (Bool b)
  AstNumber n _        -> pure (Number n)
  AstPlainString s _   -> pure (String s)
  AstTemplatedString s meta -> resolveTemplateString ctx meta s
  AstSequence items _  -> resolveSequence ctx items
  AstMapping pairs _   -> resolveMapping ctx pairs
  AstPreprocessingTag tag meta -> resolvePreprocessingTag ctx meta tag
  AstCloudFormationTag tag meta -> resolveCfnTag ctx meta tag
  AstUnknownTag (UnknownTag name inner) _meta -> do
    val <- resolveAst ctx inner
    pure $ Object $ KM.singleton (Key.fromText name) val
  AstImportedDocument (ImportedDocumentNode _ _ content _) _ ->
    resolveAst ctx content

------------------------------------------------------------------------
-- Sequences & mappings
------------------------------------------------------------------------

resolveSequence :: TagContext -> [YamlAst] -> Resolve Value
resolveSequence ctx items = do
  vals <- traverse (resolveAst ctx) items
  pure $ Array (V.fromList vals)

resolveMapping :: TagContext -> [(YamlAst, YamlAst)] -> Resolve Value
resolveMapping ctx pairs = do
  resolved <- traverse resolvePair pairs
  let filtered = [(k, v) | (k, v) <- resolved, not (isSpecialKey k)]
  pure $ Object $ KM.fromList [(Key.fromText k, v) | (k, v) <- filtered]
  where
    resolvePair (keyAst, valAst) = do
      kv <- resolveAst ctx keyAst
      let k = valueToText kv
      vv <- resolveAst ctx valAst
      pure (k, vv)
    isSpecialKey k = k `elem` ["$imports", "$defs", "$envValues", "$params"]

valueToText :: Value -> Text
valueToText = \case
  String s -> s
  Number n -> T.pack (show n)
  Bool True -> "true"
  Bool False -> "false"
  Null -> "null"
  other -> T.pack (show other)

------------------------------------------------------------------------
-- Template strings (handlebars)
------------------------------------------------------------------------

resolveTemplateString :: TagContext -> SrcMeta -> Text -> Resolve Value
resolveTemplateString ctx _meta template =
  -- TODO: implement handlebars interpolation (chunk 2.5)
  -- For now, do simple {{variable}} replacement
  pure $ String $ simpleInterpolate (tcVariables ctx) template

simpleInterpolate :: Map Text Value -> Text -> Text
simpleInterpolate vars template =
  case T.breakOn "{{" template of
    (before, rest)
      | T.null rest -> template
      | otherwise ->
          case T.breakOn "}}" (T.drop 2 rest) of
            (varName, after)
              | T.null after -> template  -- malformed
              | otherwise ->
                  let name = T.strip varName
                      replacement = case Map.lookup name vars of
                        Just (String s) -> s
                        Just (Number n) -> T.pack (show n)
                        Just (Bool True) -> "true"
                        Just (Bool False) -> "false"
                        Just Null -> ""
                        _ -> "{{" <> varName <> "}}"
                  in before <> replacement <> simpleInterpolate vars (T.drop 2 after)

------------------------------------------------------------------------
-- CloudFormation tags
------------------------------------------------------------------------

resolveCfnTag :: TagContext -> SrcMeta -> CloudFormationTag -> Resolve Value
resolveCfnTag ctx _meta tag = do
  let (name, inner) = cfnTagParts tag
  resolved <- resolveAst ctx inner
  pure $ Object $ KM.singleton (Key.fromText name) resolved

cfnTagParts :: CloudFormationTag -> (Text, YamlAst)
cfnTagParts = \case
  CfnRef v         -> ("Ref", v)
  CfnSub v         -> ("Fn::Sub", v)
  CfnGetAtt v      -> ("Fn::GetAtt", v)
  CfnJoin v        -> ("Fn::Join", v)
  CfnSelect v      -> ("Fn::Select", v)
  CfnSplit v       -> ("Fn::Split", v)
  CfnBase64 v      -> ("Fn::Base64", v)
  CfnGetAZs v      -> ("Fn::GetAZs", v)
  CfnImportValue v -> ("Fn::ImportValue", v)
  CfnFindInMap v   -> ("Fn::FindInMap", v)
  CfnCidr v        -> ("Fn::Cidr", v)
  CfnLength v      -> ("Fn::Length", v)
  CfnToJsonString v -> ("Fn::ToJsonString", v)
  CfnTransform v   -> ("Fn::Transform", v)
  CfnForEach v     -> ("Fn::ForEach", v)
  CfnIf v          -> ("Fn::If", v)
  CfnEquals v      -> ("Fn::Equals", v)
  CfnAnd v         -> ("Fn::And", v)
  CfnOr v          -> ("Fn::Or", v)
  CfnNot v         -> ("Fn::Not", v)

------------------------------------------------------------------------
-- Preprocessing tag resolution
------------------------------------------------------------------------

resolvePreprocessingTag :: TagContext -> SrcMeta -> PreprocessingTag -> Resolve Value
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

resolveVarLookup :: TagContext -> SrcMeta -> VarLookupTag -> Resolve Value
resolveVarLookup ctx meta (VarLookupTag path _query _jmespath) =
  case resolveDotPath path ctx of
    Just val -> pure val
    Nothing -> resolveError meta $
      "Variable not found: " <> path <> ". Available: " <>
      T.intercalate ", " (contextVariableNames ctx)

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

resolveIf :: TagContext -> SrcMeta -> IfTag -> Resolve Value
resolveIf ctx _meta (IfTag test thenVal elseVal) = do
  testResult <- resolveAst ctx test
  if isTruthy testResult
    then resolveAst ctx thenVal
    else case elseVal of
      Just e  -> resolveAst ctx e
      Nothing -> pure Null

resolveLet :: TagContext -> SrcMeta -> LetTag -> Resolve Value
resolveLet ctx _meta (LetTag bindings expr) = do
  newCtx <- foldBindings ctx bindings
  resolveAst newCtx expr
  where
    foldBindings c [] = pure c
    foldBindings c ((name, ast):rest) = do
      val <- resolveAst c ast
      foldBindings (withVariable name val c) rest

resolveMap :: TagContext -> SrcMeta -> MapTag -> Resolve Value
resolveMap ctx meta (MapTag items template var filterExpr) =
  resolveMapItems ctx meta items template (fromMaybeVar var) filterExpr

resolveMapItems :: TagContext -> SrcMeta -> YamlAst -> YamlAst -> Text -> Maybe YamlAst -> Resolve Value
resolveMapItems ctx meta itemsAst templateAst varName filterExpr = do
  itemsVal <- resolveAst ctx itemsAst
  case itemsVal of
    Array arr -> do
      results <- imapMaybeM (\i item -> do
        let bindings = Map.fromList
              [ (varName, item)
              , (varName <> "Idx", Number (fromIntegral i))
              ]
            itemCtx = withBindings bindings ctx
        case filterExpr of
          Just fExpr -> do
            fVal <- resolveAst itemCtx fExpr
            if isTruthy fVal
              then Just <$> resolveAst itemCtx templateAst
              else pure Nothing
          Nothing -> Just <$> resolveAst itemCtx templateAst
        ) (V.toList arr)
      pure $ Array (V.fromList results)
    _ -> resolveError meta "!$map items must be a sequence"

resolveMerge :: TagContext -> SrcMeta -> MergeTag -> Resolve Value
resolveMerge ctx meta (MergeTag sources) = do
  vals <- traverse (resolveAst ctx) sources
  let merge acc v = case v of
        Object obj -> pure $ mergeObjects acc obj
        _ -> resolveError meta "!$merge: all sources must be mappings"
  foldM merge (Object KM.empty) vals

mergeObjects :: Value -> KM.KeyMap Value -> Value
mergeObjects (Object base) overlay = Object (KM.union overlay base)
mergeObjects _ overlay = Object overlay

resolveConcat :: TagContext -> SrcMeta -> ConcatTag -> Resolve Value
resolveConcat ctx _meta (ConcatTag sources) = do
  vals <- traverse (resolveAst ctx) sources
  let flatten v = case v of
        Array arr -> V.toList arr
        other     -> [other]
  pure $ Array $ V.fromList $ concatMap flatten vals

resolveEq :: TagContext -> SrcMeta -> EqTag -> Resolve Value
resolveEq ctx _meta (EqTag left right) = do
  l <- resolveAst ctx left
  r <- resolveAst ctx right
  pure $ Bool (valuesEqual l r)

resolveNot :: TagContext -> SrcMeta -> NotTag -> Resolve Value
resolveNot ctx _meta (NotTag expr) = do
  val <- resolveAst ctx expr
  pure $ Bool (not (isTruthy val))

resolveSplit :: TagContext -> SrcMeta -> SplitTag -> Resolve Value
resolveSplit ctx meta (SplitTag delimAst strAst) = do
  delimVal <- resolveAst ctx delimAst
  strVal <- resolveAst ctx strAst
  case (delimVal, strVal) of
    (String d, String s) ->
      pure $ Array $ V.fromList $ map String $ T.splitOn d s
    _ -> resolveError meta "!$split requires string arguments"

resolveJoin :: TagContext -> SrcMeta -> JoinTag -> Resolve Value
resolveJoin ctx meta (JoinTag delimAst arrAst) = do
  delimVal <- resolveAst ctx delimAst
  arrVal <- resolveAst ctx arrAst
  case (delimVal, arrVal) of
    (String d, Array arr) ->
      pure $ String $ T.intercalate d [valueToText v | v <- V.toList arr]
    _ -> resolveError meta "!$join requires [string, sequence]"

resolveConcatMap :: TagContext -> SrcMeta -> ConcatMapTag -> Resolve Value
resolveConcatMap ctx meta (ConcatMapTag items template var filterExpr) = do
  result <- resolveMapItems ctx meta items template (fromMaybeVar var) filterExpr
  case result of
    Array arr -> pure $ Array $ V.concatMap flattenItem arr
    _ -> resolveError meta "!$concatMap: unexpected result"
  where
    flattenItem (Array inner) = inner
    flattenItem other = V.singleton other

resolveMergeMap :: TagContext -> SrcMeta -> MergeMapTag -> Resolve Value
resolveMergeMap ctx meta (MergeMapTag items template var) = do
  result <- resolveMapItems ctx meta items template (fromMaybeVar var) Nothing
  case result of
    Array arr -> do
      let merge acc v = case v of
            Object obj -> pure $ mergeObjects acc obj
            _ -> resolveError meta "!$mergeMap: items must resolve to mappings"
      foldM merge (Object KM.empty) (V.toList arr)
    _ -> resolveError meta "!$mergeMap: unexpected result"

resolveMapListToHash :: TagContext -> SrcMeta -> MapListToHashTag -> Resolve Value
resolveMapListToHash ctx meta (MapListToHashTag items template var filterExpr) = do
  result <- resolveMapItems ctx meta items template (fromMaybeVar var) filterExpr
  case result of
    Array arr -> do
      pairs <- traverse extractPair (V.toList arr)
      pure $ Object $ KM.fromList pairs
    _ -> resolveError meta "!$mapListToHash: unexpected result"
  where
    extractPair (Array pair)
      | V.length pair == 2 = pure (Key.fromText (valueToText (pair V.! 0)), pair V.! 1)
    extractPair (Object obj)
      | Just k <- KM.lookup "key" obj, Just v <- KM.lookup "value" obj =
          pure (Key.fromText (valueToText k), v)
    extractPair (Object obj) = case KM.toList obj of
      [(k, v)] -> pure (k, v)
      _ -> resolveError meta "!$mapListToHash: object item must have exactly one key"
    extractPair v = resolveError meta $ "!$mapListToHash: invalid item: " <> T.pack (show v)

resolveMapValues :: TagContext -> SrcMeta -> MapValuesTag -> Resolve Value
resolveMapValues ctx meta (MapValuesTag itemsAst templateAst var) = do
  itemsVal <- resolveAst ctx itemsAst
  case itemsVal of
    Object obj -> do
      pairs <- traverse (\(k, v) -> do
        let bindings = Map.singleton (fromMaybeVar var) $
              Object $ KM.fromList [("key", String (Key.toText k)), ("value", v)]
            itemCtx = withBindings bindings ctx
        resolved <- resolveAst itemCtx templateAst
        pure (k, resolved)
        ) (KM.toList obj)
      pure $ Object $ KM.fromList pairs
    _ -> resolveError meta "!$mapValues items must be a mapping"

resolveGroupBy :: TagContext -> SrcMeta -> GroupByTag -> Resolve Value
resolveGroupBy ctx meta (GroupByTag itemsAst keyAst var _templateAst) = do
  itemsVal <- resolveAst ctx itemsAst
  case itemsVal of
    Array arr -> do
      groups <- foldM (\acc item -> do
        let itemCtx = withVariable (fromMaybeVar var) item ctx
        keyVal <- resolveAst itemCtx keyAst
        let k = Key.fromText (valueToText keyVal)
            existing = case KM.lookup k acc of
              Just (Array v) -> v
              _ -> V.empty
        pure $ KM.insert k (Array (V.snoc existing item)) acc
        ) KM.empty (V.toList arr)
      pure $ Object groups
    _ -> resolveError meta "!$groupBy items must be a sequence"

resolveFromPairs :: TagContext -> SrcMeta -> FromPairsTag -> Resolve Value
resolveFromPairs ctx meta (FromPairsTag sourceAst) = do
  sourceVal <- resolveAst ctx sourceAst
  case sourceVal of
    Array arr -> do
      pairs <- traverse extractPair (V.toList arr)
      pure $ Object $ KM.fromList pairs
    _ -> resolveError meta "!$fromPairs requires a sequence"
  where
    extractPair (Array pair)
      | V.length pair == 2 =
          pure (Key.fromText (valueToText (pair V.! 0)), pair V.! 1)
    extractPair _ = resolveError meta "!$fromPairs: each item must be a 2-element sequence"

resolveToYamlString :: TagContext -> SrcMeta -> ToYamlStringTag -> Resolve Value
resolveToYamlString ctx _meta (ToYamlStringTag dataAst) = do
  val <- resolveAst ctx dataAst
  -- TODO: proper YAML serialization (chunk 2.10)
  pure $ String $ T.pack $ show val

resolveParseYaml :: TagContext -> SrcMeta -> ParseYamlTag -> Resolve Value
resolveParseYaml ctx meta (ParseYamlTag strAst) = do
  val <- resolveAst ctx strAst
  case val of
    String _s -> do
      -- TODO: parse YAML string (chunk 2.10)
      pure val
    _ -> resolveError meta "!$parseYaml requires a string"

resolveToJsonString :: TagContext -> SrcMeta -> ToJsonStringTag -> Resolve Value
resolveToJsonString ctx _meta (ToJsonStringTag dataAst) = do
  val <- resolveAst ctx dataAst
  pure $ String $ TE.decodeUtf8 $ BL.toStrict $ Aeson.encode val

resolveParseJson :: TagContext -> SrcMeta -> ParseJsonTag -> Resolve Value
resolveParseJson ctx meta (ParseJsonTag strAst) = do
  val <- resolveAst ctx strAst
  case val of
    String s -> case Aeson.eitherDecodeStrict' (TE.encodeUtf8 s) of
      Right v  -> pure v
      Left err -> resolveError meta $ "!$parseJson: " <> T.pack err
    _ -> resolveError meta "!$parseJson requires a string"

resolveEscape :: TagContext -> SrcMeta -> EscapeTag -> Resolve Value
resolveEscape _ctx _meta (EscapeTag contentAst) =
  pure $ astToValueRaw contentAst

resolveExpand :: TagContext -> SrcMeta -> ExpandTag -> Resolve Value
resolveExpand _ctx meta (ExpandTag _templateAst _paramsAst) =
  -- TODO: implement custom resource expansion (chunk 2.9)
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
