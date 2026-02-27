{-# LANGUAGE OverloadedRecordDot #-}
-- | CloudFormation stack import loader.
-- Parses cfn:field:location format matching JS source of truth.
module Iidy.Yaml.Imports.Loaders.Cfn
  ( loadCfnImport
  , parseCfnLocation
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.List (find)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import qualified Amazonka
import qualified Amazonka.CloudFormation.Types as CF
import qualified Amazonka.CloudFormation.DescribeStacks as DS

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
-- Currently only @cfn:output:Stack/Key@ is implemented.
loadCfnImport :: Amazonka.Env -> Text -> IO (Either ImportError ImportData)
loadCfnImport awsEnv location = do
  case parseCfnLocation location of
    Left err -> pure (Left err)
    Right (CfnOutput, resolvedLoc) ->
      loadCfnOutput awsEnv location resolvedLoc
    Right (field, _) ->
      pure $ Left $ ImportError $
        "CFN sub-type '" <> fieldName field <> "' is not yet implemented"

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

-- | Convert a CfnField back to its string name.
fieldName :: CfnField -> Text
fieldName = \case
  CfnOutput    -> "output"
  CfnExport    -> "export"
  CfnParameter -> "parameter"
  CfnTag       -> "tag"
  CfnResource  -> "resource"
  CfnStack     -> "stack"

------------------------------------------------------------------------
-- Output sub-type
------------------------------------------------------------------------

-- | Load a single output or all outputs from a stack.
-- resolvedLoc is "Stack/Key" (single) or "Stack" (all).
loadCfnOutput :: Amazonka.Env -> Text -> Text -> IO (Either ImportError ImportData)
loadCfnOutput awsEnv location resolvedLoc = do
  let (stackName, mKey) = splitStackKey resolvedLoc
  if T.null stackName
    then pure $ Left $ ImportError $ "Empty stack name in: " <> location
    else do
      result <- try @SomeException (fetchStack awsEnv stackName)
      case result of
        Left ex -> pure $ Left $ ImportError $
          "CFN fetch error for " <> stackName <> ": " <> T.pack (show ex)
        Right (Left err) -> pure (Left err)
        Right (Right stack) ->
          case mKey of
            Just key -> lookupOutput location stackName key stack
            Nothing  -> allOutputs location stack

-- | Look up a single output key from a stack.
lookupOutput :: Text -> Text -> Text -> CF.Stack -> IO (Either ImportError ImportData)
lookupOutput location stackName key stack = do
  let outputs = fromMaybe [] stack.outputs
      mOutput = find (\o -> o.outputKey == Just key) outputs
  case mOutput of
    Nothing -> pure $ Left $ ImportError $
      "Output key '" <> key <> "' not found in stack: " <> stackName
    Just output -> do
      let val = fromMaybe "" output.outputValue
      pure $ Right $ ImportData
        { idType     = ImportCfn
        , idLocation = location
        , idRawData  = val
        , idDoc      = String val
        }

-- | Return all outputs as a mapping.
allOutputs :: Text -> CF.Stack -> IO (Either ImportError ImportData)
allOutputs location stack = do
  let outputs = fromMaybe [] stack.outputs
      pairs = map (\o -> (fromMaybe "" o.outputKey, fromMaybe "" o.outputValue)) outputs
      km = foldl' (\acc (k, v) -> KM.insert (Key.fromText k) (String v) acc) KM.empty pairs
      mapping = Object km
      rawData = T.intercalate "\n" [k <> ": " <> v | (k, v) <- pairs]
  pure $ Right $ ImportData
    { idType     = ImportCfn
    , idLocation = location
    , idRawData  = rawData
    , idDoc      = mapping
    }

------------------------------------------------------------------------
-- AWS fetch
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

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Split "Stack/Key" into (Stack, Just Key) or "Stack" into (Stack, Nothing).
splitStackKey :: Text -> (Text, Maybe Text)
splitStackKey loc =
  case T.breakOn "/" loc of
    (stack, rest)
      | T.null rest -> (stack, Nothing)
      | otherwise   -> (stack, Just (T.drop 1 rest))
