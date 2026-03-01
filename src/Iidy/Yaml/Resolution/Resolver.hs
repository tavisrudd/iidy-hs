module Iidy.Yaml.Resolution.Resolver
  ( resolveAst
  , astToValueRaw
  , ResolveError(..)
  , ResolveErrorKind(..)
  ) where

import Control.Monad (foldM)
import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Scientific as Sci
import qualified Data.Set as Set
import Data.Maybe (isNothing, fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Iidy.Yaml.Ast
import Iidy.Yaml.CustomResources.Expansion (expandCustomResource, ExpansionResult(..))
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Handlebars.Engine (interpolate, defaultHelpers, InterpolateError(..))
import Iidy.Yaml.JMESPath (applyJmesPath, JMESPathError(..))
import Iidy.Yaml.Location (Position, zeroPosition)
import Iidy.Yaml.OValue
import Iidy.Yaml.Parser (parseYaml, ParseError(..))
import Iidy.Yaml.Resolution.Context

-- | Structured classification of resolve errors.
-- Carries the semantic category so downstream code can classify without parsing message strings.
data ResolveErrorKind
  = REVariableNotFound  !Text ![Text]           -- ^ path, available vars
  | REJmesPath          !Text !Text !Text       -- ^ expr, detail, varPath
  | REPropertyNotFound  !Text !Text ![Text]     -- ^ missingKey, varPath, availKeys
  | RETypeMismatch      !Text !Text !(Maybe Text) -- ^ expected, found, contextTag
  | RECfnValidation     !Text                   -- ^ cfnTagName
  | REHandlebars                                -- ^ handlebars template error
  | RETagSyntax         !(Maybe Text)           -- ^ tagName (if extractable)
  | REExpandNotFound    !Text                   -- ^ templateName
  | REParseSyntax                               -- ^ !$parseYaml/Json/expand parse error
  | REGeneric                                   -- ^ fallback
  deriving stock (Show, Eq)

data ResolveError = ResolveError
  { rePosition :: !Position
  , reMessage  :: !Text
  , reKind     :: !ResolveErrorKind
  } deriving stock (Show, Eq)

type Resolve a = Either ResolveError a

-- | Tag syntax error with optional tag name.
tagSyntaxError :: SrcMeta -> Maybe Text -> Text -> Resolve a
tagSyntaxError meta tagName msg = Left (ResolveError (smStart meta) msg (RETagSyntax tagName))

-- | Describe an OValue's type for error messages (matching Rust format)
oValueTypeName :: OValue -> Text
oValueTypeName = \case
  OString _  -> "string"
  ONumber _  -> "number"
  OBool _    -> "boolean"
  ONull      -> "null"
  OArray _   -> "sequence"
  OObject _  -> "object"

-- | Type mismatch: "expected X, found Y"
typeMismatchError :: SrcMeta -> Text -> OValue -> Resolve a
typeMismatchError meta expected val =
  Left (ResolveError (smStart meta) msg (RETypeMismatch expected found Nothing))
  where
    found = oValueTypeName val
    msg = "expected " <> expected <> ", found " <> found

-- | Type mismatch with context tag (e.g., "[delimiter]")
typeMismatchErrorCtx :: SrcMeta -> Text -> OValue -> Text -> Resolve a
typeMismatchErrorCtx meta expected val ctx =
  Left (ResolveError (smStart meta) msg (RETypeMismatch expected found (Just ctx)))
  where
    found = oValueTypeName val
    msg = "expected " <> expected <> ", found " <> found <> " [" <> ctx <> "]"

-- | Variable not found with available vars list.
variableNotFoundError :: SrcMeta -> Text -> [Text] -> Resolve a
variableNotFoundError meta path available =
  Left (ResolveError (smStart meta) msg (REVariableNotFound path available))
  where msg = "Variable not found: " <> path <> ". Available: " <> T.intercalate ", " available

-- | JMESPath expression error.
jmesPathError :: SrcMeta -> Text -> Text -> Text -> Resolve a
jmesPathError meta expr detail varPath =
  Left (ResolveError (smStart meta) msg (REJmesPath expr detail varPath))
  where msg = "Invalid JMESPath expression '" <> expr <> "': " <> detail <> ". Variable: " <> varPath

-- | Property not found in mapping during dot-query.
propertyNotFoundError :: SrcMeta -> Text -> Text -> [Text] -> Resolve a
propertyNotFoundError meta key varPath availKeys =
  Left (ResolveError (smStart meta) msg (REPropertyNotFound key varPath availKeys))
  where msg = "property '" <> key <> "' not found in mapping. Variable: " <> varPath <> ". Keys: " <> T.intercalate ", " availKeys

-- | CloudFormation tag validation error.
cfnValidationError :: SrcMeta -> Text -> Text -> Resolve a
cfnValidationError meta _tagName detail =
  Left (ResolveError (smStart meta) detail (RECfnValidation _tagName))

-- | Handlebars template interpolation error.
handlebarsError :: SrcMeta -> Text -> Resolve a
handlebarsError meta msg =
  Left (ResolveError (smStart meta) ("Handlebars error: " <> msg) REHandlebars)

-- | Template not found in !$expand.
expandNotFoundError :: SrcMeta -> Text -> Resolve a
expandNotFoundError meta templateName =
  Left (ResolveError (smStart meta) msg (REExpandNotFound templateName))
  where msg = "!$expand: template '" <> templateName <> "' not found"

-- | Parse syntax error from !$parseYaml, !$parseJson, !$expand.
parseSyntaxError :: SrcMeta -> Text -> Text -> Resolve a
parseSyntaxError meta prefix detail =
  Left (ResolveError (smStart meta) (prefix <> detail) REParseSyntax)

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

-- | Resolve an AST key-value pair to a (Text, OValue) pair.
resolvePairWith :: TagContext -> (YamlAst, YamlAst) -> Resolve (Text, OValue)
resolvePairWith ctx (keyAst, valAst) = do
  kv <- resolveAst ctx keyAst
  let k = oValueToText kv
  vv <- resolveAst ctx valAst
  pure (k, vv)

-- | Keys that are consumed by the import/preprocessing layer and should be
-- filtered from the output.
isSpecialKey :: Text -> Bool
isSpecialKey k = k `elem` ["$imports", "$defs", "$envValues", "$params"]

resolveMapping :: TagContext -> [(YamlAst, YamlAst)] -> Resolve OValue
resolveMapping ctx pairs
  | not (Map.null (tcCustomTemplateDefs ctx)) && hasResourcesKey pairs = do
      -- This is a top-level mapping containing "Resources" — resolve with expansion
      resolveMappingWithExpansion ctx pairs
  | otherwise = do
      resolved <- traverse (resolvePairWith ctx) pairs
      let filtered = [(k, v) | (k, v) <- resolved, not (isSpecialKey k)]
      pure $ OObject filtered
  where
    hasResourcesKey = any (\(k, _) -> isResourcesKey k)
    isResourcesKey (AstPlainString "Resources" _) = True
    isResourcesKey _ = False

-- | Resolve a top-level mapping that contains a "Resources" key.
-- The Resources value is resolved with custom resource expansion, and
-- global sections from expansions are merged into the top-level mapping.
resolveMappingWithExpansion :: TagContext -> [(YamlAst, YamlAst)] -> Resolve OValue
resolveMappingWithExpansion ctx pairs = do
  -- First resolve all pairs, marking Resources for special handling
  resolved <- traverse (resolvePairWith ctx) pairs
  let filtered = [(k, v) | (k, v) <- resolved, not (isSpecialKey k)]
  -- Find the Resources section and expand custom resources
  case extractResources filtered of
    Nothing -> pure $ OObject filtered
    Just (beforeRes, resources, afterRes) -> do
      (expanded, globalSections) <- expandResources resources
      -- Merge: before + expanded Resources + after + global sections (if not already present)
      let existingKeys = map fst filtered
          newGlobals = [(k, v) | (k, v) <- Map.toList globalSections, k `notElem` existingKeys]
      pure $ OObject (beforeRes ++ [("Resources", OObject expanded)] ++ afterRes ++ newGlobals)
  where
    extractResources :: [(Text, OValue)] -> Maybe ([(Text, OValue)], [(Text, OValue)], [(Text, OValue)])
    extractResources kvs =
      let (before, rest) = break (\(k, _) -> k == "Resources") kvs
      in case rest of
           (("Resources", OObject resources) : after) -> Just (before, resources, after)
           _ -> Nothing

    expandResources :: [(Text, OValue)] -> Resolve ([(Text, OValue)], Map.Map Text OValue)
    expandResources resources = do
      let parentResourceNames = Set.fromList
            [ name | (name, val) <- resources
            , case getResourceType val of
                Just typeName -> not (Map.member typeName (tcCustomTemplateDefs ctx))
                Nothing -> True
            ]
      (expanded, globals) <- foldM (expandOne parentResourceNames) ([], Map.empty) resources
      let deduped = deduplicateResources expanded
      pure (deduped, globals)
      where
        expandOne parentNames (acc, globals) (resName, resVal) =
          case getResourceType resVal of
            Just typeName | Just tmplInfo <- Map.lookup typeName (tcCustomTemplateDefs ctx) -> do
              let reparseF = buildReparse ctx
              case expandCustomResource resName resVal tmplInfo reparseF parentNames of
                Left err -> Left (ResolveError zeroPosition ("Custom resource expansion error: " <> err) REGeneric)
                Right expansionResult ->
                  let mergedGlobals = Map.unionWith mergeGlobalSection globals (erGlobalSections expansionResult)
                  in pure (acc ++ erResources expansionResult, mergedGlobals)
            _ -> pure (acc ++ [(resName, resVal)], globals)

    mergeGlobalSection :: OValue -> OValue -> OValue
    mergeGlobalSection (OObject a) (OObject b) = OObject (a ++ [(k, v) | (k, v) <- b, k `notElem` map fst a])
    mergeGlobalSection _ b = b

getResourceType :: OValue -> Maybe Text
getResourceType (OObject kvs) = case lookupO "Type" kvs of
  Just (OString t) -> Just t
  _ -> Nothing
getResourceType _ = Nothing

-- | Deduplicate a list of (key, value) pairs. When a key appears multiple times,
-- keep the first occurrence's position but use the last occurrence's value
-- (raw resources override expanded ones).
deduplicateResources :: [(Text, OValue)] -> [(Text, OValue)]
deduplicateResources kvs =
  let lastVals = Map.fromList kvs
      go _seen [] = []
      go seen ((k, _v):rest)
        | Set.member k seen = go seen rest
        | otherwise = case Map.lookup k lastVals of
            Just v' -> (k, v') : go (Set.insert k seen) rest
            Nothing -> go seen rest
  in go Set.empty kvs

-- | Build the reparse function for expandCustomResource.
-- Returns OValue to preserve key ordering from the template.
buildReparse :: TagContext -> Map.Map Text OValue -> Text -> Either Text OValue
buildReparse parentCtx params rawBody =
  case parseYaml (BL.fromStrict (TE.encodeUtf8 rawBody)) (fromMaybe "<template>" (tcInputUri parentCtx)) of
    Left (ParseError _ msg) -> Left ("Parse error: " <> msg)
    Right templateAst ->
      let subCtx = parentCtx
            { tcVariables = Map.union params (tcVariables parentCtx)
            }
      in case resolveAst subCtx templateAst of
           Left (ResolveError _ msg _) -> Left msg
           Right resolved -> Right resolved

------------------------------------------------------------------------
-- Template strings (handlebars)
------------------------------------------------------------------------

resolveTemplateString :: TagContext -> SrcMeta -> Text -> Resolve OValue
resolveTemplateString ctx meta template =
  -- Pre-validate: check that template variables exist in context
  case findMissingTemplateVar (tcVariables ctx) template of
    Just missing -> variableNotFoundError meta missing (contextVariableNames ctx)
    Nothing ->
      let ctxValue = Object (KM.fromList
            [(Key.fromText k, toValue v) | (k, v) <- Map.toList (tcVariables ctx)])
      in case interpolate defaultHelpers ctxValue template of
           Right s -> pure (OString s)
           Left (InterpolateError msg) -> handlebarsError meta msg

-- | Find the first undefined variable in a handlebars template.
-- Only checks simple {{var}} references, not block helpers or comments.
findMissingTemplateVar :: Map.Map Text OValue -> Text -> Maybe Text
findMissingTemplateVar vars = go
  where
    go t = case T.breakOn "{{" t of
      (_, rest) | T.null rest -> Nothing
      (_, rest) ->
        let inside = T.drop 2 rest
        in if T.isPrefixOf "#" inside || T.isPrefixOf "/" inside ||
              T.isPrefixOf "!" inside || T.isPrefixOf "else}}" inside
           then skipToClose inside
           else case T.breakOn "}}" inside of
             (expr, closeRest) | not (T.null closeRest) ->
               let varExpr = T.strip expr
                   -- If there's a space, it's a helper call — skip
                   hasSpace = T.any (== ' ') varExpr
                   rootVar = T.takeWhile (\c -> c /= '.' && c /= '[') varExpr
               in if hasSpace || T.null rootVar ||
                     Map.member rootVar vars ||
                     rootVar `elem` ["this", "@index", "@key", "@first", "@last"]
                  then go (T.drop 2 closeRest)
                  else Just rootVar
             _ -> Nothing
    skipToClose t = case T.breakOn "}}" t of
      (_, rest) | T.null rest -> Nothing
      (_, rest) -> go (T.drop 2 rest)

------------------------------------------------------------------------
-- CloudFormation tags
------------------------------------------------------------------------

resolveCfnTag :: TagContext -> SrcMeta -> CloudFormationTag -> Resolve OValue
resolveCfnTag ctx meta tag = do
  let (name, inner) = cfnTagParts tag
  resolved <- resolveAst ctx inner
  -- Single-element array unpacking (matches Rust behavior)
  let unpacked = case resolved of
        OArray [x] -> x
        _          -> resolved
  validateCfnTag meta name unpacked
  pure $ OObject [(name, unpacked)]

-- | Validate CloudFormation intrinsic function arguments.
-- Matches Rust's validate_cloudformation_tag validation rules.
validateCfnTag :: SrcMeta -> Text -> OValue -> Resolve ()
validateCfnTag meta name val = case name of
  "!Ref" -> case val of
    ONull -> cfnValidationError meta "!Ref" "!Ref cannot have null value"
    OString t | T.null t -> cfnValidationError meta "!Ref" "!Ref cannot reference empty string"
    OString _ -> pure ()
    _ -> cfnValidationError meta "!Ref" $ "!Ref expects a string (resource or parameter name), found " <> oValueTypeName val

  "!Sub" -> case val of
    ONull -> cfnValidationError meta "!Sub" "!Sub cannot have null value"
    OString _ -> pure ()
    OArray [OString _, OObject _] -> pure ()
    OArray [OString _, v] -> cfnValidationError meta "!Sub" $ "!Sub array form expects [string, object], found [string, " <> oValueTypeName v <> "]"
    OArray [v, v2] -> cfnValidationError meta "!Sub" $ "!Sub array form expects [string, object], found [" <> oValueTypeName v <> ", " <> oValueTypeName v2 <> "]"
    OArray items -> cfnValidationError meta "!Sub" $ "!Sub with array expects exactly 2 elements [string, variables], found " <> showLen items <> " elements"
    _ -> cfnValidationError meta "!Sub" $ "!Sub expects a string or 2-element array, found " <> oValueTypeName val

  "!GetAtt" -> case val of
    ONull -> cfnValidationError meta "!GetAtt" "!GetAtt cannot have null value"
    OString t | "." `T.isInfixOf` t -> pure ()
    OString _ -> cfnValidationError meta "!GetAtt" "!GetAtt string format requires dot notation: 'ResourceName.AttributeName'"
    OArray [OString _, OString _] -> pure ()
    OArray [v1, v2] -> cfnValidationError meta "!GetAtt" $ "!GetAtt array form expects [string, string], found [" <> oValueTypeName v1 <> ", " <> oValueTypeName v2 <> "]"
    OArray items -> cfnValidationError meta "!GetAtt" $ "!GetAtt expects exactly 2 elements [resource, attribute], found " <> showLen items <> " elements"
    _ -> cfnValidationError meta "!GetAtt" $ "!GetAtt expects a string or 2-element array, found " <> oValueTypeName val

  "!Join" -> case val of
    ONull -> cfnValidationError meta "!Join" "!Join cannot have null value"
    OArray [OString _, OArray _] -> pure ()
    OArray [OString _, v] -> cfnValidationError meta "!Join" $ "!Join expects [delimiter, array], found [string, " <> oValueTypeName v <> "]"
    OArray [v, v2] -> cfnValidationError meta "!Join" $ "!Join expects [string, array], found [" <> oValueTypeName v <> ", " <> oValueTypeName v2 <> "]"
    OArray items -> cfnValidationError meta "!Join" $ "!Join expects exactly 2 elements [delimiter, array], found " <> showLen items <> " elements"
    _ -> cfnValidationError meta "!Join" $ "!Join expects a 2-element array, found " <> oValueTypeName val

  "!Select" -> case val of
    ONull -> cfnValidationError meta "!Select" "!Select cannot have null value"
    OArray [ONumber _, OArray _] -> pure ()
    OArray [ONumber _, v] -> cfnValidationError meta "!Select" $ "!Select expects [index, array], found [number, " <> oValueTypeName v <> "]"
    OArray [v, v2] -> cfnValidationError meta "!Select" $ "!Select expects [number, array], found [" <> oValueTypeName v <> ", " <> oValueTypeName v2 <> "]"
    OArray items -> cfnValidationError meta "!Select" $ "!Select expects exactly 2 elements [index, array], found " <> showLen items <> " elements"
    _ -> cfnValidationError meta "!Select" $ "!Select expects a 2-element array, found " <> oValueTypeName val

  "!Split" -> case val of
    ONull -> cfnValidationError meta "!Split" "!Split cannot have null value"
    OArray [OString _, OString _] -> pure ()
    OArray [v1, v2] -> cfnValidationError meta "!Split" $ "!Split expects [string, string], found [" <> oValueTypeName v1 <> ", " <> oValueTypeName v2 <> "]"
    OArray items -> cfnValidationError meta "!Split" $ "!Split expects exactly 2 elements [delimiter, string], found " <> showLen items <> " elements"
    _ -> cfnValidationError meta "!Split" $ "!Split expects a 2-element array, found " <> oValueTypeName val

  "!FindInMap" -> case val of
    ONull -> cfnValidationError meta "!FindInMap" "!FindInMap cannot have null value"
    OArray items | length items == 3 -> pure ()
    OArray items -> cfnValidationError meta "!FindInMap" $ "!FindInMap expects exactly 3 elements [map_name, key1, key2], found " <> showLen items <> " elements"
    _ -> cfnValidationError meta "!FindInMap" $ "!FindInMap expects a 3-element array, found " <> oValueTypeName val

  "!If" -> case val of
    ONull -> cfnValidationError meta "!If" "!If cannot have null value"
    OArray items | length items == 3 -> pure ()
    OArray items -> cfnValidationError meta "!If" $ "!If expects a 3-element array [condition, true_value, false_value], found " <> showLen items <> " elements"
    _ -> cfnValidationError meta "!If" $ "!If expects a 3-element array, found " <> oValueTypeName val

  "!Equals" -> case val of
    ONull -> cfnValidationError meta "!Equals" "!Equals cannot have null value"
    OArray items | length items == 2 -> pure ()
    OArray items -> cfnValidationError meta "!Equals" $ "!Equals expects a 2-element array, found " <> showLen items <> " elements"
    _ -> cfnValidationError meta "!Equals" $ "!Equals expects a 2-element array, found " <> oValueTypeName val

  "!Not" -> case val of
    ONull -> cfnValidationError meta "!Not" "!Not cannot have null value"
    OArray items | length items == 1 -> pure ()
    OArray items -> cfnValidationError meta "!Not" $ "!Not expects a 1-element array, found " <> showLen items <> " elements"
    _ -> cfnValidationError meta "!Not" $ "!Not expects a 1-element array, found " <> oValueTypeName val

  -- Null-only validation for remaining tags (matches Rust catch-all)
  _ -> case val of
    ONull -> cfnValidationError meta name (name <> " cannot have null value")
    _ -> pure ()

-- | Show list length as Text.
showLen :: [a] -> Text
showLen = T.pack . show . length

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
resolveVarLookup ctx meta (VarLookupTag rawPath query jmesPathExpr) = do
  -- Expand bracket notation: config[environment] -> config.production
  let path = expandBrackets rawPath ctx
  baseVal <- case resolveDotPathO path ctx of
    Just val -> pure val
    Nothing -> variableNotFoundError meta path (contextVariableNames ctx)
  queriedVal <- case query of
    Nothing -> pure baseVal
    Just q -> applyDotQueryValidated meta path q baseVal
  case jmesPathExpr of
    Nothing -> pure queriedVal
    Just expr -> case applyJmesPath expr (toValue queriedVal) of
      Right v -> pure (fromValue v)
      Left (JMESPathError msg) -> jmesPathError meta expr msg path

expandBrackets :: Text -> TagContext -> Text
expandBrackets path ctx = go (10 :: Int) path
  where
    go depth p
      | depth <= 0 = p  -- prevent infinite recursion
      | T.isInfixOf "[" p =
          let (before, rest) = T.breakOn "[" p
              (varName, after) = T.breakOn "]" (T.drop 1 rest)
              suffix = T.drop 1 after
              resolved = case getVariable varName ctx of
                Just (OString s) -> s
                Just (ONumber n) -> case Sci.floatingOrInteger n of
                  Left (d :: Double) -> T.pack (show d)
                  Right (i :: Integer) -> T.pack (show i)
                _ -> varName
              expanded = before <> "." <> resolved <> suffix
          in go (depth - 1) expanded
      | otherwise = p

-- | Resolve a dot-path to an OValue (preserving key ordering)
resolveDotPathO :: Text -> TagContext -> Maybe OValue
resolveDotPathO path ctx =
  case T.splitOn "." path of
    -- T.splitOn never returns [], but pattern match for totality
    (root:rest) -> case getVariable root ctx of
      Nothing -> Nothing
      Just val -> traversePathO rest val
    [] -> Nothing

-- | Traverse a path through an OValue
traversePathO :: [Text] -> OValue -> Maybe OValue
traversePathO [] val = Just val
traversePathO (seg:rest) val = case val of
  OObject kvs -> case lookupO seg kvs of
    Just v  -> traversePathO rest v
    Nothing -> Nothing
  OArray arr  -> case reads (T.unpack seg) of
    [(i, "")] | i >= 0 -> case drop i arr of
      (v:_) -> traversePathO rest v
      _     -> Nothing
    _ -> Nothing
  _ -> Nothing


-- | Like applyDotQueryO but validates that all comma-separated keys exist.
applyDotQueryValidated :: SrcMeta -> Text -> Text -> OValue -> Resolve OValue
applyDotQueryValidated meta varPath q val
  -- Comma-separated key selection: validate all keys exist
  | T.isInfixOf "," q = case val of
      OObject kvs ->
        let keys = map T.strip (T.splitOn "," q)
            missing = filter (\k -> isNothing (lookupO k kvs)) keys
        in case missing of
          (m:_) -> propertyNotFoundError meta m varPath (map fst kvs)
          [] -> pure $ OObject [(k, v) | k <- keys, Just v <- [lookupO k kvs]]
      _ -> pure ONull
  -- Single dot-path traversal
  | otherwise =
      let segments = filter (not . T.null) (T.splitOn "." q)
      in pure $ case traversePathO segments val of
           Just v  -> v
           Nothing -> ONull

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
      foldBindings (withVariable name val c) rest

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
              [ (varName, item)
              , (varName <> "Idx", ONumber (fromIntegral i))
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
    _ -> typeMismatchError meta "sequence" itemsVal

resolveMerge :: TagContext -> SrcMeta -> MergeTag -> Resolve OValue
resolveMerge ctx meta (MergeTag sources) = do
  vals <- traverse (resolveAst ctx) sources
  let merge acc v = case v of
        OObject kvs -> pure $ mergeOObjects acc kvs
        _ -> typeMismatchError meta "object" v
  foldM merge (OObject []) vals

mergeOObjects :: OValue -> [(Text, OValue)] -> OValue
mergeOObjects (OObject base) overlay =
  let -- Update base values where overlay has same key
      updatedBase = map (\(k, v) -> case lookup k overlay of
                           Just v' -> (k, v')
                           Nothing -> (k, v)) base
      -- Append new keys from overlay that aren't in base
      baseKeys = map fst base
      newKeys = filter (\(k, _) -> k `notElem` baseKeys) overlay
  in OObject (updatedBase ++ newKeys)
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
    (OString _, v) -> typeMismatchError meta "string" v
    (v, _)          -> typeMismatchError meta "string" v

resolveJoin :: TagContext -> SrcMeta -> JoinTag -> Resolve OValue
resolveJoin ctx meta (JoinTag delimAst arrAst) = do
  delimVal <- resolveAst ctx delimAst
  arrVal <- resolveAst ctx arrAst
  case (delimVal, arrVal) of
    (OString d, OArray arr) -> do
      -- Validate that all items are string-convertible (not objects or arrays)
      texts <- traverse (\v -> case v of
        OObject _ -> typeMismatchError meta "string" v
        OArray _  -> typeMismatchError meta "string" v
        _         -> pure (oValueToText v)
        ) arr
      pure $ OString $ T.intercalate d texts
    (OString _, v) -> typeMismatchError meta "sequence" v
    (v, _)          -> typeMismatchErrorCtx meta "string" v "delimiter"

resolveConcatMap :: TagContext -> SrcMeta -> ConcatMapTag -> Resolve OValue
resolveConcatMap ctx meta (ConcatMapTag items template var filterExpr) = do
  result <- resolveMapItems ctx meta items template (fromMaybeVar var) filterExpr
  case result of
    OArray arr -> pure $ OArray $ concatMap flattenItem arr
    _ -> tagSyntaxError meta (Just "!$concatMap") "!$concatMap: unexpected result"
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
            _ -> typeMismatchError meta "object" v
      foldM merge (OObject []) arr
    _ -> tagSyntaxError meta (Just "!$mergeMap") "!$mergeMap: unexpected result"

resolveMapListToHash :: TagContext -> SrcMeta -> MapListToHashTag -> Resolve OValue
resolveMapListToHash ctx meta (MapListToHashTag items template var filterExpr) = do
  result <- resolveMapItems ctx meta items template (fromMaybeVar var) filterExpr
  case result of
    OArray arr -> do
      pairs <- traverse extractPair arr
      pure $ OObject pairs
    _ -> tagSyntaxError meta (Just "!$mapListToHash") "!$mapListToHash: unexpected result"
  where
    extractPair (OArray [k, v]) = pure (oValueToText k, v)
    extractPair (OObject kvs)
      | Just k <- lookupO "key" kvs, Just v <- lookupO "value" kvs =
          pure (oValueToText k, v)
    extractPair (OObject kvs) = case kvs of
      [(k, v)] -> pure (k, v)
      _ -> tagSyntaxError meta (Just "!$mapListToHash") "!$mapListToHash: object item must have exactly one key"
    extractPair v = typeMismatchError meta "2-element sequence or object" v

resolveMapValues :: TagContext -> SrcMeta -> MapValuesTag -> Resolve OValue
resolveMapValues ctx meta (MapValuesTag itemsAst templateAst var) = do
  itemsVal <- resolveAst ctx itemsAst
  case itemsVal of
    OObject kvs -> do
      pairs <- traverse (\(k, v) -> do
        let binding = OObject [("key", OString k), ("value", v)]
            itemCtx = withVariable (fromMaybeVar var) binding ctx
        resolved <- resolveAst itemCtx templateAst
        pure (k, resolved)
        ) kvs
      pure $ OObject pairs
    _ -> typeMismatchError meta "object" itemsVal

resolveGroupBy :: TagContext -> SrcMeta -> GroupByTag -> Resolve OValue
resolveGroupBy ctx meta (GroupByTag itemsAst keyAst var _templateAst) = do
  itemsVal <- resolveAst ctx itemsAst
  case itemsVal of
    OArray arr -> do
      groups <- foldM (\acc item -> do
        let itemCtx = withVariable (fromMaybeVar var) item ctx
        keyVal <- resolveAst itemCtx keyAst
        let k = oValueToText keyVal
            existing = case lookupO k acc of
              Just (OArray v) -> v
              _ -> []
        pure $ insertO k (OArray (existing ++ [item])) acc
        ) [] arr
      pure $ OObject groups
    _ -> typeMismatchError meta "sequence" itemsVal

resolveFromPairs :: TagContext -> SrcMeta -> FromPairsTag -> Resolve OValue
resolveFromPairs ctx meta (FromPairsTag sourceAst) = do
  sourceVal <- resolveAst ctx sourceAst
  case sourceVal of
    OArray arr -> do
      pairs <- traverse extractPair arr
      pure $ OObject pairs
    _ -> typeMismatchError meta "sequence" sourceVal
  where
    extractPair (OArray [k, v]) = pure (oValueToText k, v)
    extractPair v = typeMismatchError meta "sequence" v

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
        Left (ParseError _ msg) -> parseSyntaxError meta "!$parseYaml: " msg
    _ -> typeMismatchError meta "string" val

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
      Left err -> parseSyntaxError meta "!$parseJson: " (T.pack err)
    _ -> typeMismatchError meta "string" val

resolveEscape :: TagContext -> SrcMeta -> EscapeTag -> Resolve OValue
resolveEscape _ctx _meta (EscapeTag contentAst) =
  pure $ fromValue $ astToValueRaw contentAst

resolveExpand :: TagContext -> SrcMeta -> ExpandTag -> Resolve OValue
resolveExpand ctx meta (ExpandTag templateRefAst paramsAst) = do
  -- 1. Resolve template reference to get template name
  templateVal <- resolveAst ctx templateRefAst
  let templateName = oValueToText templateVal
  -- 2. Look up template info
  case Map.lookup templateName (tcCustomTemplateDefs ctx) of
    Nothing -> expandNotFoundError meta templateName
    Just tmplInfo -> do
      -- 3. Resolve provided params
      providedParams <- resolveAst ctx paramsAst
      let provided = case providedParams of
            OObject kvs -> Map.fromList kvs
            _ -> Map.empty
      -- 4. Merge with defaults from $params (defaults are Value, convert to OValue)
      let merged = mergeExpandParams (tiParams tmplInfo) provided
      -- 5. Re-parse the raw template YAML
      case parseYaml (BL.fromStrict (TE.encodeUtf8 (tiRawBody tmplInfo))) (tiLocation tmplInfo) of
        Left (ParseError _ msg) -> parseSyntaxError meta "!$expand parse error: " msg
        Right templateAst' -> do
          -- 6. Build sub-context with merged params as variables
          let subCtx = ctx
                { tcVariables = Map.union merged (tcVariables ctx)
                , tcInputUri = Just (tiLocation tmplInfo)
                }
          -- 7. Resolve the template body
          resolveAst subCtx templateAst'

mergeExpandParams :: [ParamDef] -> Map.Map Text OValue -> Map.Map Text OValue
mergeExpandParams defs provided = List.foldl' addParam provided defs
  where
    addParam acc pd =
      case Map.lookup (pdName pd) acc of
        Just _ -> acc
        Nothing -> case pdDefault pd of
          Just defVal -> Map.insert (pdName pd) defVal acc
          Nothing -> acc

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
rawKeyText (AstBool True _) = "true"
rawKeyText (AstBool False _) = "false"
rawKeyText (AstNull _) = "null"
rawKeyText (AstNumber n _) = case Sci.floatingOrInteger n of
  Left (d :: Double) -> T.pack (show d)
  Right (i :: Integer) -> T.pack (show i)
rawKeyText _ = ""

------------------------------------------------------------------------
-- OValue list helpers
------------------------------------------------------------------------

insertO :: Text -> OValue -> [(Text, OValue)] -> [(Text, OValue)]
insertO k v [] = [(k, v)]
insertO k v ((k', v'):rest)
  | k == k' = (k, v) : rest
  | otherwise = (k', v') : insertO k v rest

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

fromMaybeVar :: Maybe Text -> Text
fromMaybeVar = fromMaybe "item"

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
