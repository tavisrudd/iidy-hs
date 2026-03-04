{- | CFN operation runner — orchestrates AWS env setup, stack-args loading,
context creation, metadata emission, and final summary for CloudFormation
operations.
-}
module Iidy.Cfn.Runner (
    runCfnWithArgs,
    createSimpleContext,
    emitsCommandMetadata,
) where

import Control.Exception (SomeException, catch, finally)
import Control.Monad (when)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..), exitSuccess, exitWith)

import Iidy.Aws.ClientReqToken (generateTokenFromMaybe)
import Iidy.Aws.Config (createAwsEnv, createAwsEnvFromSettings)
import Iidy.Aws.Timing (timeProviderForOperation)
import Iidy.Cfn.CommandMetadata (constructCommandMetadata, createFinalCommandSummary)
import Iidy.Cfn.Context (CfnContext, createContext, createContextFromEnv, ctxElapsedSeconds)
import Iidy.Cfn.GlobalConfig (applyGlobalConfiguration)
import Iidy.Cfn.StackArgsLoader (
    LoadedStackArgs (..),
    extractRawAwsFromFile,
    loadStackArgs,
    mergeAwsSettings,
 )
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..), StackInput (..))
import Iidy.Cli (AwsOpts (..), Cli (..), GlobalOpts (..), cliToAwsSettings)
import Iidy.Errors (dieTxt)
import Iidy.Output.Manager (cleanupOutputDispatch, mkOutputDispatch, renderOutput)
import Iidy.Output.Types (OutputData (..))
import Iidy.Yaml.Imports.Types (RemoteImports (..))

{- | Run a CFN operation that requires loading stack args from an argsfile.
Creates an output dispatch, builds CfnContext with all session-scoped fields,
bundles per-operation data into StackInput, and passes both to the callback.
For write operations, emits CommandMetadata before and FinalCommandSummary after.
-}
runCfnWithArgs ::
    Cli ->
    CfnOperation ->
    -- | argsfile path
    Text ->
    -- | stack name override from CLI
    Maybe Text ->
    (CfnContext -> StackInput -> IO Int) ->
    IO ()
runCfnWithArgs cli operation argsfile stackNameOverride action = do
    let env = goEnvironment (cliGlobalOpts cli)
        cliAws = cliToAwsSettings cli
        argsfilePath = T.unpack argsfile
        remoteImports = if goRemoteImports (cliGlobalOpts cli) then AllowRemoteImports else BlockRemoteImports

    dispatch <- mkOutputDispatch (cliGlobalOpts cli)
    let emit = renderOutput dispatch

    -- Bootstrap AWS env for import processing.
    -- Extracts raw Profile/Region/AssumeRoleARN from the argsfile YAML
    -- (before preprocessing) and merges with CLI settings to create an env
    -- that SSM/CFN/S3 import loaders can use during preprocessing.
    -- Falls back to Nothing on any failure (loadStackArgs will report errors).
    bootstrapEnv <-
        ( do
            rawAws <- extractRawAwsFromFile argsfilePath env
            let merged = mergeAwsSettings cliAws rawAws
            Just . fst <$> createAwsEnvFromSettings merged
        )
            `catch` (\(_ :: SomeException) -> pure Nothing)

    result <- loadStackArgs argsfilePath env operation cliAws remoteImports bootstrapEnv
    case result of
        Left err -> dieTxt err
        Right (LoadedStackArgs sa mergedAws detectionCtx) -> do
            -- Create AWS env with merged settings
            (awsEnv, credStack) <- createAwsEnv detectionCtx mergedAws
            -- Apply global SSM configuration (silently ignored on error)
            sa'' <- applyGlobalConfiguration awsEnv sa
            let sa' = case stackNameOverride of
                    Just sn -> sa''{saStackName = sn}
                    Nothing -> sa''
            token <- generateTokenFromMaybe (aoClientRequestToken (cliAwsOpts cli))
            let tp = timeProviderForOperation operation
            ctx <- createContextFromEnv awsEnv credStack operation tp token env remoteImports emit
            let input = StackInput{siArgs = sa', siArgsFile = Just argsfilePath}

            -- Emit CommandMetadata for write operations (not lint/estimate-cost)
            when (emitsCommandMetadata operation) $
                do
                    meta <- constructCommandMetadata ctx mergedAws sa' env stackNameOverride
                    emit (OdCommandMetadata meta)

            rc <-
                action ctx input
                    `finally` cleanupOutputDispatch dispatch

            -- Emit FinalCommandSummary for write operations
            when (emitsCommandMetadata operation) $
                do
                    elapsed <- ctxElapsedSeconds ctx
                    emit (createFinalCommandSummary (rc == 0) elapsed)

            exitCode rc

-- | Create a simple CfnContext for operations that don't load stack args
createSimpleContext :: Cli -> CfnOperation -> Text -> RemoteImports -> (OutputData -> IO ()) -> IO CfnContext
createSimpleContext cli operation env ri emit = do
    let cliAws = cliToAwsSettings cli
    token <- generateTokenFromMaybe (aoClientRequestToken (cliAwsOpts cli))
    createContext cliAws operation (timeProviderForOperation operation) token env ri emit

{- | Operations that emit CommandMetadata and FinalCommandSummary.
Write operations minus lint and estimate-cost.
-}
emitsCommandMetadata :: CfnOperation -> Bool
emitsCommandMetadata = \case
    OpCreateStack -> True
    OpUpdateStack -> True
    OpCreateOrUpdate -> True
    OpCreateChangeset -> True
    OpTemplateApprovalRequest -> True
    OpTemplateApprovalReview -> True
    _ -> False

-- | Exit with given code
exitCode :: Int -> IO ()
exitCode 0 = exitSuccess
exitCode n = exitWith (ExitFailure n)
