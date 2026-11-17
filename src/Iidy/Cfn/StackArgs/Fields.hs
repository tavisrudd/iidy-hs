{- | Conversion of a preprocessed stack-args value to 'StackArgs', with the
field parser and its error texts (matching Rust/serde style).
-}
module Iidy.Cfn.StackArgs.Fields (
    valueToStackArgs,
    getStr,
    getStrListValidated,
    getStrMapValidated,
    getInt,
    parseOnFailureText,
    parseCapabilityText,
) where

import Control.Monad (zipWithM)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (ReaderT, ask, asks, runReaderT)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
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
valueToStackArgs (Object obj) = runReaderT stackArgsFields obj
valueToStackArgs _ = Left "Stack args must be a YAML mapping"

{- | The stack-args fields. Errors are checked in this order and the first
one wins: unknown keys, StackName, Tags, Parameters, Capabilities,
OnFailure, the string lists, TimeoutInMinutes.
-}
stackArgsFields :: FieldParser StackArgs
stackArgsFields = do
    ask >>= lift . validateNoUnknownKeys
    stackName <- lenientField "StackName" asString >>= lift . maybe (Left "StackName is required in stack-args") Right
    tags <- optionalField "Tags" strMap
    params <- optionalField "Parameters" strMap
    caps <- optionalField "Capabilities" capabilities
    onFail <- optionalField "OnFailure" onFailure
    notifArns <- optionalField "NotificationARNs" strList
    resourceTypes <- optionalField "ResourceTypes" strList
    usePrevParams <- optionalField "UsePreviousParameterValues" strList
    commandsBefore <- optionalField "CommandsBefore" strList
    timeoutMins <- optionalField "TimeoutInMinutes" int
    template <- lenientField "Template" asString
    approvedLocation <- lenientField "ApprovedTemplateLocation" asString
    region <- lenientField "Region" asString
    profile <- lenientField "Profile" asString
    assumeRoleArn <- lenientField "AssumeRoleARN" asString
    serviceRoleArn <- lenientField "ServiceRoleARN" asString
    roleArn <- lenientField "RoleARN" asString
    disableRollback <- lenientField "DisableRollback" asBool
    terminationProtection <- lenientField "EnableTerminationProtection" asBool
    stackPolicy <- rawField "StackPolicy"
    usePrevTemplate <- lenientField "UsePreviousTemplate" asBool
    pure
        StackArgs
            { saStackName = stackName
            , saTemplate = template
            , saApprovedTemplateLocation = approvedLocation
            , saRegion = region
            , saProfile = profile
            , saCapabilities = caps
            , saTags = tags
            , saParameters = params
            , saNotificationArns = notifArns
            , saAssumeRoleArn = assumeRoleArn
            , saServiceRoleArn = serviceRoleArn
            , saRoleArn = roleArn
            , saTimeoutInMinutes = timeoutMins
            , saOnFailure = onFail
            , saDisableRollback = disableRollback
            , saEnableTerminationProtection = terminationProtection
            , saStackPolicy = stackPolicy
            , saResourceTypes = resourceTypes
            , saUsePreviousTemplate = usePrevTemplate
            , saUsePreviousParameterValues = usePrevParams
            , saCommandsBefore = commandsBefore
            }

------------------------------------------------------------------------
-- Field parser
------------------------------------------------------------------------

-- | Reads the fields of one stack-args mapping; the first error wins.
type FieldParser = ReaderT (KM.KeyMap Value) (Either Text)

{- | Parses a present, non-null field value; the first argument is the key,
for messages.
-}
type ValueParser a = Text -> Value -> Either Text a

-- | A field's value as written, null included.
rawField :: Text -> FieldParser (Maybe Value)
rawField key = asks (lookupField key)

lookupField :: Text -> KM.KeyMap Value -> Maybe Value
lookupField key = KM.lookup (Key.fromText key)

-- | An optional field: absent or null is 'Nothing', anything else must parse.
optionalField :: Text -> ValueParser a -> FieldParser (Maybe a)
optionalField key parse =
    rawField key >>= \case
        Nothing -> pure Nothing
        Just Null -> pure Nothing
        Just v -> lift (Just <$> parse key v)

-- | A lenient field: a value that does not match reads as absent.
lenientField :: Text -> (Value -> Maybe a) -> FieldParser (Maybe a)
lenientField key match = (>>= match) <$> rawField key

asString :: Value -> Maybe Text
asString = \case
    String s -> Just s
    _other -> Nothing

asBool :: Value -> Maybe Bool
asBool = \case
    Bool b -> Just b
    _nonBool -> Nothing

-- | The error for a field value of the wrong type.
typeError :: Text -> Text -> Value -> Either Text a
typeError key expected v = Left ("invalid type for " <> key <> ": expected " <> expected <> ", got " <> describeType v)

------------------------------------------------------------------------
-- Value parsers
------------------------------------------------------------------------

-- | A sequence of strings (matching Rust/serde behavior).
strList :: ValueParser [Text]
strList key = \case
    Array arr -> zipWithM validateElem [0 :: Int ..] (toList arr)
    v -> typeError key "a sequence" v
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

-- | A mapping of strings to strings (matching Rust/serde behavior).
strMap :: ValueParser (Map Text Text)
strMap key = \case
    Object m -> Map.fromList <$> mapM validatePair (KM.toList m)
    v -> typeError key "a mapping" v
  where
    validatePair (k, String t) = Right (Key.toText k, t)
    validatePair (_, v) = Left ("invalid type: " <> describeValue v <> ", expected a string")

-- | An integer, rejecting other numbers (detected with 'isInteger').
int :: ValueParser Int
int key = \case
    Number n
        | isInteger n -> Right (round n)
        | otherwise ->
            Left $
                "invalid type for "
                    <> key
                    <> ": expected an integer, got float `"
                    <> T.pack (show n)
                    <> "`"
    v -> typeError key "an integer" v

onFailure :: ValueParser OnFailure
onFailure key = \case
    String s -> parseOnFailureText s
    v -> typeError key "a string" v

capabilities :: ValueParser [Capability]
capabilities key = \case
    Array arr -> mapM entry (toList arr)
    v -> typeError key "a sequence" v
  where
    entry (String s) = parseCapabilityText s
    entry v = Left $ "invalid " <> key <> " entry: expected a string, got " <> describeType v

------------------------------------------------------------------------
-- Single-field getters
------------------------------------------------------------------------

-- | A string field; any other value reads as absent.
getStr :: KM.KeyMap Value -> Text -> Maybe Text
getStr obj key = lookupField key obj >>= asString

-- | An optional string-list field (see 'strList').
getStrListValidated :: KM.KeyMap Value -> Text -> Either Text (Maybe [Text])
getStrListValidated obj key = runReaderT (optionalField key strList) obj

-- | An optional string-map field (see 'strMap').
getStrMapValidated :: KM.KeyMap Value -> Text -> Either Text (Maybe (Map Text Text))
getStrMapValidated obj key = runReaderT (optionalField key strMap) obj

-- | An optional integer field (see 'int').
getInt :: KM.KeyMap Value -> Text -> Either Text (Maybe Int)
getInt obj key = runReaderT (optionalField key int) obj

------------------------------------------------------------------------
-- Value descriptions
------------------------------------------------------------------------

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
