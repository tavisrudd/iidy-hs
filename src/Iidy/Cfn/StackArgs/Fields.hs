{- | Conversion of a preprocessed stack-args value to 'StackArgs', with the
typed field getters and their error texts (matching Rust/serde style).
-}
module Iidy.Cfn.StackArgs.Fields (
    valueToStackArgs,
    getStr,
    getStrListValidated,
    getStrMapValidated,
    getInt,
    getBool,
    describeType,
    describeValue,
    parseOnFailure,
    parseOnFailureText,
    parseCapabilities,
    parseCapabilityText,
) where

import Control.Monad (zipWithM)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific (isInteger)
import Data.Text (Text)
import Data.Text qualified as T

import Iidy.Cfn.StackArgs.Validate (validateNoUnknownKeys)
import Iidy.Cfn.Types (Capability (..), OnFailure (..), StackArgs (..))

------------------------------------------------------------------------
-- Value to StackArgs conversion
------------------------------------------------------------------------

-- | Convert a JSON Value (from YAML) to StackArgs
valueToStackArgs :: Value -> Either Text StackArgs
valueToStackArgs (Object obj) = do
    validateNoUnknownKeys obj
    stackName <- case getStr obj "StackName" of
        Just name -> Right name
        Nothing -> Left "StackName is required in stack-args"
    tags <- getStrMapValidated obj "Tags"
    params <- getStrMapValidated obj "Parameters"
    caps <- parseCapabilities obj
    onFail <- parseOnFailure obj
    notifArns <- getStrListValidated obj "NotificationARNs"
    resourceTypes <- getStrListValidated obj "ResourceTypes"
    usePrevParams <- getStrListValidated obj "UsePreviousParameterValues"
    commandsBefore <- getStrListValidated obj "CommandsBefore"
    timeoutMins <- getInt obj "TimeoutInMinutes"
    pure
        StackArgs
            { saStackName = stackName
            , saTemplate = getStr obj "Template"
            , saApprovedTemplateLocation = getStr obj "ApprovedTemplateLocation"
            , saRegion = getStr obj "Region"
            , saProfile = getStr obj "Profile"
            , saCapabilities = caps
            , saTags = tags
            , saParameters = params
            , saNotificationArns = notifArns
            , saAssumeRoleArn = getStr obj "AssumeRoleARN"
            , saServiceRoleArn = getStr obj "ServiceRoleARN"
            , saRoleArn = getStr obj "RoleARN"
            , saTimeoutInMinutes = timeoutMins
            , saOnFailure = onFail
            , saDisableRollback = getBool obj "DisableRollback"
            , saEnableTerminationProtection = getBool obj "EnableTerminationProtection"
            , saStackPolicy = KM.lookup (Key.fromText "StackPolicy") obj
            , saResourceTypes = resourceTypes
            , saUsePreviousTemplate = getBool obj "UsePreviousTemplate"
            , saUsePreviousParameterValues = usePrevParams
            , saCommandsBefore = commandsBefore
            }
valueToStackArgs _ = Left "Stack args must be a YAML mapping"

getStr :: KM.KeyMap Value -> Text -> Maybe Text
getStr obj key = case KM.lookup (Key.fromText key) obj of
    Just (String s) -> Just s
    _other -> Nothing

{- | Extract a string list, validating that all elements are strings.
Returns an error if any element has a non-string type (matching Rust/serde behavior).
-}
getStrListValidated :: KM.KeyMap Value -> Text -> Either Text (Maybe [Text])
getStrListValidated obj key = case KM.lookup (Key.fromText key) obj of
    Just (Array arr) -> do
        texts <- zipWithM validateElem [0 :: Int ..] (foldr (:) [] arr)
        pure (Just texts)
    Just Null -> Right Nothing
    Nothing -> Right Nothing
    Just v -> Left $ "invalid type for " <> key <> ": expected a sequence, got " <> describeType v
  where
    validateElem _ (String t) = Right t
    validateElem i v =
        Left $
            "invalid type in "
                <> key
                <> "["
                <> T.pack (show i)
                <> "]: expected a string, got "
                <> describeValue v

{- | Extract a string map, validating that all values are strings.
Returns an error if any value has a non-string type (matching Rust/serde behavior).
-}
getStrMapValidated :: KM.KeyMap Value -> Text -> Either Text (Maybe (Map Text Text))
getStrMapValidated obj key = case KM.lookup (Key.fromText key) obj of
    Just (Object m) -> do
        pairs <- mapM validatePair (KM.toList m)
        pure (Just (Map.fromList pairs))
    Just Null -> Right Nothing
    Nothing -> Right Nothing
    Just v -> Left ("invalid type for " <> key <> ": expected a mapping, got " <> describeType v)
  where
    validatePair (k, String t) = Right (Key.toText k, t)
    validatePair (_, v) = Left ("invalid type: " <> describeValue v <> ", expected a string")

-- | Describe a JSON value type for error messages (matching Rust/serde style).
describeType :: Value -> Text
describeType (Object _) = "a mapping"
describeType (Array _) = "a sequence"
describeType (String _) = "a string"
describeType (Number _) = "an integer"
describeType (Bool _) = "a boolean"
describeType Null = "null"

-- | Describe a JSON value for error messages (matching Rust/serde style).
describeValue :: Value -> Text
describeValue (Number n) =
    let i = round n :: Integer
     in if fromIntegral i == n
            then "integer `" <> T.pack (show i) <> "`"
            else "float `" <> T.pack (show n) <> "`"
describeValue (Bool b) = "boolean `" <> T.toLower (T.pack (show b)) <> "`"
describeValue (Array _) = "a sequence"
describeValue (Object _) = "a mapping"
describeValue Null = "null"
describeValue (String s) = "string `" <> s <> "`"

{- | Extract an integer value, rejecting non-integer numbers.
Uses Data.Scientific.isInteger to detect floats.
-}
getInt :: KM.KeyMap Value -> Text -> Either Text (Maybe Int)
getInt obj key = case KM.lookup (Key.fromText key) obj of
    Just (Number n)
        | isInteger n -> Right $ Just (round n)
        | otherwise ->
            Left $
                "invalid type for "
                    <> key
                    <> ": expected an integer, got float `"
                    <> T.pack (show n)
                    <> "`"
    Just Null -> Right Nothing
    Nothing -> Right Nothing
    Just v ->
        Left $
            "invalid type for "
                <> key
                <> ": expected an integer, got "
                <> describeType v

getBool :: KM.KeyMap Value -> Text -> Maybe Bool
getBool obj key = case KM.lookup (Key.fromText key) obj of
    Just (Bool b) -> Just b
    _nonBool -> Nothing

------------------------------------------------------------------------
-- OnFailure / Capability parsing
------------------------------------------------------------------------

-- | Parse a single OnFailure value from text.
parseOnFailureText :: Text -> Either Text OnFailure
parseOnFailureText t = case T.toUpper t of
    "DO_NOTHING" -> Right DoNothing
    "ROLLBACK" -> Right Rollback
    "DELETE" -> Right Delete
    _ ->
        Left $
            "unrecognized OnFailure value: "
                <> t
                <> " (expected DO_NOTHING, ROLLBACK, or DELETE)"

-- | Extract and parse OnFailure from a KeyMap.
parseOnFailure :: KM.KeyMap Value -> Either Text (Maybe OnFailure)
parseOnFailure obj = case KM.lookup (Key.fromText "OnFailure") obj of
    Just (String s) -> Just <$> parseOnFailureText s
    Just Null -> Right Nothing
    Nothing -> Right Nothing
    Just v -> Left $ "invalid type for OnFailure: expected a string, got " <> describeType v

-- | Parse a single Capability value from text.
parseCapabilityText :: Text -> Either Text Capability
parseCapabilityText t = case T.toUpper t of
    "CAPABILITY_IAM" -> Right CapIAM
    "CAPABILITY_NAMED_IAM" -> Right CapNamedIAM
    "CAPABILITY_AUTO_EXPAND" -> Right CapAutoExpand
    _ ->
        Left $
            "unrecognized Capability value: "
                <> t
                <> " (expected CAPABILITY_IAM, CAPABILITY_NAMED_IAM, or CAPABILITY_AUTO_EXPAND)"

-- | Extract and parse Capabilities list from a KeyMap.
parseCapabilities :: KM.KeyMap Value -> Either Text (Maybe [Capability])
parseCapabilities obj = case KM.lookup (Key.fromText "Capabilities") obj of
    Just (Array arr) -> do
        caps <- mapM parseOneCapEntry (foldr (:) [] arr)
        pure (Just caps)
    Just Null -> Right Nothing
    Nothing -> Right Nothing
    Just v -> Left $ "invalid type for Capabilities: expected a sequence, got " <> describeType v
  where
    parseOneCapEntry :: Value -> Either Text Capability
    parseOneCapEntry (String s) = parseCapabilityText s
    parseOneCapEntry v = Left $ "invalid Capabilities entry: expected a string, got " <> describeType v
