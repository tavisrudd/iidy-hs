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
  -- * Internal (exported for testing)
  , getStrListValidated
  , getStrMapValidated
  , resolveEnvMaps
  , parseOnFailureText
  , parseCapabilityText
  , validateNoUnknownKeys
  ) where

import Control.Applicative ((<|>))
import Control.Monad (foldM, zipWithM)
import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import qualified Data.List as List
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Text.EditDistance (levenshteinDistance, defaultEditCosts)

import Iidy.Aws.CredentialSource
  ( AwsSettings(..)
  , CredentialDetectionContext(..)
  )
import Iidy.Cfn.Types (CfnOperation, Capability(..), OnFailure(..), StackArgs(..), cfnOperationStr)
import Iidy.Yaml.Engine
  ( preprocessYaml11
  , PreprocessResult(..)
  )
import Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher)
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
      result <- preprocessYaml11 (mkFullDispatcher Nothing) ast baseLocation
      case result of
        Left err ->
          pure $ Left $ "Preprocess error in " <> baseLocation <> ": " <> T.pack (show err)

        Right (PreprocessResult val _manifest) -> do
          let jsonVal = toValue val
          -- Resolve environment maps (can fail if env not found in map)
          case resolveEnvMaps jsonVal environment of
            Left err ->
              pure $ Left $ "Environment map error in " <> baseLocation <> ": " <> err
            Right resolved -> do
              let withEnvTag = ensureEnvironmentTag resolved environment
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
-- Returns Left with an error if an env map doesn't contain the current environment
-- or if the resolved value is not a string (matching Rust behavior).
resolveEnvMaps :: Value -> Text -> Either Text Value
resolveEnvMaps (Object obj) env =
  fmap Object $ foldM (\acc key -> resolveEnvMapField acc key env) obj
    ["Profile", "AssumeRoleARN", "Region"]
resolveEnvMaps v _ = Right v

resolveEnvMapField :: KM.KeyMap Value -> Text -> Text -> Either Text (KM.KeyMap Value)
resolveEnvMapField obj key env =
  case KM.lookup (Key.fromText key) obj of
    Just (Object envMap) ->
      case KM.lookup (Key.fromText env) envMap of
        Just (String s) -> Right $ KM.insert (Key.fromText key) (String s) obj
        Just _nonString -> Left $
          "The " <> key <> " setting in stack-args.yaml must map environments to strings"
        Nothing -> Left $
          "environment '" <> env <> "' not found in " <> key <> " map"
    Just (String _) -> Right obj  -- already a scalar string
    Just Null       -> Right obj  -- null is fine
    Nothing         -> Right obj  -- absent is fine
    Just _          -> Left $
      "The " <> key <> " setting in stack-args.yaml must be a string or an environment map"

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
  let region = fromMaybe "" (awsRegion aws)
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
-- Unknown key validation
------------------------------------------------------------------------

-- | Set of all valid top-level keys in stack-args YAML.
validTopLevelKeys :: Set Text
validTopLevelKeys = Set.fromList
  [ "StackName", "Template", "ApprovedTemplateLocation"
  , "Region", "Profile", "AssumeRoleARN", "ServiceRoleARN", "RoleARN"
  , "Capabilities", "Tags", "Parameters", "NotificationARNs"
  , "TimeoutInMinutes", "OnFailure", "DisableRollback"
  , "EnableTerminationProtection", "StackPolicy", "ResourceTypes"
  , "UsePreviousTemplate", "UsePreviousParameterValues"
  , "CommandsBefore", "$envValues"
  ]

-- | Validate that a KeyMap contains no unknown top-level keys.
-- Returns Left with an error listing unknown keys (with "did you mean?" suggestions)
-- if any are found.
validateNoUnknownKeys :: KM.KeyMap Value -> Either Text ()
validateNoUnknownKeys obj =
  let allKeys = map Key.toText (KM.keys obj)
      unknownKeys = filter (\k -> not (Set.member k validTopLevelKeys)) allKeys
  in case unknownKeys of
       [] -> Right ()
       _  -> Left $ "Unknown keys in stack-args: "
                  <> T.intercalate ", " (map formatUnknownKey unknownKeys)

-- | Format an unknown key with an optional "did you mean?" suggestion.
formatUnknownKey :: Text -> Text
formatUnknownKey key =
  case findSuggestion key of
    Nothing         -> key
    Just suggestion -> key <> " (did you mean " <> suggestion <> "?)"

-- | Find the closest valid key by edit distance.
-- Only suggests if distance <= min(3, len/2 + 1) and distance > 0.
-- Never suggests $envValues (internal key).
findSuggestion :: Text -> Maybe Text
findSuggestion key =
  let keyStr = T.unpack key
      keyLen = T.length key
      maxDist = min 3 (keyLen `div` 2 + 1)
      -- Exclude $envValues from suggestions (internal key)
      suggestableKeys = Set.toList (Set.delete "$envValues" validTopLevelKeys)
      scored = [ (dist, candidate)
               | candidate <- suggestableKeys
               , let dist = levenshteinDistance defaultEditCosts keyStr (T.unpack candidate)
               , dist > 0
               , dist <= maxDist
               ]
  in case scored of
       [] -> Nothing
       _  -> Just $ snd $ List.minimumBy (\a b -> compare (fst a) (fst b)) scored

------------------------------------------------------------------------
-- Value to StackArgs conversion
------------------------------------------------------------------------

-- | Convert a JSON Value (from YAML) to StackArgs
valueToStackArgs :: Value -> Either Text StackArgs
valueToStackArgs (Object obj) = do
  validateNoUnknownKeys obj
  tags            <- getStrMapValidated obj "Tags"
  params          <- getStrMapValidated obj "Parameters"
  caps            <- parseCapabilities obj
  onFail          <- parseOnFailure obj
  notifArns       <- getStrListValidated obj "NotificationARNs"
  resourceTypes   <- getStrListValidated obj "ResourceTypes"
  usePrevParams   <- getStrListValidated obj "UsePreviousParameterValues"
  commandsBefore  <- getStrListValidated obj "CommandsBefore"
  pure StackArgs
    { saStackName                   = getStr obj "StackName"
    , saTemplate                    = getStr obj "Template"
    , saApprovedTemplateLocation    = getStr obj "ApprovedTemplateLocation"
    , saRegion                      = getStr obj "Region"
    , saProfile                     = getStr obj "Profile"
    , saCapabilities                = caps
    , saTags                        = tags
    , saParameters                  = params
    , saNotificationArns            = notifArns
    , saAssumeRoleArn               = getStr obj "AssumeRoleARN"
    , saServiceRoleArn              = getStr obj "ServiceRoleARN"
    , saRoleArn                     = getStr obj "RoleARN"
    , saTimeoutInMinutes            = getInt obj "TimeoutInMinutes"
    , saOnFailure                   = onFail
    , saDisableRollback             = getBool obj "DisableRollback"
    , saEnableTerminationProtection = getBool obj "EnableTerminationProtection"
    , saStackPolicy                 = KM.lookup (Key.fromText "StackPolicy") obj
    , saResourceTypes               = resourceTypes
    , saUsePreviousTemplate         = getBool obj "UsePreviousTemplate"
    , saUsePreviousParameterValues  = usePrevParams
    , saCommandsBefore              = commandsBefore
    }
valueToStackArgs _ = Left "Stack args must be a YAML mapping"

-- | Extract a string list, validating that all elements are strings.
-- Returns an error if any element has a non-string type (matching Rust/serde behavior).
getStrListValidated :: KM.KeyMap Value -> Text -> Either Text (Maybe [Text])
getStrListValidated obj key = case KM.lookup (Key.fromText key) obj of
  Just (Array arr) -> do
    texts <- zipWithM validateElem [0 :: Int ..] (foldr (:) [] arr)
    pure (Just texts)
  Just Null -> Right Nothing
  Nothing   -> Right Nothing
  Just v    -> Left $ "invalid type for " <> key <> ": expected a sequence, got " <> describeType v
  where
    validateElem _ (String t) = Right t
    validateElem i v          = Left $ "invalid type in " <> key <> "[" <> T.pack (show i)
                                     <> "]: expected a string, got " <> describeValue v

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

------------------------------------------------------------------------
-- OnFailure / Capability parsing
------------------------------------------------------------------------

-- | Parse a single OnFailure value from text.
parseOnFailureText :: Text -> Either Text OnFailure
parseOnFailureText t = case T.toUpper t of
  "DO_NOTHING" -> Right DoNothing
  "ROLLBACK"   -> Right Rollback
  "DELETE"     -> Right Delete
  _            -> Left $ "unrecognized OnFailure value: " <> t
                       <> " (expected DO_NOTHING, ROLLBACK, or DELETE)"

-- | Extract and parse OnFailure from a KeyMap.
parseOnFailure :: KM.KeyMap Value -> Either Text (Maybe OnFailure)
parseOnFailure obj = case KM.lookup (Key.fromText "OnFailure") obj of
  Just (String s) -> Just <$> parseOnFailureText s
  Just Null       -> Right Nothing
  Nothing         -> Right Nothing
  Just v          -> Left $ "invalid type for OnFailure: expected a string, got " <> describeType v

-- | Parse a single Capability value from text.
parseCapabilityText :: Text -> Either Text Capability
parseCapabilityText t = case T.toUpper t of
  "CAPABILITY_IAM"         -> Right CapIAM
  "CAPABILITY_NAMED_IAM"   -> Right CapNamedIAM
  "CAPABILITY_AUTO_EXPAND" -> Right CapAutoExpand
  _                        -> Left $ "unrecognized Capability value: " <> t
                                   <> " (expected CAPABILITY_IAM, CAPABILITY_NAMED_IAM, or CAPABILITY_AUTO_EXPAND)"

-- | Extract and parse Capabilities list from a KeyMap.
parseCapabilities :: KM.KeyMap Value -> Either Text (Maybe [Capability])
parseCapabilities obj = case KM.lookup (Key.fromText "Capabilities") obj of
  Just (Array arr) -> do
    caps <- mapM parseOneCapEntry (foldr (:) [] arr)
    pure (Just caps)
  Just Null -> Right Nothing
  Nothing   -> Right Nothing
  Just v    -> Left $ "invalid type for Capabilities: expected a sequence, got " <> describeType v
  where
    parseOneCapEntry :: Value -> Either Text Capability
    parseOneCapEntry (String s) = parseCapabilityText s
    parseOneCapEntry v = Left $ "invalid Capabilities entry: expected a string, got " <> describeType v
