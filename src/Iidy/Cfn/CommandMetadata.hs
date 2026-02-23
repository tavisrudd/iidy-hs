-- | Command metadata and summary construction.
--
-- Builds CommandMetadata from CfnContext, CLI settings, and stack args.
-- Also provides FinalCommandSummary construction.
module Iidy.Cfn.CommandMetadata
  ( constructCommandMetadata
  , createFinalCommandSummary
  -- * Internal (exported for testing)
  , buildCliArguments
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

import qualified Amazonka

import Iidy.Aws.ClientReqToken ()
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
  -> Maybe Text   -- ^ CLI stack name override (only included in CLI Arguments if present)
  -> IO CommandMetadata
constructCommandMetadata ctx awsSettings sa env cliStackNameOverride = do
  -- Get current IAM principal via STS
  (_account, arn) <- getCallerIdentity (cfnEnv ctx)

  -- Get all tokens used (primary is always first)
  allTokens <- ctxGetUsedTokens ctx

  -- Derive tokens = all except primary
  let derivedTokens = case allTokens of
        (_:rest) -> rest
        []       -> []

  -- Build CLI arguments map (only include stack-name if it was a CLI flag)
  let cliArgs = buildCliArguments awsSettings cliStackNameOverride

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

-- | Build the CLI arguments map from settings and CLI stack name override.
-- Only includes values that were explicitly passed as CLI flags.
buildCliArguments :: AwsSettings -> Maybe Text -> Map Text Text
buildCliArguments settings cliStackName =
  Map.fromList $ concat
    [ maybe [] (\p -> [("profile", p)]) (awsProfile settings)
    , maybe [] (\r -> [("region", r)])  (awsRegion settings)
    , maybe [] (\n -> [("stack-name", n)]) cliStackName
    , maybe [] (\r -> [("assume-role-arn", r)]) (awsAssumeRoleArn settings)
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
