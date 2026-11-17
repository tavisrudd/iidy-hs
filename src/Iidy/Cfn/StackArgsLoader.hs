{- | Stack args loader: reads and preprocesses argsfile YAML into StackArgs.

Mirrors Rust's cfn::stack_args::load_stack_args:
  1. Read argsfile YAML
  2. Preprocess with YAML engine (resolves custom tags, imports)
  3. Resolve environment maps for Profile/Region/AssumeRoleARN
  4. Inject $envValues
  5. Deserialize to StackArgs
  6. Merge CLI AWS settings with argsfile settings
-}
module Iidy.Cfn.StackArgsLoader (
    loadStackArgs,
    loadStackArgsWith,
    LoadedStackArgs (..),

    -- * Credential fields
    CredentialField (..),
    credentialFields,
    credentialFieldKey,
    credentialFieldFlag,
    credentialFieldSetting,

    -- * AWS settings bootstrap (for pre-import credential creation)
    RawField (..),
    readRawField,
    mergeAwsSettings,

    -- * Internal (exported for testing)
    extractRawAwsFromAst,
    getStrListValidated,
    getStrMapValidated,
    getInt,
    resolveEnvMaps,
    parseOnFailureText,
    parseCapabilityText,
    validateNoUnknownKeys,
    mergeSentinel,
    noProfileSentinel,
    noRoleSentinel,
) where

import Control.Monad (foldM)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Amazonka qualified
import Iidy.Aws.CredentialSource (
    AwsSettings (..),
    CredentialDetectionContext (..),
 )
import Iidy.Cfn.StackArgs.Credentials (
    CredentialField (..),
    RawField (..),
    credentialFieldFlag,
    credentialFieldKey,
    credentialFieldSetting,
    credentialFields,
    extractRawAwsFromAst,
    mergeAwsSettings,
    mergeSentinel,
    noProfileSentinel,
    noRoleSentinel,
    readRawField,
    settingsFromFields,
 )
import Iidy.Cfn.StackArgs.Fields (
    getInt,
    getStr,
    getStrListValidated,
    getStrMapValidated,
    parseCapabilityText,
    parseOnFailureText,
    valueToStackArgs,
 )
import Iidy.Cfn.StackArgs.Validate (validateNoUnknownKeys)
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..), cfnOperationStr)
import Iidy.Yaml.Ast (YamlAst)
import Iidy.Yaml.Engine (
    LoadImportFn,
    PreprocessResult (..),
 )
import Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher, mkImportConfig, preprocessWithPolicy)
import Iidy.Yaml.Imports.Types (ImportPolicy)
import Iidy.Yaml.OValue (toValue)
import Iidy.Yaml.Parser (ParseError (..), parseYaml)

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

-- | Result of loading stack args, including merged AWS settings
data LoadedStackArgs = LoadedStackArgs
    { lsaStackArgs :: !StackArgs
    , lsaMergedAws :: !AwsSettings
    , lsaDetectionCtx :: !CredentialDetectionContext
    }
    deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

{- | Load and preprocess an argsfile into StackArgs.
Uses YAML 1.1 spec (CloudFormation compatibility).
Resolves environment maps, injects $envValues, deserializes.

The optional 'Amazonka.Env' enables AWS import types (ssm:, cfn:,
ssm-path:) during preprocessing.  Pass 'Nothing' for the first pass
(before AWS credentials are available) and @'Just' env@ for the
second pass once credentials have been established.
-}
loadStackArgs ::
    -- | argsfile path
    FilePath ->
    -- | environment name
    Text ->
    -- | operation being performed
    CfnOperation ->
    -- | CLI-provided AWS settings
    AwsSettings ->
    -- | import policy (remote imports, trusted sources)
    ImportPolicy ->
    -- | optional AWS env for imports
    Maybe Amazonka.Env ->
    IO (Either Text LoadedStackArgs)
loadStackArgs argsfile environment operation cliAws policy mAwsEnv =
    loadStackArgsWith
        policy
        (\_ast -> pure (mkFullDispatcher (mkImportConfig mAwsEnv policy)))
        argsfile
        environment
        operation
        cliAws

{- | Like 'loadStackArgs', with the import loader built from the parsed file
(see "Iidy.Cfn.StackArgsBootstrap"); the loader must wrap
'mkFullDispatcher' built from the given policy.
-}
loadStackArgsWith ::
    -- | import policy the loader applies
    ImportPolicy ->
    -- | import loader for the parsed argsfile
    (YamlAst -> IO LoadImportFn) ->
    -- | argsfile path
    FilePath ->
    -- | environment name
    Text ->
    -- | operation being performed
    CfnOperation ->
    -- | CLI-provided AWS settings
    AwsSettings ->
    IO (Either Text LoadedStackArgs)
loadStackArgsWith policy mkLoader argsfile environment operation cliAws =
    runExceptT $ do
        content <- lift $ BL.readFile argsfile
        let baseLocation = T.pack argsfile

        -- Parse YAML
        ast <- case parseYaml content baseLocation of
            Left (ParseError _pos msg) ->
                throwE $ "Parse error in " <> baseLocation <> ": " <> msg
            Right a -> pure a

        -- Preprocess (YAML 1.1 for CFN compatibility)
        loader <- lift (mkLoader ast)
        preprocessResult <- ExceptT $ do
            r <- preprocessWithPolicy policy loader True ast baseLocation
            pure $ case r of
                Left err ->
                    Left $
                        "Preprocess error in "
                            <> baseLocation
                            <> ": "
                            <> T.pack (show err)
                Right ok -> Right ok

        let jsonVal = toValue (prValue preprocessResult)

        -- Resolve environment maps (can fail if env not found in map)
        resolved <- case resolveEnvMaps jsonVal environment of
            Left err ->
                throwE $ "Environment map error in " <> baseLocation <> ": " <> err
            Right v -> pure v

        let withEnvTag = ensureEnvironmentTag resolved environment
            withEnvValues = injectEnvValues withEnvTag environment operation cliAws

        -- Extract AWS settings from argsfile
        let argsfileAws = extractAwsSettings withEnvValues
            mergedAws = mergeAwsSettings cliAws argsfileAws
            detectionCtx =
                CredentialDetectionContext
                    { cdcCliProfile = awsProfile cliAws
                    , cdcStackArgsProfile = awsProfile argsfileAws
                    , cdcCliAssumeRoleArn = awsAssumeRoleArn cliAws
                    , cdcStackArgsAssumeRoleArn = awsAssumeRoleArn argsfileAws
                    }

        -- Deserialize to StackArgs
        stackArgs <- case valueToStackArgs withEnvValues of
            Left err ->
                throwE $
                    "Failed to parse stack args from " <> baseLocation <> ": " <> err
            Right sa -> pure sa

        refuseCommandsBefore baseLocation operation stackArgs

        pure
            LoadedStackArgs
                { lsaStackArgs = stackArgs
                , lsaMergedAws = mergedAws
                , lsaDetectionCtx = detectionCtx
                }

------------------------------------------------------------------------
-- CommandsBefore
------------------------------------------------------------------------

{- | Refuse a stack-args file with a non-empty @CommandsBefore@ for the operations that
would run it in Rust (@should_process_commands_before@,
@src/cfn/stack_args.rs:483-490@) and iidy-js (@loadStackArgs.ts:137-166@).
iidy-hs never runs the commands (see DIVERGENCES.md), so going ahead would
skip them silently. An empty list runs nothing in the originals and loads.
Other operations accept the field and ignore it.
-}
refuseCommandsBefore :: (Monad m) => Text -> CfnOperation -> StackArgs -> ExceptT Text m ()
refuseCommandsBefore argsfile operation sa = case saCommandsBefore sa of
    Just (_ : _)
        | runsCommandsBefore operation ->
            throwE $
                "CommandsBefore in "
                    <> argsfile
                    <> " is not supported: iidy-hs does not run these commands for "
                    <> cfnOperationStr operation
                    <> ". Remove CommandsBefore from the file, or run the commands yourself before running iidy-hs."
    _notRun -> pure ()

-- | The operations Rust and iidy-js run @CommandsBefore@ for.
runsCommandsBefore :: CfnOperation -> Bool
runsCommandsBefore = \case
    OpCreateStack -> True
    OpUpdateStack -> True
    OpCreateChangeset -> True
    OpCreateOrUpdate -> True
    _other -> False

------------------------------------------------------------------------
-- Environment map resolution
------------------------------------------------------------------------

{- | Resolve environment maps for Profile, Region, AssumeRoleARN.
These fields can be either a string or a mapping of environment -> string.
Returns Left with an error if an env map doesn't contain the current environment
or if the resolved value is not a string (matching Rust behavior).
-}
resolveEnvMaps :: Value -> Text -> Either Text Value
resolveEnvMaps (Object obj) env =
    Object
        <$> foldM
            (\acc key -> resolveEnvMapField acc key env)
            obj
            (map credentialFieldKey credentialFields)
resolveEnvMaps v _ = Right v

resolveEnvMapField :: KM.KeyMap Value -> Text -> Text -> Either Text (KM.KeyMap Value)
resolveEnvMapField obj key env =
    case KM.lookup (Key.fromText key) obj of
        Just (Object envMap) ->
            case KM.lookup (Key.fromText env) envMap of
                Just (String s) -> Right $ KM.insert (Key.fromText key) (String s) obj
                Just _nonString ->
                    Left $
                        "The " <> key <> " setting in stack-args.yaml must map environments to strings"
                Nothing ->
                    Left $
                        "environment '" <> env <> "' not found in " <> key <> " map"
        Just (String _) -> Right obj -- already a scalar string
        Just Null -> Right obj -- null is fine
        Nothing -> Right obj -- absent is fine
        Just _ ->
            Left $
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
            _nonMapping -> KM.empty
        tags' = case KM.lookup envKey tags of
            Just _existing -> tags -- already set
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
            _nonMapping -> KM.empty
        -- New values take precedence over existing
        merged = case envValues of
            Object newMap -> Object (KM.union newMap existing)
            _nonObject -> envValues
     in Object (KM.insert envValuesKey merged obj)
injectEnvValues v _ _ _ = v

-- | Build $envValues matching iidy-js structure
buildEnvValues :: Text -> CfnOperation -> AwsSettings -> Value
buildEnvValues env operation aws =
    let region = fromMaybe "" (awsRegion aws)
        iidyBase =
            KM.fromList
                [ (Key.fromText "command", String (cfnOperationStr operation))
                , (Key.fromText "environment", String env)
                , (Key.fromText "region", String region)
                ]
        iidyNs = case awsProfile aws of
            Just p -> Object (KM.insert (Key.fromText "profile") (String p) iidyBase)
            Nothing -> Object iidyBase
     in Object $
            KM.fromList
                [ (Key.fromText "region", String region)
                , (Key.fromText "environment", String env)
                , (Key.fromText "iidy", iidyNs)
                ]

------------------------------------------------------------------------
-- AWS settings extraction and merging
------------------------------------------------------------------------

-- | Extract AWS settings from preprocessed argsfile Value
extractAwsSettings :: Value -> AwsSettings
extractAwsSettings (Object obj) = settingsFromFields (getStr obj . credentialFieldKey)
extractAwsSettings _ = AwsSettings Nothing Nothing Nothing
