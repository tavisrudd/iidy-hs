module Main (main) where

import Control.Exception (catch, finally)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Foreign.C.Types (CInt (..))
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitSuccess, exitWith)
import System.IO (hPutStrLn, stderr)
import System.Posix.Signals (Handler (..), installHandler, sigINT)

import Iidy.Aws.Config (createAwsEnvFromSettings)
import Iidy.Cfn.CommandMetadata (constructCommandMetadata, createFinalCommandSummary)
import Iidy.Cfn.Context (CfnContext (..), ctxElapsedSeconds)
import Iidy.Cfn.Operations.Changeset (
    StackState (..),
    buildChangeSetCreationResult,
    checkStackState,
    createChangeset,
    executeChangeset,
    generateDashedName,
 )
import Iidy.Cfn.Operations.ConvertStack (convertStackToIidy)
import Iidy.Cfn.Operations.CreateOrUpdate (createOrUpdate)
import Iidy.Cfn.Operations.CreateStack (createStack)
import Iidy.Cfn.Operations.DeleteStack (deleteStack)
import Iidy.Cfn.Operations.DescribeStack (describeStack)
import Iidy.Cfn.Operations.DescribeStackDrift (describeStackDrift)
import Iidy.Cfn.Operations.EstimateCost (estimateCost)
import Iidy.Cfn.Operations.GetStackTemplate (getStackTemplate)
import Iidy.Cfn.Operations.LintTemplate (lintTemplate)
import Iidy.Cfn.Operations.ListStacks (listStacks)
import Iidy.Cfn.Operations.TemplateApproval (templateApprovalRequest, templateApprovalReview)
import Iidy.Cfn.Operations.UpdateStack (updateStack, updateStackWithChangeset)
import Iidy.Cfn.Operations.WatchStack (watchStack)
import Iidy.Cfn.Runner (createSimpleContext, runCfnWithArgs)
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..), StackInput (..), emptyStackArgs)
import Iidy.Cli
import Iidy.Cli.Completion (bashCompletionScript, fishCompletionScript, zshCompletionScript)
import Iidy.Cli.Parser (parseCliOpts)
import Iidy.Demo (runDemo)
import Iidy.Errors (dieTxt, handleEither, handleUncaughtException)
import Iidy.Explain (explainErrors)
import Iidy.GetImport (runGetImport)
import Iidy.InitStackArgs (runInitStackArgs)
import Iidy.Output.Manager (cleanupOutputDispatch, mkOutputDispatch, renderOutput)
import Iidy.Output.Types (OutputData (..))
import Iidy.Params.Client (GetByPathResult (..), paramGet, paramGetByPath, paramGetHistory, paramSet)
import Iidy.Params.Review (paramReview)
import Iidy.Render (runRender)
import Iidy.Yaml.Imports.Types (RemoteImports (..))

{- | POSIX _exit(2) — terminates immediately without cleanup.
Used for signal handlers to avoid GHC's backtrace on exitWith.
-}
foreign import ccall "unistd.h _exit" c_exit :: CInt -> IO ()

main :: IO ()
main = do
    -- Install SIGINT handler: _exit(130) avoids GHC backtrace on Ctrl-C
    _ <- installHandler sigINT (CatchOnce $ c_exit 130) Nothing
    -- Catch unhandled exceptions (missing file, AWS errors, etc.)
    -- and format them like Rust does, without GHC backtrace noise.
    ( do
            cli <- parseCliOpts
            runCommand cli
        )
        `catch` handleUncaughtException

------------------------------------------------------------------------
-- Command dispatch
------------------------------------------------------------------------

runCommand :: Cli -> IO ()
runCommand cli = case cliCommand cli of
    CmdRender args -> do
        dispatch <- mkOutputDispatch (cliGlobalOpts cli)
        runRender (renderOutput dispatch) args (cliGlobalOpts cli) >>= exitCode
    CmdExplain codes -> explainErrors codes
    -- CloudFormation operations with stack-args
    CmdCreateStack args ->
        runCfnWithArgs cli OpCreateStack (csaArgsfile args) (csaStackName args) $
            \ctx input -> createStack ctx (siArgs input) (siArgsFile input) >>= handleEither
    CmdUpdateStack args ->
        runCfnWithArgs cli OpUpdateStack (sfaArgsfile (usaBase args)) (sfaStackName (usaBase args)) $
            \ctx input ->
                let sa = siArgs input; fp = siArgsFile input
                 in if usaChangeset args
                        then updateStackWithChangeset ctx sa (usaYes args) fp >>= handleEither
                        else updateStack ctx sa fp >>= handleEither
    CmdCreateOrUpdate args ->
        runCfnWithArgs cli OpCreateOrUpdate (sfaArgsfile (usaBase args)) (sfaStackName (usaBase args)) $
            \ctx input -> createOrUpdate ctx (siArgs input) (usaChangeset args) (usaYes args) (siArgsFile input) >>= handleEither
    CmdEstimateCost args ->
        runCfnWithArgs cli OpEstimateCost (sfaArgsfile args) (sfaStackName args) $
            \ctx input -> estimateCost ctx (siArgs input) (siArgsFile input) >>= handleEither
    CmdCreateChangeset args ->
        runCfnWithArgs cli OpCreateChangeset (ccsArgsfile args) (ccsStackName args) $
            \ctx input -> do
                let sa = siArgs input
                    emit = cfnEmit ctx
                -- Determine changeset name (user-provided or random)
                csName <- maybe generateDashedName pure (ccsChangesetName args)
                -- Check stack state to determine changeset type
                let stackName = saStackName sa
                state <- checkStackState ctx stackName
                let exists = case state of StackNormal -> True; _ -> False
                csEither <- createChangeset ctx sa csName exists (siArgsFile input)
                case csEither of
                    Left err -> do
                        emit (OdRawOutput err)
                        pure 1
                    Right info -> do
                        let csResult = buildChangeSetCreationResult info exists (ccsArgsfile args)
                        emit (OdChangeSetResult csResult)
                        pure 0
    CmdExecChangeset args -> do
        let stackName = fromMaybe "" (ecsStackName args)
            env = goEnvironment (cliGlobalOpts cli)
            remoteImports = if goRemoteImports (cliGlobalOpts cli) then AllowRemoteImports else BlockRemoteImports
        dispatch <- mkOutputDispatch (cliGlobalOpts cli)
        let emit = renderOutput dispatch
        ctx <- createSimpleContext cli OpExecuteChangeset env remoteImports emit
        -- Emit CommandMetadata before operation
        meta <- constructCommandMetadata ctx (cliToAwsSettings cli) emptyStackArgs env Nothing
        emit (OdCommandMetadata meta)
        result <-
            executeChangeset ctx stackName (ecsChangesetName args)
                `finally` cleanupOutputDispatch dispatch
        case result of
            Left err -> dieTxt err
            Right rc -> do
                elapsed <- ctxElapsedSeconds ctx
                emit (createFinalCommandSummary (rc == 0) elapsed)
                exitCode rc

    -- Read-only CloudFormation operations
    CmdDescribeStack args -> do
        let env = goEnvironment (cliGlobalOpts cli)
        dispatch <- mkOutputDispatch (cliGlobalOpts cli)
        let emit = renderOutput dispatch
        ctx <- createSimpleContext cli OpDescribeStack env BlockRemoteImports emit
        result <- describeStack ctx (daStackname args) (daEvents args) env emit
        case result of
            Left err -> dieTxt err
            Right () -> pure ()
    CmdWatchStack args -> do
        dispatch <- mkOutputDispatch (cliGlobalOpts cli)
        ctx <- createSimpleContext cli OpWatchStack "" BlockRemoteImports (renderOutput dispatch)
        result <-
            watchStack ctx (waStackname args) (waInactivityTimeout args) (renderOutput dispatch)
                `finally` cleanupOutputDispatch dispatch
        case result of
            Left err -> dieTxt err
            Right rc -> exitCode rc
    CmdDescribeStackDrift args -> do
        dispatch <- mkOutputDispatch (cliGlobalOpts cli)
        ctx <- createSimpleContext cli OpDescribeStackDrift "" BlockRemoteImports (renderOutput dispatch)
        result <- describeStackDrift ctx (drfStackname args) (drfDriftCache args) (renderOutput dispatch)
        case result of
            Left err -> dieTxt err
            Right () -> pure ()
    CmdDeleteStack args -> do
        let env = goEnvironment (cliGlobalOpts cli)
        dispatch <- mkOutputDispatch (cliGlobalOpts cli)
        let emit = renderOutput dispatch
        ctx <- createSimpleContext cli OpDeleteStack env BlockRemoteImports emit
        -- Emit CommandMetadata before operation
        meta <- constructCommandMetadata ctx (cliToAwsSettings cli) emptyStackArgs env Nothing
        emit (OdCommandMetadata meta)
        result <-
            deleteStack ctx (delStackname args) (delYes args) env emit
                `finally` cleanupOutputDispatch dispatch
        case result of
            Left err -> dieTxt err
            Right rc -> do
                elapsed <- ctxElapsedSeconds ctx
                -- rc=0 is success, rc=130 is user declined (also success per Rust)
                emit (createFinalCommandSummary (rc == 0 || rc == 130) elapsed)
                exitCode rc
    CmdGetStackTemplate args -> do
        dispatch <- mkOutputDispatch (cliGlobalOpts cli)
        let emit = renderOutput dispatch
        ctx <- createSimpleContext cli OpGetStackTemplate "" BlockRemoteImports emit
        result <- getStackTemplate ctx (gtaStackname args)
        case result of
            Left err -> dieTxt err
            Right tpl -> emit (OdRawOutput (tpl <> "\n"))
    CmdListStacks args -> do
        dispatch <- mkOutputDispatch (cliGlobalOpts cli)
        ctx <- createSimpleContext cli OpListStacks "" BlockRemoteImports (renderOutput dispatch)
        let tagFilters = if null (laTagFilter args) then Nothing else Just (laTagFilter args)
            hasQuery = case laQuery args of Just _ -> True; Nothing -> False
        result <- listStacks ctx tagFilters (laTags args) hasQuery
        case result of
            Left err -> dieTxt err
            Right datas -> mapM_ (renderOutput dispatch) datas

    -- SSM Parameter commands
    CmdParam pcmd -> do
        (env, _creds) <- createAwsEnvFromSettings (cliToAwsSettings cli)
        dispatch <- mkOutputDispatch (cliGlobalOpts cli)
        let emit = renderOutput dispatch
        case pcmd of
            ParamGet args -> do
                result <- paramGet env args
                case result of
                    Left err -> dieTxt err
                    Right val -> emit (OdRawOutput (val <> "\n"))
            ParamSet args -> do
                result <- paramSet env args
                case result of
                    Left err -> dieTxt err
                    Right () -> emit (OdRawOutput "Parameter set successfully.\n")
            ParamGetByPath args -> do
                result <- paramGetByPath env args
                case result of
                    Left err -> dieTxt err
                    Right ByPathEmpty -> do
                        emit (OdRawOutput "No parameters found\n")
                        exitCode 1
                    Right (ByPathOutput txt) -> emit (OdRawOutput txt)
            ParamGetHistory args -> do
                result <- paramGetHistory env args
                case result of
                    Left err -> dieTxt err
                    Right txt -> emit (OdRawOutput txt)
            ParamReview args -> do
                result <- paramReview env (ppaPath args)
                case result of
                    Left err -> dieTxt err
                    Right rc -> exitCode rc

    -- Removed command — directs users to AWS CLI
    CmdGetStackInstances args -> do
        hPutStrLn stderr $
            "The get-stack-instances command has been removed. Use the AWS CLI instead:\n  \
            \aws ec2 describe-instances \\\n    \
            \--filters \"Name=tag:aws:cloudformation:stack-name,Values="
                <> T.unpack (gsiStackname args)
                <> "\""
        exitWith (ExitFailure 1)
    CmdTemplateApproval acmd -> case acmd of
        ApprovalRequest args ->
            runCfnWithArgs cli OpTemplateApprovalRequest (araArgsfile args) Nothing $
                \ctx input -> do
                    result <- templateApprovalRequest ctx (siArgs input) (araLintTemplate args) (siArgsFile input)
                    handleEither result
        ApprovalReview args -> do
            dispatch <- mkOutputDispatch (cliGlobalOpts cli)
            let emit = renderOutput dispatch
                ri = if goRemoteImports (cliGlobalOpts cli) then AllowRemoteImports else BlockRemoteImports
            ctx <- createSimpleContext cli OpTemplateApprovalReview "" ri emit
            result <- templateApprovalReview ctx (arvUrl args) (arvContext args)
            case result of
                Left err -> dieTxt err
                Right rc -> exitCode rc
    CmdGetImport args -> do
        dispatch <- mkOutputDispatch (cliGlobalOpts cli)
        runGetImport (renderOutput dispatch) args (cliGlobalOpts cli) >>= exitCode
    CmdDemo args ->
        let ri = if goRemoteImports (cliGlobalOpts cli) then AllowRemoteImports else BlockRemoteImports
         in runDemo (daDemoscript args) (daTimescaling args) (daMaskSecrets args) ri >>= exitCode
    CmdLintTemplate args ->
        runCfnWithArgs cli OpLintTemplate (ltaArgsfile args) Nothing $
            \ctx input -> lintTemplate ctx (siArgs input) (siArgsFile input) >>= handleEither
    CmdConvertStackToIidy args -> do
        ctx <- createSimpleContext cli OpConvertStackToIidy "" BlockRemoteImports (\_ -> pure ())
        result <-
            convertStackToIidy
                ctx
                (caStackname args)
                (caOutputDir args)
                (caMoveParamsToSsm args)
                (caSortkeys args)
                (caProject args)
        case result of
            Left err -> dieTxt err
            Right rc -> exitCode rc
    CmdInitStackArgs args -> runInitStackArgs args >>= exitCode
    CmdCompletion mShell -> do
        shellType <- case mShell of
            Just st -> pure st
            Nothing -> do
                mEnv <- lookupEnv "SHELL"
                pure $ case mEnv of
                    Just s -> detectShellType (reverse $ takeWhile (/= '/') (reverse s))
                    Nothing -> ShellBash
        case shellType of
            ShellBash -> putStrLn bashCompletionScript
            ShellZsh -> putStrLn zshCompletionScript
            ShellFish -> putStrLn fishCompletionScript

-- | Exit with given code
exitCode :: Int -> IO ()
exitCode 0 = exitSuccess
exitCode n = exitWith (ExitFailure n)
