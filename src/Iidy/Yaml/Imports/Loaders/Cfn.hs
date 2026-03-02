{-# LANGUAGE OverloadedRecordDot #-}
-- | CloudFormation stack import loader.
-- Parses cfn:field:location format matching JS source of truth.
-- Supports 6 subtypes: output, export, parameter, tag, resource, stack.
module Iidy.Yaml.Imports.Loaders.Cfn
  ( loadCfnImport
  , parseCfnLocation
  , CfnField(..)
  ) where

import Control.Exception (try)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.List (find)
import qualified Data.List as List
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import qualified Amazonka
import qualified Amazonka.CloudFormation.Types as CF
import qualified Amazonka.CloudFormation.DescribeStacks as DS
import qualified Amazonka.CloudFormation.ListExports as LE
import qualified Amazonka.CloudFormation.DescribeStackResources as DSR

import Iidy.Yaml.Imports.Types (ImportData(..), ImportError(..), ImportType(..))

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

-- | CFN sub-type field parsed from cfn:field:location format.
data CfnField
  = CfnOutput
  | CfnExport
  | CfnParameter
  | CfnTag
  | CfnResource
  | CfnStack
  deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

-- | Load a CloudFormation import.
-- Accepts @cfn:field:location@ format (matching JS source of truth).
loadCfnImport :: Amazonka.Env -> Text -> IO (Either ImportError ImportData)
loadCfnImport awsEnv location = do
  case parseCfnLocation location of
    Left err -> pure (Left err)
    Right (CfnOutput, resolvedLoc) ->
      loadCfnOutput awsEnv location resolvedLoc
    Right (CfnExport, resolvedLoc) ->
      loadCfnExport awsEnv location resolvedLoc
    Right (CfnParameter, resolvedLoc) ->
      loadCfnParameter awsEnv location resolvedLoc
    Right (CfnTag, resolvedLoc) ->
      loadCfnTag awsEnv location resolvedLoc
    Right (CfnResource, resolvedLoc) ->
      loadCfnResource awsEnv location resolvedLoc
    Right (CfnStack, resolvedLoc) ->
      loadCfnStack awsEnv location resolvedLoc

------------------------------------------------------------------------
-- Location parsing
------------------------------------------------------------------------

-- | Parse a cfn: location into (field, resolvedLocation).
-- JS format: location.split(':') gives [cfn, field, ...rest], resolvedLocation = rest.join(':')
parseCfnLocation :: Text -> Either ImportError (CfnField, Text)
parseCfnLocation location =
  let stripped = maybe location id (T.stripPrefix "cfn:" location)
      parts = T.splitOn ":" stripped
  in case parts of
       (fieldStr : rest)
         | not (null rest) ->
             case parseField fieldStr of
               Just field -> Right (field, T.intercalate ":" rest)
               Nothing -> Left $ ImportError $
                 "Invalid cfn sub-type: " <> fieldStr
                 <> ". Expected: output|export|parameter|tag|resource|stack"
         | otherwise -> Left $ ImportError $
             "Invalid cfn import format. Expected cfn:field:location, got: " <> location
       [] -> Left $ ImportError $
         "Invalid cfn import format. Expected cfn:field:location, got: " <> location

-- | Parse a field name string into a CfnField.
parseField :: Text -> Maybe CfnField
parseField = \case
  "output"    -> Just CfnOutput
  "export"    -> Just CfnExport
  "parameter" -> Just CfnParameter
  "tag"       -> Just CfnTag
  "resource"  -> Just CfnResource
  "stack"     -> Just CfnStack
  _           -> Nothing

------------------------------------------------------------------------
-- Output sub-type
------------------------------------------------------------------------

-- | Load a single output or all outputs from a stack.
-- resolvedLoc is "Stack/Key" (single) or "Stack" (all).
loadCfnOutput :: Amazonka.Env -> Text -> Text -> IO (Either ImportError ImportData)
loadCfnOutput awsEnv location resolvedLoc = do
  let (stackName, mKey) = splitStackKey resolvedLoc
  withStack awsEnv location stackName $ \stack ->
    case mKey of
      Just key -> do
        let outputs = fromMaybe [] stack.outputs
            mOutput = find (\o -> o.outputKey == Just key) outputs
        case mOutput of
          Nothing -> pure $ Left $ ImportError $
            "Output key '" <> key <> "' not found in stack: " <> stackName
          Just output -> do
            let val = fromMaybe "" output.outputValue
            pure $ Right $ mkImportData location val (String val)
      Nothing -> do
        let outputs = fromMaybe [] stack.outputs
            pairs = map (\o -> (fromMaybe "" o.outputKey, fromMaybe "" o.outputValue)) outputs
        pure $ Right $ mkMappingImportData location pairs

------------------------------------------------------------------------
-- Export sub-type
------------------------------------------------------------------------

-- | Load a CloudFormation export by name.
-- resolvedLoc is the export name (no stack involved).
loadCfnExport :: Amazonka.Env -> Text -> Text -> IO (Either ImportError ImportData)
loadCfnExport awsEnv location exportName = do
  if T.null exportName
    then pure $ Left $ ImportError $ "Empty export name in: " <> location
    else do
      result <- try @Amazonka.Error (fetchExports awsEnv)
      case result of
        Left ex -> pure $ Left $ ImportError $
          "CFN ListExports error: " <> T.pack (show ex)
        Right exports -> do
          let mExport = find (\e -> e.name == Just exportName) exports
          case mExport of
            Nothing -> pure $ Left $ ImportError $
              "Export '" <> exportName <> "' not found"
            Just export' -> do
              let val = fromMaybe "" export'.value
              pure $ Right $ mkImportData location val (String val)

------------------------------------------------------------------------
-- Parameter sub-type
------------------------------------------------------------------------

-- | Load a single parameter or all parameters from a stack.
loadCfnParameter :: Amazonka.Env -> Text -> Text -> IO (Either ImportError ImportData)
loadCfnParameter awsEnv location resolvedLoc = do
  let (stackName, mKey) = splitStackKey resolvedLoc
  withStack awsEnv location stackName $ \stack ->
    case mKey of
      Just key -> do
        let params = fromMaybe [] stack.parameters
            mParam = find (\p -> p.parameterKey == Just key) params
        case mParam of
          Nothing -> pure $ Left $ ImportError $
            "Parameter '" <> key <> "' not found in stack: " <> stackName
          Just param -> do
            let val = fromMaybe "" param.parameterValue
            pure $ Right $ mkImportData location val (String val)
      Nothing -> do
        let params = fromMaybe [] stack.parameters
            pairs = map (\p -> (fromMaybe "" p.parameterKey, fromMaybe "" p.parameterValue)) params
        pure $ Right $ mkMappingImportData location pairs

------------------------------------------------------------------------
-- Tag sub-type
------------------------------------------------------------------------

-- | Load a single tag or all tags from a stack.
loadCfnTag :: Amazonka.Env -> Text -> Text -> IO (Either ImportError ImportData)
loadCfnTag awsEnv location resolvedLoc = do
  let (stackName, mKey) = splitStackKey resolvedLoc
  withStack awsEnv location stackName $ \stack ->
    case mKey of
      Just key -> do
        let tags = fromMaybe [] stack.tags
            mTag = find (\t -> t.key == key) tags
        case mTag of
          Nothing -> pure $ Left $ ImportError $
            "Tag '" <> key <> "' not found in stack: " <> stackName
          Just tag -> do
            let val = tag.value
            pure $ Right $ mkImportData location val (String val)
      Nothing -> do
        let tags = fromMaybe [] stack.tags
            pairs = map (\t -> (t.key, t.value)) tags
        pure $ Right $ mkMappingImportData location pairs

------------------------------------------------------------------------
-- Resource sub-type
------------------------------------------------------------------------

-- | Load a single resource or all resources from a stack.
loadCfnResource :: Amazonka.Env -> Text -> Text -> IO (Either ImportError ImportData)
loadCfnResource awsEnv location resolvedLoc = do
  let (stackName, mKey) = splitStackKey resolvedLoc
  if T.null stackName
    then pure $ Left $ ImportError $ "Empty stack name in: " <> location
    else do
      result <- try @Amazonka.Error (fetchResources awsEnv stackName)
      case result of
        Left ex -> pure $ Left $ ImportError $
          "CFN DescribeStackResources error for " <> stackName <> ": " <> T.pack (show ex)
        Right resources ->
          case mKey of
            Just key -> do
              let mResource = find (\r -> r.logicalResourceId == key) resources
              case mResource of
                Nothing -> pure $ Left $ ImportError $
                  "Resource '" <> key <> "' not found in stack: " <> stackName
                Just resource -> do
                  let doc = resourceToValue resource
                      rawData = T.pack (show doc)
                  pure $ Right $ mkImportData location rawData doc
            Nothing -> do
              let km = List.foldl' (\acc r ->
                        KM.insert (Key.fromText r.logicalResourceId)
                                  (resourceToValue r) acc)
                      KM.empty resources
                  doc = Object km
                  rawData = T.pack (show doc)
              pure $ Right $ mkImportData location rawData doc

-- | Convert a StackResource to a JSON Value (mapping).
resourceToValue :: CF.StackResource -> Value
resourceToValue r =
  let km = KM.fromList
        [ (Key.fromText "LogicalResourceId", String r.logicalResourceId)
        , (Key.fromText "PhysicalResourceId",
            maybe Null String r.physicalResourceId)
        , (Key.fromText "ResourceType", String r.resourceType)
        , (Key.fromText "ResourceStatus",
            String (CF.fromResourceStatus r.resourceStatus))
        ]
  in Object km

------------------------------------------------------------------------
-- Stack (full) sub-type
------------------------------------------------------------------------

-- | Load full stack data (Outputs + Parameters + Tags).
loadCfnStack :: Amazonka.Env -> Text -> Text -> IO (Either ImportError ImportData)
loadCfnStack awsEnv location resolvedLoc = do
  let stackName = resolvedLoc
  withStack awsEnv location stackName $ \stack -> do
    let outputPairs = map (\o -> (fromMaybe "" o.outputKey, fromMaybe "" o.outputValue))
                          (fromMaybe [] stack.outputs)
        paramPairs  = map (\p -> (fromMaybe "" p.parameterKey, fromMaybe "" p.parameterValue))
                          (fromMaybe [] stack.parameters)
        tagPairs    = map (\t -> (t.key, t.value))
                          (fromMaybe [] stack.tags)
        outputsKm = pairsToKeyMap outputPairs
        paramsKm  = pairsToKeyMap paramPairs
        tagsKm    = pairsToKeyMap tagPairs
        topKm = KM.fromList
          [ (Key.fromText "Outputs",    Object outputsKm)
          , (Key.fromText "Parameters", Object paramsKm)
          , (Key.fromText "Tags",       Object tagsKm)
          ]
        doc = Object topKm
        rawData = T.pack (show doc)
    pure $ Right $ mkImportData location rawData doc

------------------------------------------------------------------------
-- AWS fetch helpers
------------------------------------------------------------------------

-- | Fetch a stack description.
fetchStack :: Amazonka.Env -> Text -> IO (Either ImportError CF.Stack)
fetchStack awsEnv stackName = runResourceT $ do
  let req = DS.newDescribeStacks { DS.stackName = Just stackName }
  resp <- Amazonka.send awsEnv req
  let stacks = fromMaybe [] resp.stacks
  case listToMaybe stacks of
    Nothing -> pure $ Left $ ImportError $ "Stack not found: " <> stackName
    Just stack -> pure (Right stack)

-- | Fetch exports (non-paginated, matching Rust behavior).
fetchExports :: Amazonka.Env -> IO [CF.Export]
fetchExports awsEnv = runResourceT $ do
  let req = LE.newListExports
  resp <- Amazonka.send awsEnv req
  pure $ fromMaybe [] resp.exports

-- | Fetch stack resources.
fetchResources :: Amazonka.Env -> Text -> IO [CF.StackResource]
fetchResources awsEnv stackName = runResourceT $ do
  let req = DSR.newDescribeStackResources { DSR.stackName = Just stackName }
  resp <- Amazonka.send awsEnv req
  pure $ fromMaybe [] resp.stackResources

-- | Fetch stack and call a handler with it, wrapping exceptions.
withStack
  :: Amazonka.Env
  -> Text  -- ^ original location (for error messages)
  -> Text  -- ^ stack name
  -> (CF.Stack -> IO (Either ImportError ImportData))
  -> IO (Either ImportError ImportData)
withStack awsEnv location stackName handler = do
  if T.null stackName
    then pure $ Left $ ImportError $ "Empty stack name in: " <> location
    else do
      result <- try @Amazonka.Error (fetchStack awsEnv stackName)
      case result of
        Left ex -> pure $ Left $ ImportError $
          "CFN fetch error for " <> stackName <> ": " <> T.pack (show ex)
        Right (Left err) -> pure (Left err)
        Right (Right stack) -> handler stack

------------------------------------------------------------------------
-- Data construction helpers
------------------------------------------------------------------------

-- | Build an ImportData with ImportCfn type.
mkImportData :: Text -> Text -> Value -> ImportData
mkImportData location rawData doc = ImportData
  { idType     = ImportCfn
  , idLocation = location
  , idRawData  = rawData
  , idDoc      = doc
  }

-- | Build an ImportData from key-value pairs (as Object mapping).
mkMappingImportData :: Text -> [(Text, Text)] -> ImportData
mkMappingImportData location pairs =
  let km = pairsToKeyMap pairs
      doc = Object km
      rawData = T.intercalate "\n" [k <> ": " <> v | (k, v) <- pairs]
  in mkImportData location rawData doc

-- | Convert key-value pairs to a KeyMap.
pairsToKeyMap :: [(Text, Text)] -> KM.KeyMap Value
pairsToKeyMap = List.foldl' (\acc (k, v) -> KM.insert (Key.fromText k) (String v) acc) KM.empty

-- | Split "Stack/Key" into (Stack, Just Key) or "Stack" into (Stack, Nothing).
splitStackKey :: Text -> (Text, Maybe Text)
splitStackKey loc =
  case T.breakOn "/" loc of
    (stack, rest)
      | T.null rest -> (stack, Nothing)
      | otherwise   -> (stack, Just (T.drop 1 rest))
