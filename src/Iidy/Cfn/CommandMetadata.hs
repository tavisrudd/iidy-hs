-- | Command metadata and summary construction.
--
-- Builds CommandMetadata from CfnContext, CLI settings, and stack args.
-- Also provides FinalCommandSummary construction.
module Iidy.Cfn.CommandMetadata
  ( constructCommandMetadata
  , createFinalCommandSummary
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)

import qualified Amazonka

import Iidy.Aws.ClientReqToken (TokenInfo(..))
import Iidy.Aws.Config (credentialDisplayName)
import Iidy.Aws.CredentialSource (AwsSettings(..))
import Iidy.Aws.Sts (getCallerIdentity)
import Iidy.Cfn.Context (CfnContext(..), ctxGetUsedTokens)
import Iidy.Cfn.Types (StackArgs(..))
import Iidy.Output.Types
  ( CommandMetadata(..)
  , FinalCommandSummary(..)
  , CommandSummaryResult(..)
  , OutputData(..)
  )

------------------------------------------------------------------------
-- CommandMetadata construction
------------------------------------------------------------------------

-- | Build CommandMetadata from operation context and settings.
-- Makes a STS GetCallerIdentity call to get the current IAM principal.
constructCommandMetadata
  :: CfnContext
  -> AwsSettings
  -> StackArgs
  -> Text         -- ^ environment name
  -> IO CommandMetadata
constructCommandMetadata ctx awsSettings sa env = do
  -- Get current IAM principal via STS
  (_account, arn) <- getCallerIdentity (cfnEnv ctx)

  -- Get all tokens used (primary is always first)
  allTokens <- ctxGetUsedTokens ctx

  -- Derive tokens = all except primary
  let derivedTokens = case allTokens of
        (_:rest) -> rest
        []       -> []

  -- Build CLI arguments map
  let cliArgs = buildCliArguments awsSettings sa

  -- Get region from env
  let regionText = Amazonka.fromRegion (Amazonka.region (cfnEnv ctx))

  -- Get credential display name
  let credSource = credentialDisplayName (cfnCredentialSources ctx)

  -- IAM service role from stack args
  let serviceRole = saServiceRoleArn sa

  pure CommandMetadata
    { cmEnvironment        = env
    , cmRegion             = regionText
    , cmProfile            = awsProfile awsSettings
    , cmCliArguments       = cliArgs
    , cmIamServiceRole     = serviceRole
    , cmCurrentIamPrincipal = arn
    , cmCredentialSource   = credSource
    , cmVersion            = "0.1.0.0"
    , cmPrimaryToken       = cfnPrimaryToken ctx
    , cmDerivedTokens      = derivedTokens
    }

-- | Build the CLI arguments map from settings and stack args.
buildCliArguments :: AwsSettings -> StackArgs -> Map Text Text
buildCliArguments settings sa =
  Map.fromList $ concat
    [ maybe [] (\p -> [("profile", p)]) (awsProfile settings)
    , maybe [] (\r -> [("region", r)])  (awsRegion settings)
    , maybe [] (\n -> [("stack-name", n)]) (saStackName sa)
    , maybe [] (\r -> [("assume-role-arn", r)]) (awsAssumeRoleArn settings)
    , maybe [] (\r -> [("service-role-arn", r)]) (saServiceRoleArn sa)
    ]

------------------------------------------------------------------------
-- FinalCommandSummary construction
------------------------------------------------------------------------

-- | Create a FinalCommandSummary OutputData.
createFinalCommandSummary :: Bool -> Int -> OutputData
createFinalCommandSummary success elapsed =
  OdFinalCommandSummary FinalCommandSummary
    { fcsResult = if success then SummarySuccess else SummaryFailure
    , fcsElapsedSeconds = elapsed
    }
