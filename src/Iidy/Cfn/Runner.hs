{- | CFN operation runner — orchestrates AWS env setup, stack-args loading,
context creation, metadata emission, and final summary for CloudFormation
operations.
-}
module Iidy.Cfn.Runner (
    runCfnWithArgs,
    createSimpleContext,
    emitsCommandMetadata,
) where

import Control.Exception (IOException, finally, try)
import Control.Monad (when)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..), exitSuccess, exitWith)
import System.IO (hIsTerminalDevice, stdin)

import Amazonka qualified

import Iidy.Aws.ClientReqToken (generateTokenFromMaybe)
import Iidy.Aws.Config (createAwsEnv, createAwsEnvFromSettings, resolveRegion)
import Iidy.Aws.Timing (timeProviderForOperation)
import Iidy.Cfn.CommandMetadata (constructCommandMetadata, createFinalCommandSummary)
import Iidy.Cfn.CommandsBefore (CommandsBeforeSettings (..), commandOutputFor)
import Iidy.Cfn.Context (CfnContext, createContext, createContextFromEnv, ctxElapsedSeconds)
import Iidy.Cfn.GlobalConfig (applyGlobalConfiguration)
import Iidy.Cfn.StackArgsBootstrap (loadStackArgsBootstrapped)
import Iidy.Cfn.StackArgsLoader (LoadedStackArgs (..))
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..), StackInput (..))
import Iidy.Cli (AwsOpts (..), Cli (..), GlobalOpts (..), cliToAwsSettings, importPolicyFromOpts)
import Iidy.Errors (dieTxt)
import Iidy.Output.Manager (cleanupOutputDispatch, mkOutputDispatch, renderOutput)
import Iidy.Output.Types (OutputData (..))
import Iidy.Types (OutputMode (..))
import Iidy.Yaml.Imports.Types (ImportPolicy)

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
        policy = importPolicyFromOpts (cliGlobalOpts cli)

    dispatch <- mkOutputDispatch (cliGlobalOpts cli)
    let emit = renderOutput dispatch

    -- Imports in the argsfile run under an env built by this factory;
    -- the final env below is built from the preprocessed settings.
    stdinIsTerminal <- hIsTerminalDevice stdin
    let commandsBefore =
            CommandsBeforeSettings
                { cbsOutput = commandOutputFor (goOutputMode (cliGlobalOpts cli) == Just Json)
                , cbsStackName = stackNameOverride
                , cbsResolveRegion = resolvedRegionText
                , cbsStdinIsTerminal = stdinIsTerminal
                }
    result <-
        loadStackArgsBootstrapped
            commandsBefore
            (fmap fst . createAwsEnvFromSettings)
            argsfilePath
            env
            operation
            cliAws
            policy
    case result of
        Left err -> dieTxt err
        Right (LoadedStackArgs sa mergedAws detectionCtx) -> do
            -- Create AWS env with merged settings
            (awsEnv, credStack) <- createAwsEnv detectionCtx mergedAws
            -- Apply global SSM configuration only when opted in with
            -- --global-config (operator roles often lack SSM read on /iidy/)
            sa'' <-
                if aoGlobalConfig (cliAwsOpts cli)
                    then applyGlobalConfiguration awsEnv sa
                    else pure sa
            let sa' = case stackNameOverride of
                    Just sn -> sa''{saStackName = sn}
                    Nothing -> sa''
            token <- generateTokenFromMaybe (aoClientRequestToken (cliAwsOpts cli))
            let tp = timeProviderForOperation operation
            ctx <- createContextFromEnv awsEnv credStack operation tp token env policy emit
            let input = StackInput{siArgs = sa', siArgsFile = Just argsfilePath}

            -- Emit CommandMetadata for write operations (not lint/estimate-cost)
            when (emitsCommandMetadata operation) $
                do
                    meta <- constructCommandMetadata ctx mergedAws (saServiceRoleArn sa') env stackNameOverride
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

{- | The region the AWS environment is built with ('resolveRegion', as
'createAwsEnv' applies it), or 'Nothing' when none is configured.
-}
resolvedRegionText :: Maybe Text -> IO (Maybe Text)
resolvedRegionText merged = do
    r <- try (resolveRegion merged)
    pure $ case r of
        Right region -> Just (Amazonka.fromRegion region)
        Left (_ :: IOException) -> Nothing

-- | Create a simple CfnContext for operations that don't load stack args
createSimpleContext :: Cli -> CfnOperation -> Text -> ImportPolicy -> (OutputData -> IO ()) -> IO CfnContext
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
    _readOnly -> False

-- | Exit with given code
exitCode :: Int -> IO ()
exitCode 0 = exitSuccess
exitCode n = exitWith (ExitFailure n)
