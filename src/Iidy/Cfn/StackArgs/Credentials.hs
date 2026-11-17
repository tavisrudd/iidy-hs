{- | The stack-args fields that choose the AWS account and region: reading
them from the raw file before preprocessing (for the import bootstrap,
"Iidy.Cfn.StackArgsBootstrap") and merging them with the command line.
-}
module Iidy.Cfn.StackArgs.Credentials (
    -- * Credential fields
    CredentialField (..),
    credentialFields,
    credentialFieldKey,
    credentialFieldFlag,
    credentialFieldSetting,
    settingsFromFields,

    -- * Raw credential fields (before preprocessing)
    RawField (..),
    readRawField,
    extractRawAwsFromAst,

    -- * Merging with the command line
    mergeAwsSettings,
    mergeSentinel,
    noProfileSentinel,
    noRoleSentinel,
) where

import Control.Applicative ((<|>))
import Data.Text (Text)

import Iidy.Aws.CredentialSource (AwsSettings (..))
import Iidy.Yaml.Ast (YamlAst (..))

------------------------------------------------------------------------
-- Credential fields
------------------------------------------------------------------------

{- | The stack-args fields that choose the AWS account and region. This is
the one list of them: the raw reading, the environment-map resolution, the
settings extraction and the import bootstrap all go through it.
-}
data CredentialField = CredProfile | CredAssumeRoleArn | CredRegion
    deriving stock (Show, Eq, Ord, Enum, Bounded)

-- | Every credential field, in the order errors are checked.
credentialFields :: [CredentialField]
credentialFields = [minBound .. maxBound]

-- | The field's key in a stack-args file.
credentialFieldKey :: CredentialField -> Text
credentialFieldKey = \case
    CredProfile -> "Profile"
    CredAssumeRoleArn -> "AssumeRoleARN"
    CredRegion -> "Region"

-- | The command-line option that sets the field.
credentialFieldFlag :: CredentialField -> Text
credentialFieldFlag = \case
    CredProfile -> "--profile"
    CredAssumeRoleArn -> "--assume-role-arn"
    CredRegion -> "--region"

-- | The field's value in a settings record.
credentialFieldSetting :: CredentialField -> AwsSettings -> Maybe Text
credentialFieldSetting = \case
    CredProfile -> awsProfile
    CredAssumeRoleArn -> awsAssumeRoleArn
    CredRegion -> awsRegion

-- | Build settings from a value per credential field.
settingsFromFields :: (CredentialField -> Maybe Text) -> AwsSettings
settingsFromFields get =
    AwsSettings
        { awsProfile = get CredProfile
        , awsRegion = get CredRegion
        , awsAssumeRoleArn = get CredAssumeRoleArn
        }

------------------------------------------------------------------------
-- Raw credential fields (before preprocessing)
------------------------------------------------------------------------

-- | A credential field as written in the file, before preprocessing.
data RawField
    = RawAbsent
    | -- | A plain string, directly or as the environment's map entry.
      RawLiteral !Text
    | -- | Not known before preprocessing; the text is a clause saying why.
      RawComputed !Text
    deriving stock (Show, Eq)

{- | Read a credential field from the raw top-level mapping. It is literal
only when it is a plain string, or an environment map whose entry for the
environment is a plain string, and each mapping on the way has only
plain-string keys with the looked-up key once. Anything else is not known
before preprocessing (fail closed): a tag, a handlebars template, any other
node, a missing environment entry, a duplicated key (the final value keeps
the last one), or a key that preprocessing could turn into the field's
name (a template or a tag), and a document that is not a plain mapping.
-}
readRawField :: YamlAst -> Text -> CredentialField -> RawField
readRawField (AstMapping pairs _) environment field =
    case plainKeyLookup key pairs of
        KeyNotPlain -> RawComputed ("the stack-args mapping has a key that is not a plain string, which could set " <> key)
        KeyDuplicated -> RawComputed (key <> " appears more than once")
        KeyMissing -> RawAbsent
        KeyFound (AstNull _) -> RawAbsent
        KeyFound (AstMapping envMap _) -> case plainKeyLookup environment envMap of
            KeyNotPlain -> RawComputed ("the environment map for " <> key <> " has a key that is not a plain string")
            KeyDuplicated -> RawComputed ("the environment map for " <> key <> " has the entry " <> environment <> " more than once")
            KeyMissing -> RawComputed (key <> " is an environment map with no entry for environment " <> environment)
            KeyFound entry -> plainOrComputed (key <> " (environment entry '" <> environment <> "')") entry
        KeyFound node -> plainOrComputed key node
  where
    key = credentialFieldKey field
readRawField _ _ field =
    RawComputed (credentialFieldKey field <> " is read from a document that is not a plain mapping")

-- | Classify a raw value node of the named field.
plainOrComputed :: Text -> YamlAst -> RawField
plainOrComputed subject = \case
    AstPlainString t _ -> RawLiteral t
    AstTemplatedString t _ -> computed ("the handlebars template " <> t)
    AstPreprocessingTag{} -> computed "a preprocessing tag"
    AstCloudFormationTag _ _ -> computed "a CloudFormation tag"
    AstUnknownTag _ _ -> computed "a tagged value"
    AstImportedDocument _ _ -> computed "an imported document"
    _other -> computed "a value that is not a string"
  where
    computed what = RawComputed (subject <> " is " <> what)

{- | The literal credential fields of a raw 'YamlAst' (see 'readRawField');
a field that is absent or not known before preprocessing is 'Nothing'.
-}
extractRawAwsFromAst :: YamlAst -> Text -> AwsSettings
extractRawAwsFromAst ast environment = settingsFromFields $ \field ->
    case readRawField ast environment field of
        RawLiteral t -> Just t
        RawAbsent -> Nothing
        RawComputed _ -> Nothing

-- | The outcome of looking a key up in raw mapping pairs.
data KeyLookup
    = KeyMissing
    | KeyFound !YamlAst
    | KeyDuplicated
    | -- | Some key is not a plain string, so it may become any key.
      KeyNotPlain

-- | Look a key up, failing closed on non-plain keys and duplicates.
plainKeyLookup :: Text -> [(YamlAst, YamlAst)] -> KeyLookup
plainKeyLookup name pairs
    | not (all (isPlainKey . fst) pairs) = KeyNotPlain
    | otherwise = case [v | (AstPlainString k _, v) <- pairs, k == name] of
        [] -> KeyMissing
        [v] -> KeyFound v
        _duplicates -> KeyDuplicated
  where
    isPlainKey = \case
        AstPlainString _ _ -> True
        _other -> False

------------------------------------------------------------------------
-- Merging with the command line
------------------------------------------------------------------------

-- | Sentinel value: @--profile=no-profile@ clears any inherited profile.
noProfileSentinel :: Text
noProfileSentinel = "no-profile"

-- | Sentinel value: @--assume-role-arn=no-role@ clears any inherited role.
noRoleSentinel :: Text
noRoleSentinel = "no-role"

{- | Merge AWS settings (CLI overrides argsfile).
Sentinel values "no-profile" and "no-role" clear inherited settings.
-}
mergeAwsSettings :: AwsSettings -> AwsSettings -> AwsSettings
mergeAwsSettings cli argsfile =
    AwsSettings
        { awsProfile = mergeSentinel noProfileSentinel (awsProfile cli) (awsProfile argsfile)
        , awsRegion = awsRegion cli <|> awsRegion argsfile
        , awsAssumeRoleArn = mergeSentinel noRoleSentinel (awsAssumeRoleArn cli) (awsAssumeRoleArn argsfile)
        }

{- | Merge with sentinel support: if CLI value is the sentinel, return 'Nothing'
(clearing any inherited value). Otherwise normal CLI-overrides-argsfile.
-}
mergeSentinel :: Text -> Maybe Text -> Maybe Text -> Maybe Text
mergeSentinel sentinel (Just val) _
    | val == sentinel = Nothing
mergeSentinel _ cli argsfile = cli <|> argsfile
