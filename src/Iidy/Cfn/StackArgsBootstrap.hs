{- | Stack-args loading with the AWS environment its imports run under.

A stack-args file may use AWS imports (@ssm:@, @ssm-path:@, @cfn:@, @s3:@).
They run during preprocessing, before computed values exist, so their
environment is built from the credential fields as written in the file
('readRawField'), merged under the CLI settings. Following iidy-js
(@src/cfn/loadStackArgs.ts:91-118@), a credential field that is not a plain
string or an environment map of plain strings refuses the first AWS import,
unless the command line sets that field: otherwise the import would run
under different credentials or region than the file finally names. A file
without AWS imports never builds this environment and is not checked.
-}
module Iidy.Cfn.StackArgsBootstrap (
    loadStackArgsBootstrapped,
) where

import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T

import Amazonka qualified

import Iidy.Aws.CredentialSource (AwsSettings)
import Iidy.Cfn.StackArgsLoader (
    CredentialField,
    LoadedStackArgs,
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
loadStackArgsBootstrapped mkEnv argsfile environment operation cliAws remoteImports =
    loadStackArgsWith
        (bootstrapLoader mkEnv (T.pack argsfile) environment cliAws remoteImports)
        argsfile
        environment
        operation
        cliAws

{- | The import loader for one parsed stack-args file. Non-AWS imports load
as usual; the first AWS import checks the credential fields and builds the
environment, and every later one reuses that outcome.
-}
bootstrapLoader ::
    (AwsSettings -> IO Amazonka.Env) ->
    -- | argsfile path
    Text ->
    -- | environment name
    Text ->
    AwsSettings ->
    RemoteImports ->
    YamlAst ->
    IO LoadImportFn
bootstrapLoader mkEnv argsfile environment cliAws remoteImports ast = do
    outcome <- newIORef Nothing
    let importSettings = mergeAwsSettings cliAws (extractRawAwsFromAst ast environment)
        dispatcher mEnv = mkFullDispatcher ImportConfig{icAwsEnv = mEnv, icRemoteImports = remoteImports}
        notPlain =
            [ (field, how)
            | field <- credentialFields
            , isNothing (credentialFieldSetting field cliAws)
            , RawComputed how <- [readRawField ast environment field]
            ]
        awsEnvFor location = do
            known <- readIORef outcome
            case known of
                Just result -> pure result
                Nothing -> do
                    result <- case notPlain of
                        (field, how) : _ ->
                            pure (Left (computedFieldError argsfile location importSettings field how))
                        [] -> buildImportEnv mkEnv argsfile location importSettings
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

-- | The refusal for a credential field that is not plain.
computedFieldError :: Text -> Text -> AwsSettings -> CredentialField -> Text -> Text
computedFieldError argsfile location importSettings field how =
    let key = credentialFieldKey field
     in key
            <> " in "
            <> argsfile
            <> " is "
            <> how
            <> ", not a plain string, so the AWS import "
            <> location
            <> " would run with "
            <> key
            <> " "
            <> settingText (credentialFieldSetting field importSettings)
            <> " instead of the value the file computes. In a stack-args file"
            <> " with AWS imports, "
            <> T.intercalate ", " (map credentialFieldKey credentialFields)
            <> " must be plain strings or environment maps of plain strings: set "
            <> key
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
