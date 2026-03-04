-- | CloudFormation API request builder.
--
-- Converts StackArgs + CfnContext into properly formatted CloudFormation
-- API requests with template loading, parameter mapping, and token injection.
module Iidy.Cfn.RequestBuilder
  ( -- * Request building
    buildCreateStackRequest
  , buildUpdateStackRequest
  , buildDeleteStackRequest
  , buildCreateChangeSetRequest
    -- * Helpers
  , toAmazonkaCapability
  , mapCapabilities
  , mapParameters
  , mapTags
  , toAmazonkaOnFailure
  , serializeStackPolicy
  ) where

import Control.Applicative ((<|>))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE

import qualified Data.Aeson as Aeson
import qualified Amazonka.CloudFormation as CF
-- Import operation modules with unique qualifiers for unambiguous field access
import qualified Amazonka.CloudFormation.CreateStack as CS
import qualified Amazonka.CloudFormation.UpdateStack as US
import qualified Amazonka.CloudFormation.DeleteStack as DS
import qualified Amazonka.CloudFormation.CreateChangeSet as CCS
import qualified Amazonka.CloudFormation.Types.Parameter as Param

import Iidy.Aws.ClientReqToken (TokenInfo(..))
import Iidy.Cfn.Context (CfnContext(..), ctxDeriveToken)
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig(..))
import Iidy.Yaml.Imports.Types (RemoteImports(..))
import Iidy.Cfn.TemplateLoader (TemplateResult(..), loadCfnTemplate)
import Iidy.Cfn.Types (Capability(..), OnFailure(..), StackArgs(..))

------------------------------------------------------------------------
-- Request builders
------------------------------------------------------------------------

-- | Build a CreateStack request from StackArgs.
-- Returns the request and the token used, or a descriptive error.
buildCreateStackRequest
  :: CfnContext
  -> StackArgs
  -> Bool           -- ^ use primary token (vs derived)
  -> Maybe FilePath -- ^ argsfile path for template resolution
  -> Text           -- ^ environment name
  -> RemoteImports  -- ^ whether HTTP/S3 imports are allowed
  -> IO (Either Text (CF.CreateStack, TokenInfo))
buildCreateStackRequest ctx args usePrimary argsfilePath env remoteImports = do
  let sName = saStackName args
      importCfg = ImportConfig { icAwsEnv = Just (cfnEnv ctx), icRemoteImports = remoteImports }
  token <- if usePrimary
    then pure (cfnPrimaryToken ctx)
    else ctxDeriveToken ctx "create-stack"
  tmplEither <- loadCfnTemplate (saTemplate args) argsfilePath env importCfg
  case tmplEither of
    Left err -> pure (Left err)
    Right tmplResult -> do
      let baseReq = CS.newCreateStack sName
          req = baseReq
            { CS.templateBody = trTemplateBody tmplResult
            , CS.templateURL = trTemplateUrl tmplResult
            , CS.capabilities = mapCapabilities (saCapabilities args)
            , CS.parameters = mapParameters (saParameters args)
            , CS.tags = mapTags (saTags args)
            , CS.roleARN = saServiceRoleArn args <|> saRoleArn args
            , CS.clientRequestToken = Just (tiValue token)
            , CS.notificationARNs = saNotificationArns args
            , CS.timeoutInMinutes = fromIntegral <$> saTimeoutInMinutes args
            , CS.disableRollback = saDisableRollback args
            , CS.enableTerminationProtection = saEnableTerminationProtection args
            , CS.onFailure = fmap toAmazonkaOnFailure (saOnFailure args)
            , CS.stackPolicyBody = serializeStackPolicy (saStackPolicy args)
            , CS.resourceTypes = saResourceTypes args
            }
      pure (Right (req, token))

-- | Build an UpdateStack request from StackArgs.
buildUpdateStackRequest
  :: CfnContext
  -> StackArgs
  -> Bool           -- ^ use primary token
  -> Maybe FilePath -- ^ argsfile path
  -> Text           -- ^ environment name
  -> RemoteImports  -- ^ whether HTTP/S3 imports are allowed
  -> IO (Either Text (CF.UpdateStack, TokenInfo))
buildUpdateStackRequest ctx args usePrimary argsfilePath env remoteImports = do
  let sName = saStackName args
      importCfg = ImportConfig { icAwsEnv = Just (cfnEnv ctx), icRemoteImports = remoteImports }
  token <- if usePrimary
    then pure (cfnPrimaryToken ctx)
    else ctxDeriveToken ctx "update-stack"
  tmplEither <- loadCfnTemplate (saTemplate args) argsfilePath env importCfg
  case tmplEither of
    Left err -> pure (Left err)
    Right tmplResult -> do
      let baseReq = US.newUpdateStack sName
          req = baseReq
            { US.templateBody = trTemplateBody tmplResult
            , US.templateURL = trTemplateUrl tmplResult
            , US.capabilities = mapCapabilities (saCapabilities args)
            , US.parameters = mapParameters (saParameters args)
            , US.tags = mapTags (saTags args)
            , US.roleARN = saServiceRoleArn args <|> saRoleArn args
            , US.clientRequestToken = Just (tiValue token)
            , US.notificationARNs = saNotificationArns args
            , US.stackPolicyBody = serializeStackPolicy (saStackPolicy args)
            , US.resourceTypes = saResourceTypes args
            }
      pure (Right (req, token))

-- | Build a DeleteStack request.
-- Uses the primary token (not derived), matching Rust behavior.
buildDeleteStackRequest :: CfnContext -> Text -> IO (CF.DeleteStack, TokenInfo)
buildDeleteStackRequest ctx sName = do
  let token = cfnPrimaryToken ctx
      baseReq = DS.newDeleteStack sName
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
  -> RemoteImports  -- ^ whether HTTP/S3 imports are allowed
  -> IO (Either Text (CF.CreateChangeSet, TokenInfo))
buildCreateChangeSetRequest ctx args csName csType argsfilePath env remoteImports = do
  let sName = saStackName args
      importCfg = ImportConfig { icAwsEnv = Just (cfnEnv ctx), icRemoteImports = remoteImports }
  token <- ctxDeriveToken ctx "create-changeset"
  tmplEither <- loadCfnTemplate (saTemplate args) argsfilePath env importCfg
  case tmplEither of
    Left err -> pure (Left err)
    Right tmplResult -> do
      let baseReq = CCS.newCreateChangeSet sName csName
          req = baseReq
            { CCS.templateBody = trTemplateBody tmplResult
            , CCS.templateURL = trTemplateUrl tmplResult
            , CCS.capabilities = mapCapabilities (saCapabilities args)
            , CCS.parameters = mapParameters (saParameters args)
            , CCS.tags = mapTags (saTags args)
            , CCS.roleARN = saServiceRoleArn args <|> saRoleArn args
            , CCS.clientToken = Just (tiValue token)
            , CCS.changeSetType = Just csType
            , CCS.notificationARNs = saNotificationArns args
            , CCS.resourceTypes = saResourceTypes args
            }
      pure (Right (req, token))

------------------------------------------------------------------------
-- Capability mapping
------------------------------------------------------------------------

-- | Convert a Capability ADT value to the corresponding amazonka type.
toAmazonkaCapability :: Capability -> CF.Capability
toAmazonkaCapability CapIAM        = CF.Capability_CAPABILITY_IAM
toAmazonkaCapability CapNamedIAM   = CF.Capability_CAPABILITY_NAMED_IAM
toAmazonkaCapability CapAutoExpand = CF.Capability_CAPABILITY_AUTO_EXPAND

-- | Map a list of Capability values to CloudFormation Capability values.
mapCapabilities :: Maybe [Capability] -> Maybe [CF.Capability]
mapCapabilities Nothing     = Nothing
mapCapabilities (Just [])   = Nothing
mapCapabilities (Just caps) = Just (map toAmazonkaCapability caps)

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

-- | Convert an OnFailure ADT value to the corresponding amazonka type.
toAmazonkaOnFailure :: OnFailure -> CF.OnFailure
toAmazonkaOnFailure DoNothing = CF.OnFailure_DO_NOTHING
toAmazonkaOnFailure Rollback  = CF.OnFailure_ROLLBACK
toAmazonkaOnFailure Delete    = CF.OnFailure_DELETE

------------------------------------------------------------------------
-- Stack policy serialization
------------------------------------------------------------------------

-- | Serialize a stack policy JSON value to Text for the AWS API.
-- The AWS CloudFormation API accepts stack policy as a JSON string.
serializeStackPolicy :: Maybe Aeson.Value -> Maybe Text
serializeStackPolicy Nothing = Nothing
serializeStackPolicy (Just v) = Just (TL.toStrict (TLE.decodeUtf8 (Aeson.encode v)))
