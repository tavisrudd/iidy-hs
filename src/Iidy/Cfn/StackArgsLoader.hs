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
    loadStackArgsWithSettings,
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
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Amazonka qualified
import Iidy.Aws.CredentialSource (
    AwsSettings (..),
    CredentialDetectionContext (..),
 )
import Iidy.Cfn.CommandsBefore (
    CommandsBeforeInput (..),
    CommandsBeforeSettings,
    defaultCommandsBeforeSettings,
    runCommandsBefore,
    runsCommandsBefore,
 )
import Iidy.Cfn.StackArgs.Credentials (
    CredentialField (..),
    RawField (..),
    commandsBeforeKey,
    credentialFieldFlag,
    credentialFieldKey,
    credentialFieldSetting,
    credentialFields,
    extractRawAwsFromAst,
    mergeAwsSettings,
    mergeSentinel,
    noProfileSentinel,
    noRoleSentinel,
    readRawCommands,
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
import Iidy.Yaml.Ast (YamlAst (..), astMeta)
import Iidy.Yaml.Engine (
    LoadImportFn,
    PreprocessResult (..),
    preprocessYamlWithVariables,
 )
import Iidy.Yaml.Imports.ContentParsing (parseErrorMessage)
import Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher, mkImportConfig)
import Iidy.Yaml.Imports.Types (ImportPolicy (..))
import Iidy.Yaml.OValue (OValue, toValue)
import Iidy.Yaml.Parser (parseYamlStrict)

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
loadStackArgsWith = loadStackArgsWithSettings defaultCommandsBeforeSettings

{- | 'loadStackArgsWith' with the command-line settings for running
@CommandsBefore@ ("Iidy.Cfn.CommandsBefore").

For the four operations that run them, the entries are read from the raw
file, the document is preprocessed without them (pass 1, the commands'
context), the commands are dry-run and run, and the document is
preprocessed again with the expanded commands, so imports of files they
built are read after them (both originals resolve imports twice:
@stack_args.rs:282-320@, @loadStackArgs.ts:148-169@).
-}
loadStackArgsWithSettings ::
    CommandsBeforeSettings ->
    ImportPolicy ->
    (YamlAst -> IO LoadImportFn) ->
    FilePath ->
    Text ->
    CfnOperation ->
    AwsSettings ->
    IO (Either Text LoadedStackArgs)
loadStackArgsWithSettings settings policy mkLoader argsfile environment operation cliAws =
    runExceptT $ do
        content <- lift $ BL.readFile argsfile
        let baseLocation = T.pack argsfile

        -- Parse YAML
        ast <- case parseYamlStrict content baseLocation of
            Left perr ->
                throwE $ "Parse error in " <> baseLocation <> ": " <> parseErrorMessage perr
            Right a -> pure a

        -- Preprocess (YAML 1.1 for CFN compatibility)
        loader <- lift (mkLoader ast)
        let preprocess doc = ExceptT $ do
                r <- preprocessYamlWithVariables (ipTrustedSources policy) True loader doc baseLocation
                pure $ case r of
                    Left err ->
                        Left $
                            "Preprocess error in "
                                <> baseLocation
                                <> ": "
                                <> T.pack (show err)
                    Right ok -> Right ok
            -- Resolve environment maps (can fail if env not found in map)
            document preprocessResult =
                case resolveEnvMaps (toValue (prValue preprocessResult)) environment of
                    Left err ->
                        throwE $ "Environment map error in " <> baseLocation <> ": " <> err
                    Right v -> pure (ensureEnvironmentTag v environment)

        (finalAst, ran) <-
            if runsCommandsBefore operation
                then commandsBeforePass settings preprocess document argsfile ast environment operation cliAws
                else pure (ast, Nothing)

        withEnvTag <- document . fst =<< preprocess finalAst

        let withEnvValues = injectEnvValues withEnvTag environment operation cliAws

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

        -- A CommandsBefore the written key did not give (a computed key)
        -- never ran; refuse it.
        mapM_ (refuseComputedCommands baseLocation (saCommandsBefore stackArgs)) ran

        pure
            LoadedStackArgs
                { lsaStackArgs = stackArgs
                , lsaMergedAws = mergedAws
                , lsaDetectionCtx = detectionCtx
                }

------------------------------------------------------------------------
-- CommandsBefore
------------------------------------------------------------------------

{- | Read, dry-run and run the commands for an operation that runs them;
the document to preprocess finally (the commands replaced by their expanded
text) and the commands that ran ('Just' them, possibly none).
-}
commandsBeforePass ::
    CommandsBeforeSettings ->
    (YamlAst -> ExceptT Text IO (PreprocessResult, Map Text OValue)) ->
    (PreprocessResult -> ExceptT Text IO Value) ->
    FilePath ->
    YamlAst ->
    Text ->
    CfnOperation ->
    AwsSettings ->
    ExceptT Text IO (YamlAst, Maybe [Text])
commandsBeforePass settings preprocess document argsfile ast environment operation cliAws = do
    let baseLocation = T.pack argsfile
    commands <- case readRawCommands ast of
        Left why ->
            throwE $
                "In "
                    <> baseLocation
                    <> ", "
                    <> why
                    <> ": CommandsBefore entries must be strings written in the stack-args file"
        Right cs -> pure cs
    if null commands
        then pure (ast, Just [])
        else do
            (pass1, variables) <- preprocess (withCommands Nothing ast)
            stackArgsPass1 <- document pass1
            case stackArgsPass1 of
                Object o | KM.member (Key.fromText commandsBeforeKey) o -> throwE (computedCommandsError baseLocation)
                _noCommands -> pure ()
            let merged = mergeAwsSettings cliAws (extractAwsSettings stackArgsPass1)
            expanded <-
                ExceptT $
                    runCommandsBefore
                        settings
                        CommandsBeforeInput
                            { cbiArgsfile = argsfile
                            , cbiRawAst = ast
                            , cbiCommands = commands
                            , cbiOperation = operation
                            , cbiEnvironment = environment
                            , cbiProfile = awsProfile merged
                            , cbiRegion = awsRegion merged
                            , cbiStackArgs = stackArgsPass1
                            , cbiVariables = variables
                            }
            pure (withCommands (Just expanded) ast, Just expanded)

{- | The document with the written @CommandsBefore@ removed ('Nothing') or
its value replaced by plain strings.
-}
withCommands :: Maybe [Text] -> YamlAst -> YamlAst
withCommands replacement = \case
    AstMapping pairs meta -> AstMapping (concatMap replace pairs) meta
    other -> other
  where
    replace pair@(key, value) = case key of
        AstPlainString k _ | k == commandsBeforeKey -> case replacement of
            Nothing -> []
            Just texts -> [(key, AstSequence [AstPlainString t (astMeta value) | t <- texts] (astMeta value))]
        _other -> [pair]

{- | Refuse a final @CommandsBefore@ that differs from what ran: only a
computed key, tag or merge can produce one, and it never ran.
-}
refuseComputedCommands :: (Monad m) => Text -> Maybe [Text] -> [Text] -> ExceptT Text m ()
refuseComputedCommands argsfile final ran
    | fromMaybe [] final == ran = pure ()
    | otherwise = throwE (computedCommandsError argsfile)

computedCommandsError :: Text -> Text
computedCommandsError argsfile =
    "In "
        <> argsfile
        <> ", CommandsBefore is produced by a computed key, tag or merge; iidy-hs runs only a CommandsBefore list written in the stack-args file, so it refuses this one without running it"

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
