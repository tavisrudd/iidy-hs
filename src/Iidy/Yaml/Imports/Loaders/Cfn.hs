{-# LANGUAGE OverloadedRecordDot #-}
-- | CloudFormation stack output import loader.
module Iidy.Yaml.Imports.Loaders.Cfn
  ( loadCfnImport
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Trans.Resource (runResourceT)
import Data.List (find)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import qualified Amazonka
import qualified Amazonka.CloudFormation.Types as CF
import qualified Amazonka.CloudFormation.DescribeStacks as DS

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

-- | Load a CloudFormation stack output value.
-- Accepts @cfn:stackName/outputKey@ or @cfn:stackName.outputKey@.
-- Returns the output value as text, or an error message.
loadCfnImport :: Amazonka.Env -> Text -> IO (Either Text Text)
loadCfnImport awsEnv location = do
  let ref = stripCfnPrefix location
  case parseCfnRef ref of
    Left err -> pure (Left err)
    Right (stackName, outputKey) -> do
      result <- try @SomeException (fetchCfnOutput awsEnv stackName outputKey)
      case result of
        Left ex  -> pure $ Left $
          "CFN fetch error for " <> stackName <> "/" <> outputKey <> ": " <> T.pack (show ex)
        Right (Left err)  -> pure (Left err)
        Right (Right val) -> pure (Right val)

------------------------------------------------------------------------
-- CFN fetch
------------------------------------------------------------------------

-- | Describe a stack and find the specified output key.
fetchCfnOutput :: Amazonka.Env -> Text -> Text -> IO (Either Text Text)
fetchCfnOutput awsEnv stackName outputKey = runResourceT $ do
  let req = DS.newDescribeStacks { DS.stackName = Just stackName }
  resp <- Amazonka.send awsEnv req
  let stacks = fromMaybe [] resp.stacks
  case listToMaybe stacks of
    Nothing ->
      pure $ Left $ "Stack not found: " <> stackName
    Just stack ->
      let outputs = fromMaybe [] stack.outputs
          mOutput = find (outputHasKey outputKey) outputs
      in case mOutput of
           Nothing ->
             pure $ Left $
               "Output key '" <> outputKey <> "' not found in stack: " <> stackName
           Just output ->
             pure $ Right $ fromMaybe "" output.outputValue

------------------------------------------------------------------------
-- Reference parsing
------------------------------------------------------------------------

-- | Check whether an output record matches the given key.
outputHasKey :: Text -> CF.Output -> Bool
outputHasKey key output = output.outputKey == Just key

-- | Parse a CFN reference: @stackName/outputKey@ or @stackName.outputKey@.
-- Both slash and dot separators are supported.
parseCfnRef :: Text -> Either Text (Text, Text)
parseCfnRef ref =
  case tryBreakOn "/" ref of
    Just result -> validateParts result ref
    Nothing     ->
      case tryBreakOn "." ref of
        Just result -> validateParts result ref
        Nothing     ->
          Left $ "CFN reference must be 'stackName/outputKey' or 'stackName.outputKey': " <> ref

validateParts :: (Text, Text) -> Text -> Either Text (Text, Text)
validateParts (stackName, outputKey) ref
  | T.null stackName = Left $ "CFN reference has empty stack name: " <> ref
  | T.null outputKey = Left $ "CFN reference has empty output key: " <> ref
  | otherwise        = Right (stackName, outputKey)

-- | Break on separator and return (before, after-separator).
-- Returns Nothing if the separator is absent.
tryBreakOn :: Text -> Text -> Maybe (Text, Text)
tryBreakOn sep text =
  case T.breakOn sep text of
    (before, rest)
      | T.null rest -> Nothing
      | otherwise   -> Just (before, T.drop (T.length sep) rest)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Strip the @cfn:@ prefix from a location string.
stripCfnPrefix :: Text -> Text
stripCfnPrefix loc =
  maybe loc id (T.stripPrefix "cfn:" loc)
