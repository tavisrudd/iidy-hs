-- | Stack args loader: reads and preprocesses argsfile YAML into StackArgs.
--
-- Mirrors Rust's cfn::stack_args::load_stack_args:
--   1. Read argsfile YAML
--   2. Preprocess with YAML engine (resolves custom tags, imports)
--   3. Resolve environment maps for Profile/Region/AssumeRoleARN
--   4. Inject $envValues
--   5. Deserialize to StackArgs
--   6. Merge CLI AWS settings with argsfile settings
module Iidy.Cfn.StackArgsLoader
  ( loadStackArgs
  , LoadedStackArgs(..)
  ) where

import Control.Applicative ((<|>))
import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Iidy.Aws.CredentialSource
  ( AwsSettings(..)
  , CredentialDetectionContext(..)
  )
import Iidy.Cfn.Types (CfnOperation, StackArgs(..), cfnOperationStr)
import Iidy.Yaml.Engine
  ( preprocessYaml11
  , PreprocessResult(..)
  )
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.OValue (toValue)
import Iidy.Yaml.Parser (parseYaml, ParseError(..))

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

-- | Result of loading stack args, including merged AWS settings
data LoadedStackArgs = LoadedStackArgs
  { lsaStackArgs     :: !StackArgs
  , lsaMergedAws     :: !AwsSettings
  , lsaDetectionCtx  :: !CredentialDetectionContext
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- | Load and preprocess an argsfile into StackArgs.
-- Uses YAML 1.1 spec (CloudFormation compatibility).
-- Resolves environment maps, injects $envValues, deserializes.
loadStackArgs
  :: FilePath        -- ^ argsfile path
  -> Text            -- ^ environment name
  -> CfnOperation    -- ^ operation being performed
  -> AwsSettings     -- ^ CLI-provided AWS settings
  -> IO (Either Text LoadedStackArgs)
loadStackArgs argsfile environment operation cliAws = do
  content <- BL.readFile argsfile
  let baseLocation = T.pack argsfile

  -- Parse YAML
  case parseYaml content baseLocation of
    Left (ParseError _pos msg) ->
      pure $ Left $ "Parse error in " <> baseLocation <> ": " <> msg

    Right ast -> do
      -- Preprocess (YAML 1.1 for CFN compatibility)
      result <- preprocessYaml11 loadFileImport ast baseLocation
      case result of
        Left err ->
          pure $ Left $ "Preprocess error in " <> baseLocation <> ": " <> T.pack (show err)

        Right (PreprocessResult val _manifest) -> do
          let jsonVal = toValue val
          -- Resolve environment maps and inject $envValues
          let resolved = resolveEnvMaps jsonVal environment
              withEnvTag = ensureEnvironmentTag resolved environment
              withEnvValues = injectEnvValues withEnvTag environment operation cliAws

          -- Extract AWS settings from argsfile
          let argsfileAws = extractAwsSettings withEnvValues
              mergedAws = mergeAwsSettings cliAws argsfileAws
              detectionCtx = CredentialDetectionContext
                { cdcCliProfile = awsProfile cliAws
                , cdcStackArgsProfile = awsProfile argsfileAws
                , cdcCliAssumeRoleArn = awsAssumeRoleArn cliAws
                , cdcStackArgsAssumeRoleArn = awsAssumeRoleArn argsfileAws
                }

          -- Deserialize to StackArgs
          case valueToStackArgs withEnvValues of
            Left err ->
              pure $ Left $ "Failed to parse stack args from " <> baseLocation <> ": " <> err
            Right stackArgs ->
              pure $ Right $ LoadedStackArgs
                { lsaStackArgs = stackArgs
                , lsaMergedAws = mergedAws
                , lsaDetectionCtx = detectionCtx
                }

------------------------------------------------------------------------
-- Environment map resolution
------------------------------------------------------------------------

-- | Resolve environment maps for Profile, Region, AssumeRoleARN.
-- These fields can be either a string or a mapping of environment -> string.
resolveEnvMaps :: Value -> Text -> Value
resolveEnvMaps (Object obj) env = Object $
  foldr (\key acc -> resolveEnvMapField acc key env) obj
    ["Profile", "AssumeRoleARN", "Region"]
resolveEnvMaps v _ = v

resolveEnvMapField :: KM.KeyMap Value -> Text -> Text -> KM.KeyMap Value
resolveEnvMapField obj key env =
  case KM.lookup (Key.fromText key) obj of
    Just (Object envMap) ->
      case KM.lookup (Key.fromText env) envMap of
        Just val -> KM.insert (Key.fromText key) val obj
        Nothing  -> obj  -- env not found, leave as-is
    _ -> obj  -- already a scalar or absent

------------------------------------------------------------------------
-- Environment tag
------------------------------------------------------------------------

-- | Ensure Tags.environment is set
ensureEnvironmentTag :: Value -> Text -> Value
ensureEnvironmentTag (Object obj) env =
  let tagsKey = Key.fromText "Tags"
      envKey = Key.fromText "environment"
      tags = case KM.lookup tagsKey obj of
               Just (Object t) -> t
               _               -> KM.empty
      tags' = case KM.lookup envKey tags of
                Just _  -> tags  -- already set
                Nothing -> KM.insert envKey (String env) tags
  in Object (KM.insert tagsKey (Object tags') obj)
ensureEnvironmentTag v _ = v

------------------------------------------------------------------------
-- $envValues injection
------------------------------------------------------------------------

-- | Inject $envValues into the argsfile data
injectEnvValues :: Value -> Text -> CfnOperation -> AwsSettings -> Value
injectEnvValues (Object obj) env operation aws =
  let envValuesKey = Key.fromText "$envValues"
      envValues = buildEnvValues env operation aws
      existing = case KM.lookup envValuesKey obj of
                   Just (Object m) -> m
                   _               -> KM.empty
      -- New values take precedence over existing
      merged = case envValues of
                 Object newMap -> Object (KM.union newMap existing)
                 _             -> envValues
  in Object (KM.insert envValuesKey merged obj)
injectEnvValues v _ _ _ = v

-- | Build $envValues matching iidy-js structure
buildEnvValues :: Text -> CfnOperation -> AwsSettings -> Value
buildEnvValues env operation aws =
  let region = fromMaybe "us-east-1" (awsRegion aws)
      iidyBase = KM.fromList
        [ (Key.fromText "command", String (cfnOperationStr operation))
        , (Key.fromText "environment", String env)
        , (Key.fromText "region", String region)
        ]
      iidyNs = case awsProfile aws of
        Just p  -> Object (KM.insert (Key.fromText "profile") (String p) iidyBase)
        Nothing -> Object iidyBase
  in Object $ KM.fromList
    [ (Key.fromText "region", String region)
    , (Key.fromText "environment", String env)
    , (Key.fromText "iidy", iidyNs)
    ]

------------------------------------------------------------------------
-- AWS settings extraction and merging
------------------------------------------------------------------------

-- | Extract AWS settings from preprocessed argsfile Value
extractAwsSettings :: Value -> AwsSettings
extractAwsSettings (Object obj) = AwsSettings
  { awsProfile = getStr obj "Profile"
  , awsRegion = getStr obj "Region"
  , awsAssumeRoleArn = getStr obj "AssumeRoleARN"
  }
extractAwsSettings _ = AwsSettings Nothing Nothing Nothing

getStr :: KM.KeyMap Value -> Text -> Maybe Text
getStr obj key = case KM.lookup (Key.fromText key) obj of
  Just (String s) -> Just s
  _               -> Nothing

-- | Merge AWS settings (CLI overrides argsfile)
mergeAwsSettings :: AwsSettings -> AwsSettings -> AwsSettings
mergeAwsSettings cli argsfile = AwsSettings
  { awsProfile = awsProfile cli <|> awsProfile argsfile
  , awsRegion = awsRegion cli <|> awsRegion argsfile
  , awsAssumeRoleArn = awsAssumeRoleArn cli <|> awsAssumeRoleArn argsfile
  }

------------------------------------------------------------------------
-- Value to StackArgs conversion
------------------------------------------------------------------------

-- | Convert a JSON Value (from YAML) to StackArgs
valueToStackArgs :: Value -> Either Text StackArgs
valueToStackArgs (Object obj) = do
  tags   <- getStrMapValidated obj "Tags"
  params <- getStrMapValidated obj "Parameters"
  pure StackArgs
    { saStackName                   = getStr obj "StackName"
    , saTemplate                    = getStr obj "Template"
    , saApprovedTemplateLocation    = getStr obj "ApprovedTemplateLocation"
    , saRegion                      = getStr obj "Region"
    , saProfile                     = getStr obj "Profile"
    , saCapabilities                = getStrList obj "Capabilities"
    , saTags                        = tags
    , saParameters                  = params
    , saNotificationArns            = getStrList obj "NotificationARNs"
    , saAssumeRoleArn               = getStr obj "AssumeRoleARN"
    , saServiceRoleArn              = getStr obj "ServiceRoleARN"
    , saRoleArn                     = getStr obj "RoleARN"
    , saTimeoutInMinutes            = getInt obj "TimeoutInMinutes"
    , saOnFailure                   = getStr obj "OnFailure"
    , saDisableRollback             = getBool obj "DisableRollback"
    , saEnableTerminationProtection = getBool obj "EnableTerminationProtection"
    , saStackPolicy                 = KM.lookup (Key.fromText "StackPolicy") obj
    , saResourceTypes               = getStrList obj "ResourceTypes"
    , saUsePreviousTemplate         = getBool obj "UsePreviousTemplate"
    , saUsePreviousParameterValues  = getStrList obj "UsePreviousParameterValues"
    , saCommandsBefore              = getStrList obj "CommandsBefore"
    }
valueToStackArgs _ = Left "Stack args must be a YAML mapping"

getStrList :: KM.KeyMap Value -> Text -> Maybe [Text]
getStrList obj key = case KM.lookup (Key.fromText key) obj of
  Just (Array arr) -> Just [t | String t <- foldr (:) [] arr]
  _                -> Nothing

-- | Extract a string map, validating that all values are strings.
-- Returns an error if any value has a non-string type (matching Rust/serde behavior).
getStrMapValidated :: KM.KeyMap Value -> Text -> Either Text (Maybe (Map Text Text))
getStrMapValidated obj key = case KM.lookup (Key.fromText key) obj of
  Just (Object m) -> do
    pairs <- mapM validatePair (KM.toList m)
    pure (Just (Map.fromList pairs))
  Just Null -> Right Nothing
  Nothing   -> Right Nothing
  Just v    -> Left ("invalid type for " <> key <> ": expected a mapping, got " <> describeType v)
  where
    validatePair (k, String t) = Right (Key.toText k, t)
    validatePair (_, v)        = Left ("invalid type: " <> describeValue v <> ", expected a string")

-- | Describe a JSON value type for error messages (matching Rust/serde style).
describeType :: Value -> Text
describeType (Object _) = "a mapping"
describeType (Array _)  = "a sequence"
describeType (String _) = "a string"
describeType (Number _) = "an integer"
describeType (Bool _)   = "a boolean"
describeType Null       = "null"

-- | Describe a JSON value for error messages (matching Rust/serde style).
describeValue :: Value -> Text
describeValue (Number n) =
  let i = round n :: Integer
  in if fromIntegral i == n
     then "integer `" <> T.pack (show i) <> "`"
     else "float `" <> T.pack (show n) <> "`"
describeValue (Bool b)   = "boolean `" <> T.toLower (T.pack (show b)) <> "`"
describeValue (Array _)  = "a sequence"
describeValue (Object _) = "a mapping"
describeValue Null       = "null"
describeValue (String s) = "string `" <> s <> "`"

getInt :: KM.KeyMap Value -> Text -> Maybe Int
getInt obj key = case KM.lookup (Key.fromText key) obj of
  Just (Number n) -> Just (round n)
  _               -> Nothing

getBool :: KM.KeyMap Value -> Text -> Maybe Bool
getBool obj key = case KM.lookup (Key.fromText key) obj of
  Just (Bool b) -> Just b
  _             -> Nothing
