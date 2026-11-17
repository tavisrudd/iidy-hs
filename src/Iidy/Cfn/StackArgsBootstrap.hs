{- | Stack-args loading with the AWS environment its imports run under.

A stack-args file may use AWS imports (@ssm:@, @cfn:@, @s3:@). Those run
during preprocessing, before the file's own @Profile@, @Region@ and
@AssumeRoleARN@ are known in their final form, so the import environment
is built from the fields as written in the file, merged under the CLI
settings.
-}
module Iidy.Cfn.StackArgsBootstrap (
    loadStackArgsBootstrapped,
) where

import Control.Exception (SomeException, catch)
import Data.Text (Text)

import Amazonka qualified

import Iidy.Aws.CredentialSource (AwsSettings)
import Iidy.Cfn.StackArgsLoader (
    LoadedStackArgs,
    extractRawAwsFromFile,
    loadStackArgs,
    mergeAwsSettings,
 )
import Iidy.Cfn.Types (CfnOperation)
import Iidy.Yaml.Imports.Types (RemoteImports)

{- | Load a stack-args file, building the import environment with the given
factory. Production passes 'Iidy.Aws.Config.createAwsEnvFromSettings';
tests pass a mock factory and inspect the settings it was asked for.
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
    bootstrapEnv <-
        ( do
            rawAws <- extractRawAwsFromFile argsfile environment
            Just <$> mkEnv (mergeAwsSettings cliAws rawAws)
        )
            `catch` (\(_ :: SomeException) -> pure Nothing)
    loadStackArgs argsfile environment operation cliAws remoteImports bootstrapEnv
