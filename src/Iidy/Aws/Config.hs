-- | AWS configuration setup and credential loading.
--
-- Creates amazonka Env with proper region, profile, and assume-role configuration.
-- Integrates with credential source detection for provenance tracking.
module Iidy.Aws.Config
  ( -- * Environment setup
    createAwsEnv
  , createAwsEnvFromSettings
    -- * Region handling
  , resolveRegion
  , textToRegion
    -- * Credential detection
  , detectCredentialSources
  , credentialDisplayName
    -- * Re-exports
  , Amazonka.Env
  , Amazonka.Region
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import System.Environment (lookupEnv)

import qualified Amazonka

import Iidy.Aws.CredentialSource

------------------------------------------------------------------------
-- Environment setup
------------------------------------------------------------------------

-- | Create an AWS Env from merged settings and detection context.
-- Returns the env and the detected credential source stack for provenance.
createAwsEnv :: CredentialDetectionContext -> AwsSettings -> IO (Amazonka.Env, CredentialSourceStack)
createAwsEnv detectionCtx settings = do
  -- Detect credential sources for provenance tracking
  credStack <- detectCredentialSources detectionCtx
  -- Create base env with default credential chain
  env <- Amazonka.newEnv Amazonka.discover
  -- Apply region override if specified
  region <- resolveRegion (awsRegion settings)
  let env' = env { Amazonka.region = region }
  pure (env', credStack)

-- | Create AWS Env from simple settings (no detection context).
-- Uses default detection context with CLI settings only.
createAwsEnvFromSettings :: AwsSettings -> IO (Amazonka.Env, CredentialSourceStack)
createAwsEnvFromSettings settings =
  let ctx = CredentialDetectionContext
        { cdcCliProfile = awsProfile settings
        , cdcStackArgsProfile = Nothing
        , cdcCliAssumeRoleArn = awsAssumeRoleArn settings
        , cdcStackArgsAssumeRoleArn = Nothing
        }
  in createAwsEnv ctx settings

------------------------------------------------------------------------
-- Region handling
------------------------------------------------------------------------

-- | Resolve region from settings or environment, defaulting to us-east-1.
-- Priority: explicit setting > AWS_REGION > AWS_DEFAULT_REGION > us-east-1
resolveRegion :: Maybe Text -> IO Amazonka.Region
resolveRegion (Just r) = pure (textToRegion r)
resolveRegion Nothing = do
  envRegion <- lookupEnv "AWS_REGION"
  case envRegion of
    Just r  -> pure (textToRegion (T.pack r))
    Nothing -> do
      envRegion2 <- lookupEnv "AWS_DEFAULT_REGION"
      case envRegion2 of
        Just r  -> pure (textToRegion (T.pack r))
        Nothing -> pure Amazonka.NorthVirginia

-- | Convert text region name to amazonka Region
textToRegion :: Text -> Amazonka.Region
textToRegion = Amazonka.Region'

------------------------------------------------------------------------
-- Credential detection
------------------------------------------------------------------------

-- | Detect credential sources from environment for provenance tracking.
-- This does NOT configure credentials (amazonka.discover does that),
-- it only determines which source is being used for display purposes.
detectCredentialSources :: CredentialDetectionContext -> IO CredentialSourceStack
detectCredentialSources ctx = do
  -- Check environment variables in priority order
  hasAccessKey <- hasEnv "AWS_ACCESS_KEY_ID"
  hasSecretKey <- hasEnv "AWS_SECRET_ACCESS_KEY"
  hasSessionToken <- hasEnv "AWS_SESSION_TOKEN"
  hasWebIdentity <- hasEnv "AWS_WEB_IDENTITY_TOKEN_FILE"
  hasContainerEcs <- hasEnv "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"
  hasContainerGeneric <- hasEnv "AWS_CONTAINER_CREDENTIALS_FULL_URI"
  envProfile <- lookupEnvText "AWS_PROFILE"

  let sources = concat
        -- 1. Static/temporary env var credentials (highest priority)
        [ if hasAccessKey && hasSecretKey && hasSessionToken
          then [EnvironmentVariablesTemporary]
          else if hasAccessKey && hasSecretKey
          then [EnvironmentVariablesStatic]
          else []
        -- 2. Web identity token
        , [WebIdentityToken | hasWebIdentity]
        -- 3. Container credentials
        , [ContainerCredentialsEcs | hasContainerEcs]
        , [ContainerCredentialsGeneric | hasContainerGeneric]
        -- 4. Profile (always present as fallback)
        , [ProfileCredential (determineProfile ctx envProfile)]
        ]

      -- Apply assume role wrapper if specified
      withAssumeRole = case (cdcCliAssumeRoleArn ctx, cdcStackArgsAssumeRoleArn ctx) of
        (Just arn, _) -> case sources of
          (s:rest) -> AssumeRoleCredential (AssumeRoleInfo s arn AssumeRoleCliFlag) : rest
          [] -> [AssumeRoleCredential (AssumeRoleInfo UnknownCredentialSource arn AssumeRoleCliFlag)]
        (_, Just arn) -> case sources of
          (s:rest) -> AssumeRoleCredential (AssumeRoleInfo s arn AssumeRoleStackArgs) : rest
          [] -> [AssumeRoleCredential (AssumeRoleInfo UnknownCredentialSource arn AssumeRoleStackArgs)]
        _ -> sources

  pure (CredentialSourceStack withAssumeRole)

-- | Determine profile info from detection context
determineProfile :: CredentialDetectionContext -> Maybe Text -> ProfileInfo
determineProfile ctx envProfile =
  let (name, source) = case (cdcCliProfile ctx, cdcStackArgsProfile ctx, envProfile) of
        (Just p, _, _) -> (p, ProfileCliFlag)
        (_, Just p, _) -> (p, ProfileStackArgs)
        (_, _, Just p) -> (p, ProfileAwsProfileEnvVar)
        _              -> ("default", ProfileDefault)
  in ProfileInfo
    { piName = name
    , piSource = source
    , piProfileRoleArn = Nothing  -- Would need to parse ~/.aws/config
    }

------------------------------------------------------------------------
-- Display
------------------------------------------------------------------------

-- | Get a human-readable display name for the credential source stack
credentialDisplayName :: CredentialSourceStack -> Text
credentialDisplayName (CredentialSourceStack []) = "unknown"
credentialDisplayName (CredentialSourceStack (active:overridden)) =
  let activeName = sourceDisplayName active
      overriddenNames = map sourceDisplayName overridden
  in if null overriddenNames
     then activeName
     else activeName <> " (overriding " <> T.intercalate " and " overriddenNames <> ")"

-- | Display name for a single credential source
sourceDisplayName :: CredentialSource -> Text
sourceDisplayName = \case
  EnvironmentVariablesStatic -> "environment variables (AWS_ACCESS_KEY_ID)"
  EnvironmentVariablesTemporary -> "environment variables (AWS_ACCESS_KEY_ID + AWS_SESSION_TOKEN)"
  ProfileCredential pinfo ->
    "profile '" <> piName pinfo <> "' (" <> profileSourceName (piSource pinfo) <> ")"
  AssumeRoleCredential ari ->
    "assume-role " <> ariRoleArn ari <> " via " <> sourceDisplayName (ariBaseSource ari)
  ContainerCredentialsEcs -> "ECS container credentials"
  ContainerCredentialsGeneric -> "container credentials"
  WebIdentityToken -> "web identity token"
  InstanceMetadata -> "EC2 instance metadata"
  UnknownCredentialSource -> "unknown"

-- | Display name for profile source
profileSourceName :: ProfileSource -> Text
profileSourceName = \case
  ProfileCliFlag -> "CLI flag"
  ProfileStackArgs -> "stack-args"
  ProfileAwsProfileEnvVar -> "AWS_PROFILE"
  ProfileDefault -> "default"

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

hasEnv :: String -> IO Bool
hasEnv name = do
  val <- lookupEnv name
  pure $ case val of
    Just v  -> not (null v)
    Nothing -> False

lookupEnvText :: String -> IO (Maybe Text)
lookupEnvText name = do
  val <- lookupEnv name
  pure (T.pack <$> val)
