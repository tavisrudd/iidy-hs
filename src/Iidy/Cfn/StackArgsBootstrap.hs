{- | Stack-args loading with the AWS environment its imports run under.

A stack-args file may use AWS imports (@ssm:@, @ssm-path:@, @cfn:@, @s3:@).
They run during preprocessing, before computed values exist, so their
environment is built from the credential fields as written in the file
('readRawField'), merged under the CLI settings. Following iidy-js
(@src/cfn/loadStackArgs.ts:91-118@), a credential field that is not a plain
string or an environment map of plain strings refuses the first AWS import,
unless the command line sets that field: otherwise the import would run
under different credentials or region than the file finally names. As a
backstop, the settings the imports ran with are compared with the final
merged settings, and any difference refuses the load. A file without AWS
imports never builds this environment and is not checked.
-}
module Iidy.Cfn.StackArgsBootstrap (
    loadStackArgsBootstrapped,

    -- * Internal (exported for testing)
    importSettingsMismatch,
) where

import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T

import Amazonka qualified

import Iidy.Aws.CredentialSource (AwsSettings)
import Iidy.Cfn.StackArgsLoader (
    CredentialField,
    LoadedStackArgs (..),
    RawField (..),
    credentialFieldFlag,
    credentialFieldKey,
    credentialFieldSetting,
    credentialFields,
    extractRawAwsFromAst,
    loadStackArgsWith,
    mergeAwsSettings,
    readRawField,
 )
import Iidy.Cfn.Types (CfnOperation)
import Iidy.GetImport (needsAwsEnv)
import Iidy.Yaml.Ast (YamlAst)
import Iidy.Yaml.Engine (LoadImportFn)
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig (..), mkFullDispatcher)
import Iidy.Yaml.Imports.Types (ImportError (..), RemoteImports, parseImportType)

{- | Load a stack-args file, building the import environment with the given
factory at the first AWS import. Production passes
'Iidy.Aws.Config.createAwsEnvFromSettings'; tests pass a mock factory and
inspect the settings it was asked for.
-}
loadStackArgsBootstrapped ::
    -- | AWS env factory
    (AwsSettings -> IO Amazonka.Env) ->
    -- | argsfile path
    FilePath ->
    -- | environment name
    Text ->
    CfnOperation ->
    -- | CLI-provided AWS settings
    AwsSettings ->
    RemoteImports ->
    IO (Either Text LoadedStackArgs)
loadStackArgsBootstrapped mkEnv argsfile environment operation cliAws remoteImports = do
    ranWith <- newIORef Nothing
    loaded <-
        loadStackArgsWith
            (bootstrapLoader ranWith mkEnv argsfileText environment cliAws remoteImports)
            argsfile
            environment
            operation
            cliAws
    importSettings <- readIORef ranWith
    pure $ do
        result <- loaded
        case importSettings >>= \settings -> importSettingsMismatch argsfileText settings (lsaMergedAws result) of
            Just err -> Left err
            Nothing -> Right result
  where
    argsfileText = T.pack argsfile

{- | The refusal when the AWS imports ran with settings (first argument)
that differ from the final merged settings (second argument), or 'Nothing'
when they agree.
-}
importSettingsMismatch :: Text -> AwsSettings -> AwsSettings -> Maybe Text
importSettingsMismatch argsfile importSettings finalSettings =
    case [field | field <- credentialFields, setting field importSettings /= setting field finalSettings] of
        [] -> Nothing
        field : _ ->
            Just $
                "In "
                    <> argsfile
                    <> ", the AWS imports ran with "
                    <> credentialFieldKey field
                    <> " "
                    <> settingText (setting field importSettings)
                    <> ", but the final "
                    <> credentialFieldKey field
                    <> " is "
                    <> settingText (setting field finalSettings)
                    <> "."
                    <> fixAdvice field
  where
    setting = credentialFieldSetting

{- | The import loader for one parsed stack-args file. Non-AWS imports load
as usual; the first AWS import checks the credential fields and builds the
environment, and every later one reuses that outcome.
-}
bootstrapLoader ::
    -- | set to the settings the import env was built with
    IORef (Maybe AwsSettings) ->
    (AwsSettings -> IO Amazonka.Env) ->
    -- | argsfile path
    Text ->
    -- | environment name
    Text ->
    AwsSettings ->
    RemoteImports ->
    YamlAst ->
    IO LoadImportFn
bootstrapLoader ranWith mkEnv argsfile environment cliAws remoteImports ast = do
    outcome <- newIORef Nothing
    let importSettings = mergeAwsSettings cliAws (extractRawAwsFromAst ast environment)
        dispatcher mEnv = mkFullDispatcher ImportConfig{icAwsEnv = mEnv, icRemoteImports = remoteImports}
        notPlain =
            [ (field, why)
            | field <- credentialFields
            , isNothing (credentialFieldSetting field cliAws)
            , RawComputed why <- [readRawField ast environment field]
            ]
        awsEnvFor location = do
            known <- readIORef outcome
            case known of
                Just result -> pure result
                Nothing -> do
                    result <- case notPlain of
                        (field, why) : _ ->
                            pure (Left (computedFieldError argsfile location importSettings field why))
                        [] -> do
                            built <- buildImportEnv mkEnv argsfile location importSettings
                            either (const (pure ())) (const (writeIORef ranWith (Just importSettings))) built
                            pure built
                    writeIORef outcome (Just result)
                    pure result
    pure $ \location baseLocation ->
        if isAwsImport remoteImports location baseLocation
            then do
                envResult <- awsEnvFor location
                case envResult of
                    Left err -> pure (Left (ImportError err))
                    Right env -> dispatcher (Just env) location baseLocation
            else dispatcher Nothing location baseLocation

-- | Whether loading this import location makes AWS calls ('needsAwsEnv').
isAwsImport :: RemoteImports -> Text -> Text -> Bool
isAwsImport remoteImports location baseLocation =
    either (const False) (needsAwsEnv remoteImports) (parseImportType location baseLocation)

-- | Run the factory, turning a synchronous failure into a message with its cause.
buildImportEnv :: (AwsSettings -> IO Amazonka.Env) -> Text -> Text -> AwsSettings -> IO (Either Text Amazonka.Env)
buildImportEnv mkEnv argsfile location settings = do
    built <- try (mkEnv settings)
    case built of
        Right env -> pure (Right env)
        Left (e :: SomeException)
            | isJust (fromException e :: Maybe SomeAsyncException) -> throwIO e
            | otherwise ->
                pure . Left $
                    "cannot build the AWS environment for the import "
                        <> location
                        <> " in "
                        <> argsfile
                        <> " ("
                        <> describeSettings settings
                        <> "): "
                        <> T.pack (displayException e)

-- | The refusal for a credential field that is not plain; @why@ is a clause.
computedFieldError :: Text -> Text -> AwsSettings -> CredentialField -> Text -> Text
computedFieldError argsfile location importSettings field why =
    "In "
        <> argsfile
        <> ", "
        <> why
        <> ", so the AWS import "
        <> location
        <> " would run with "
        <> credentialFieldKey field
        <> " "
        <> settingText (credentialFieldSetting field importSettings)
        <> " instead of the value the file computes."
        <> fixAdvice field

-- | What the user can do about a refused credential field.
fixAdvice :: CredentialField -> Text
fixAdvice field =
    " In a stack-args file with AWS imports, "
        <> T.intercalate ", " (map credentialFieldKey credentialFields)
        <> " must be plain strings or environment maps of plain strings: set "
        <> credentialFieldKey field
        <> " literally or pass "
        <> credentialFieldFlag field
        <> " on the command line"

-- | Each credential field of a settings value, for messages.
describeSettings :: AwsSettings -> Text
describeSettings settings =
    T.intercalate
        ", "
        [ credentialFieldKey field <> " " <> settingText (credentialFieldSetting field settings)
        | field <- credentialFields
        ]

settingText :: Maybe Text -> Text
settingText = fromMaybe "not set (ambient AWS configuration)"
