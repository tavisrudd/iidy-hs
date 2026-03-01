-- | CloudFormation API request builder.
--
-- Converts StackArgs + CfnContext into properly formatted CloudFormation
-- API requests with template loading, parameter mapping, and token injection.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.RequestBuilder
  ( -- * Request building
    buildCreateStackRequest
  , buildUpdateStackRequest
  , buildDeleteStackRequest
  , buildCreateChangeSetRequest
    -- * Helpers
  , mapCapability
  , mapCapabilities
  , mapParameters
  , mapTags
  , mapOnFailure
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T

import qualified Amazonka.CloudFormation as CF
-- Import operation modules with unique qualifiers for unambiguous field access
import qualified Amazonka.CloudFormation.CreateStack as CS
import qualified Amazonka.CloudFormation.UpdateStack as US
import qualified Amazonka.CloudFormation.DeleteStack as DS
import qualified Amazonka.CloudFormation.CreateChangeSet as CCS
import qualified Amazonka.CloudFormation.Types.Parameter as Param

import Iidy.Aws.ClientReqToken (TokenInfo(..))
import Iidy.Cfn.Context (CfnContext(..), ctxDeriveToken)
import Iidy.Cfn.TemplateLoader (TemplateResult(..), loadCfnTemplate)
import Iidy.Cfn.Types (StackArgs(..), getStackName)

------------------------------------------------------------------------
-- Request builders
------------------------------------------------------------------------

-- | Build a CreateStack request from StackArgs.
-- Returns the request and the token used.
buildCreateStackRequest
  :: CfnContext
  -> StackArgs
  -> Bool           -- ^ use primary token (vs derived)
  -> Maybe FilePath -- ^ argsfile path for template resolution
  -> Text           -- ^ environment name
  -> IO (CF.CreateStack, TokenInfo)
buildCreateStackRequest ctx args usePrimary argsfilePath env = do
  let sName = getStackName args
  token <- if usePrimary
    then pure (cfnPrimaryToken ctx)
    else ctxDeriveToken ctx "create-stack"
  tmplResult <- loadCfnTemplate (saTemplate args) argsfilePath env
  let baseReq = CS.newCreateStack sName
      req = baseReq
        { CS.templateBody = trTemplateBody tmplResult
        , CS.templateURL = trTemplateUrl tmplResult
        , CS.capabilities = mapCapabilities (saCapabilities args)
        , CS.parameters = mapParameters (saParameters args)
        , CS.tags = mapTags (saTags args)
        , CS.roleARN = saServiceRoleArn args
        , CS.clientRequestToken = Just (tiValue token)
        , CS.notificationARNs = saNotificationArns args
        , CS.timeoutInMinutes = fromIntegral <$> saTimeoutInMinutes args
        , CS.disableRollback = saDisableRollback args
        , CS.enableTerminationProtection = saEnableTerminationProtection args
        , CS.onFailure = mapOnFailure (saOnFailure args)
        }
  pure (req, token)

-- | Build an UpdateStack request from StackArgs.
buildUpdateStackRequest
  :: CfnContext
  -> StackArgs
  -> Bool           -- ^ use primary token
  -> Maybe FilePath -- ^ argsfile path
  -> Text           -- ^ environment name
  -> IO (CF.UpdateStack, TokenInfo)
buildUpdateStackRequest ctx args usePrimary argsfilePath env = do
  let sName = getStackName args
  token <- if usePrimary
    then pure (cfnPrimaryToken ctx)
    else ctxDeriveToken ctx "update-stack"
  tmplResult <- loadCfnTemplate (saTemplate args) argsfilePath env
  let baseReq = US.newUpdateStack sName
      req = baseReq
        { US.templateBody = trTemplateBody tmplResult
        , US.templateURL = trTemplateUrl tmplResult
        , US.capabilities = mapCapabilities (saCapabilities args)
        , US.parameters = mapParameters (saParameters args)
        , US.tags = mapTags (saTags args)
        , US.roleARN = saServiceRoleArn args
        , US.clientRequestToken = Just (tiValue token)
        , US.notificationARNs = saNotificationArns args
        }
  pure (req, token)

-- | Build a DeleteStack request.
buildDeleteStackRequest :: CfnContext -> Text -> IO (CF.DeleteStack, TokenInfo)
buildDeleteStackRequest ctx sName = do
  token <- ctxDeriveToken ctx "delete-stack"
  let baseReq = DS.newDeleteStack sName
      req = baseReq
        { DS.clientRequestToken = Just (tiValue token)
        }
  pure (req, token)

-- | Build a CreateChangeSet request.
buildCreateChangeSetRequest
  :: CfnContext
  -> StackArgs
  -> Text     -- ^ changeset name
  -> CF.ChangeSetType  -- ^ CREATE or UPDATE
  -> Maybe FilePath
  -> Text     -- ^ environment
  -> IO (CF.CreateChangeSet, TokenInfo)
buildCreateChangeSetRequest ctx args csName csType argsfilePath env = do
  let sName = getStackName args
  token <- ctxDeriveToken ctx "create-changeset"
  tmplResult <- loadCfnTemplate (saTemplate args) argsfilePath env
  let baseReq = CCS.newCreateChangeSet sName csName
      req = baseReq
        { CCS.templateBody = trTemplateBody tmplResult
        , CCS.templateURL = trTemplateUrl tmplResult
        , CCS.capabilities = mapCapabilities (saCapabilities args)
        , CCS.parameters = mapParameters (saParameters args)
        , CCS.tags = mapTags (saTags args)
        , CCS.roleARN = saServiceRoleArn args
        , CCS.clientToken = Just (tiValue token)
        , CCS.changeSetType = Just csType
        }
  pure (req, token)

------------------------------------------------------------------------
-- Capability mapping
------------------------------------------------------------------------

mapCapability :: Text -> Maybe CF.Capability
mapCapability t = case T.toUpper t of
  "CAPABILITY_IAM"         -> Just CF.Capability_CAPABILITY_IAM
  "CAPABILITY_NAMED_IAM"   -> Just CF.Capability_CAPABILITY_NAMED_IAM
  "CAPABILITY_AUTO_EXPAND" -> Just CF.Capability_CAPABILITY_AUTO_EXPAND
  _                        -> Nothing

-- | Map a list of capability strings to CloudFormation Capability values.
-- Unrecognised strings are silently dropped: schema validation upstream
-- (stack-args.yaml loading) is expected to reject unknown values before
-- this point.  Any string that survives to here and does not match a
-- known capability was already accepted by the user's stack-args file,
-- so dropping it is the safe fallback (AWS would reject the request
-- anyway).
mapCapabilities :: Maybe [Text] -> Maybe [CF.Capability]
mapCapabilities Nothing = Nothing
mapCapabilities (Just caps) =
  let mapped = catMaybes (map mapCapability caps)
  in if null mapped then Nothing else Just mapped

------------------------------------------------------------------------
-- Parameter/tag mapping
------------------------------------------------------------------------

-- | Convert parameter map to CloudFormation Parameter list
mapParameters :: Maybe (Map Text Text) -> Maybe [CF.Parameter]
mapParameters Nothing = Nothing
mapParameters (Just params)
  | Map.null params = Nothing
  | otherwise = Just $ map toParam (Map.toList params)
  where
    toParam :: (Text, Text) -> CF.Parameter
    toParam (k, v) =
      let p = CF.newParameter
      in p { Param.parameterKey = Just k
           , Param.parameterValue = Just v
           }

-- | Convert tag map to CloudFormation Tag list
mapTags :: Maybe (Map Text Text) -> Maybe [CF.Tag]
mapTags Nothing = Nothing
mapTags (Just tags')
  | Map.null tags' = Nothing
  | otherwise = Just $ map toTag (Map.toList tags')
  where
    toTag :: (Text, Text) -> CF.Tag
    toTag (k, v) = CF.newTag k v

------------------------------------------------------------------------
-- OnFailure mapping
------------------------------------------------------------------------

mapOnFailure :: Maybe Text -> Maybe CF.OnFailure
mapOnFailure Nothing = Nothing
mapOnFailure (Just t) = case T.toUpper t of
  "DELETE"     -> Just CF.OnFailure_DELETE
  "ROLLBACK"  -> Just CF.OnFailure_ROLLBACK
  "DO_NOTHING" -> Just CF.OnFailure_DO_NOTHING
  _            -> Nothing
