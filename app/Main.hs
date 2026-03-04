{-# LANGUAGE OverloadedRecordDot #-}
module Main (main) where

import Control.Exception (SomeException, IOException, catch, finally, fromException, displayException)
import qualified Amazonka
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.UUID.V4 (nextRandom)
import qualified Data.UUID as UUID
import Foreign.C.Types (CInt(..))
import System.Environment (lookupEnv)
import System.Exit (exitWith, ExitCode(..))
import System.IO (hPutStrLn, stderr)
import System.Posix.Signals (installHandler, sigINT, Handler(..))

import Iidy.Aws.ClientReqToken (TokenInfo(..), TokenSource(..))
import Iidy.Aws.Config (createAwsEnv, createAwsEnvFromSettings)
import Iidy.Aws.CredentialSource (AwsSettings(..))
import Iidy.Aws.Timing (TimeProvider, systemTimeProvider, reliableTimeProvider)
import Iidy.Cfn.CommandMetadata (constructCommandMetadata, createFinalCommandSummary)
import Iidy.Cfn.Context (CfnContext, createContext, createContextFromEnv, ctxElapsedSeconds)
import Iidy.Cfn.Operations.Changeset
  ( createChangeset, executeChangeset, buildChangeSetCreationResult
  , generateDashedName, checkStackState, StackState(..)
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
import Iidy.Cfn.GlobalConfig (applyGlobalConfiguration)
import Iidy.Cfn.StackArgsLoader (loadStackArgs, LoadedStackArgs(..))
import Iidy.Cfn.Types (CfnOperation(..), StackArgs(..), emptyStackArgs, isReadOnlyOperation)
import Iidy.Cli
import Iidy.Cli.Parser (parseCliOpts)
import Iidy.Demo (runDemo)
import Iidy.Explain (explainErrors)
import Iidy.GetImport (runGetImport)
import Iidy.InitStackArgs (runInitStackArgs)
import Iidy.Output.Manager (mkOutputDispatch, renderOutput, cleanupOutputDispatch)
import Iidy.Output.Types (OutputData(..))
import Iidy.Params.Client (paramGet, paramSet, paramGetByPath, paramGetHistory, GetByPathResult(..))
import Iidy.Params.Review (paramReview)
import Iidy.Render (runRender)
import Iidy.Yaml.Imports.Types (RemoteImports(..))

-- | POSIX _exit(2) — terminates immediately without cleanup.
-- Used for signal handlers to avoid GHC's backtrace on exitWith.
foreign import ccall "unistd.h _exit" c_exit :: CInt -> IO ()

main :: IO ()
main = do
  -- Install SIGINT handler: _exit(130) avoids GHC backtrace on Ctrl-C
  _ <- installHandler sigINT (CatchOnce $ c_exit 130) Nothing
  -- Catch unhandled exceptions (missing file, AWS errors, etc.)
  -- and format them like Rust does, without GHC backtrace noise.
  (do cli <- parseCliOpts
      runCommand cli
    ) `catch` handleUncaughtException

-- | Format unhandled exceptions matching Rust's error output style.
-- Strips GHC backtrace noise and formats IO errors cleanly.
-- Amazonka ServiceErrors get the message extracted; other errors get best-effort formatting.
handleUncaughtException :: SomeException -> IO ()
handleUncaughtException e
  | Just ec <- fromException e = exitWith (ec :: ExitCode)
  | Just awsErr <- fromException e = do
      handleAwsError (awsErr :: Amazonka.Error)
      exitWith (ExitFailure 1)
  | Just ioe <- fromException e = do
      -- IO exceptions: format like Rust's "No such file or directory (os error 2)"
      let msg = displayException (ioe :: IOException)
      hPutStrLn stderr $ "ERROR: " <> firstLine msg
      hPutStrLn stderr "  \x2022 Check the AWS CloudFormation console for more details"
      exitWith (ExitFailure 1)
  | otherwise = do
      let msg = firstLine (displayException e)
      hPutStrLn stderr $ "ERROR: " <> msg
      hPutStrLn stderr "  \x2022 Check the AWS CloudFormation console for more details"
      exitWith (ExitFailure 1)
  where
    firstLine s = case lines s of
      (l:_) -> l
      []    -> s

-- | Format an Amazonka error with the service error message extracted.
handleAwsError :: Amazonka.Error -> IO ()
handleAwsError (Amazonka.ServiceError se) = do
  let Amazonka.ErrorCode code = se.code
      msg = maybe "" Amazonka.fromErrorMessage se.message
      errMsg = T.unpack (code <> ": " <> msg)
  hPutStrLn stderr $ "ERROR: " <> errMsg
  hPutStrLn stderr "  \x2022 Check the AWS CloudFormation console for more details"
handleAwsError err = do
  hPutStrLn stderr $ "ERROR: " <> firstLine' (displayException err)
  hPutStrLn stderr "  \x2022 Check the AWS CloudFormation console for more details"
  where
    firstLine' s = case lines s of
      (l:_) -> l
      []    -> s

------------------------------------------------------------------------
-- Command dispatch
------------------------------------------------------------------------

runCommand :: Cli -> IO ()
runCommand cli = case cliCommand cli of
  CmdRender args        -> do
      dispatch <- mkOutputDispatch (cliGlobalOpts cli)
      runRender (renderOutput dispatch) args (cliGlobalOpts cli) >>= exitCode
  CmdExplain codes      -> explainErrors codes

  -- CloudFormation operations with stack-args
  CmdCreateStack args   ->
    runCfnWithArgs cli OpCreateStack (csaArgsfile args) (csaStackName args)
      $ \remoteImports ctx sa fp env emit -> createStack ctx sa fp env emit remoteImports >>= handleEither

  CmdUpdateStack args   ->
    runCfnWithArgs cli OpUpdateStack (sfaArgsfile (usaBase args)) (sfaStackName (usaBase args))
      $ \remoteImports ctx sa fp env emit ->
          if usaChangeset args
            then updateStackWithChangeset ctx sa (usaYes args) fp env emit remoteImports >>= handleEither
            else updateStack ctx sa fp env emit remoteImports >>= handleEither

  CmdCreateOrUpdate args ->
    runCfnWithArgs cli OpCreateOrUpdate (sfaArgsfile (usaBase args)) (sfaStackName (usaBase args))
      $ \remoteImports ctx sa fp env emit -> createOrUpdate ctx sa (usaChangeset args) (usaYes args) fp env emit remoteImports >>= handleEither

  CmdEstimateCost args  ->
    runCfnWithArgs cli OpEstimateCost (sfaArgsfile args) (sfaStackName args)
      $ \remoteImports ctx sa fp env emit -> do
          result <- estimateCost ctx sa fp env emit remoteImports
          handleEither result

  CmdCreateChangeset args ->
    runCfnWithArgs cli OpCreateChangeset (ccsArgsfile args) (ccsStackName args)
      $ \remoteImports ctx sa fp env emit -> do
          -- Determine changeset name (user-provided or random)
          csName <- case ccsChangesetName args of
            Just name -> pure name
            Nothing   -> generateDashedName
          -- Check stack state to determine changeset type
          let stackName = saStackName sa
          state <- checkStackState ctx stackName
          let exists = case state of { StackNormal -> True; _ -> False }
          csEither <- createChangeset ctx sa csName exists fp env remoteImports
          case csEither of
            Left err -> do
              emit (OdRawOutput err)
              pure 1
            Right info -> do
              let csResult = buildChangeSetCreationResult info exists (ccsArgsfile args)
              emit (OdChangeSetResult csResult)
              pure 0

  CmdExecChangeset args -> do
      let stackName = maybe "" id (ecsStackName args)
      ctx <- createSimpleContext cli OpExecuteChangeset
      dispatch <- mkOutputDispatch (cliGlobalOpts cli)
      let emit = renderOutput dispatch
          env = goEnvironment (cliGlobalOpts cli)
      -- Emit CommandMetadata before operation
      meta <- constructCommandMetadata ctx (cliToAwsSettings cli) emptyStackArgs env Nothing
      emit (OdCommandMetadata meta)
      result <- executeChangeset ctx stackName (ecsChangesetName args) emit
        `finally` cleanupOutputDispatch dispatch
      case result of
        Left err -> dieTxt err
        Right rc -> do
          elapsed <- ctxElapsedSeconds ctx
          emit (createFinalCommandSummary (rc == 0) elapsed)
          exitCode rc

  -- Read-only CloudFormation operations
  CmdDescribeStack args -> do
      ctx <- createSimpleContext cli OpDescribeStack
      dispatch <- mkOutputDispatch (cliGlobalOpts cli)
      let env = goEnvironment (cliGlobalOpts cli)
          emit = renderOutput dispatch
      result <- describeStack ctx (daStackname args) (daEvents args) env emit
      case result of
        Left err -> dieTxt err
        Right () -> pure ()

  CmdWatchStack args -> do
      ctx <- createSimpleContext cli OpWatchStack
      dispatch <- mkOutputDispatch (cliGlobalOpts cli)
      result <- watchStack ctx (waStackname args) (waInactivityTimeout args) (renderOutput dispatch)
        `finally` cleanupOutputDispatch dispatch
      case result of
        Left err -> dieTxt err
        Right rc -> exitCode rc

  CmdDescribeStackDrift args -> do
      ctx <- createSimpleContext cli OpDescribeStackDrift
      dispatch <- mkOutputDispatch (cliGlobalOpts cli)
      result <- describeStackDrift ctx (drfStackname args) (drfDriftCache args) (renderOutput dispatch)
      case result of
        Left err -> dieTxt err
        Right () -> pure ()

  CmdDeleteStack args -> do
      ctx <- createSimpleContext cli OpDeleteStack
      dispatch <- mkOutputDispatch (cliGlobalOpts cli)
      let env = goEnvironment (cliGlobalOpts cli)
          emit = renderOutput dispatch
      -- Emit CommandMetadata before operation
      meta <- constructCommandMetadata ctx (cliToAwsSettings cli) emptyStackArgs env Nothing
      emit (OdCommandMetadata meta)
      result <- deleteStack ctx (delStackname args) (delYes args) env emit
        `finally` cleanupOutputDispatch dispatch
      case result of
        Left err -> dieTxt err
        Right rc -> do
          elapsed <- ctxElapsedSeconds ctx
          -- rc=0 is success, rc=130 is user declined (also success per Rust)
          emit (createFinalCommandSummary (rc == 0 || rc == 130) elapsed)
          exitCode rc

  CmdGetStackTemplate args -> do
      ctx <- createSimpleContext cli OpGetStackTemplate
      dispatch <- mkOutputDispatch (cliGlobalOpts cli)
      let emit = renderOutput dispatch
      result <- getStackTemplate ctx (gtaStackname args)
      case result of
        Left err  -> dieTxt err
        Right tpl -> emit (OdRawOutput (tpl <> "\n"))

  CmdListStacks args -> do
      ctx <- createSimpleContext cli OpListStacks
      dispatch <- mkOutputDispatch (cliGlobalOpts cli)
      let tagFilters = if null (laTagFilter args) then Nothing else Just (laTagFilter args)
          hasQuery = case laQuery args of { Just _ -> True; Nothing -> False }
      result <- listStacks ctx tagFilters (laTags args) hasQuery
      case result of
        Left err    -> dieTxt err
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
            Left err  -> dieTxt err
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
            Left err  -> dieTxt err
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
        <> T.unpack (gsiStackname args) <> "\""
      exitWith (ExitFailure 1)
  CmdTemplateApproval acmd -> case acmd of
    ApprovalRequest args ->
      runCfnWithArgs cli OpTemplateApprovalRequest (araArgsfile args) Nothing
        $ \remoteImports ctx sa fp env emit -> do
            result <- templateApprovalRequest ctx sa (araLintTemplate args) fp env emit remoteImports
            handleEither result
    ApprovalReview args -> do
      ctx <- createSimpleContext cli OpTemplateApprovalReview
      dispatch <- mkOutputDispatch (cliGlobalOpts cli)
      result <- templateApprovalReview ctx (arvUrl args) (arvContext args) (renderOutput dispatch)
      case result of
        Left err -> dieTxt err
        Right rc -> exitCode rc
  CmdGetImport args      -> do
      dispatch <- mkOutputDispatch (cliGlobalOpts cli)
      runGetImport (renderOutput dispatch) args (cliGlobalOpts cli) >>= exitCode
  CmdDemo args           ->
    let ri = if goRemoteImports (cliGlobalOpts cli) then AllowRemoteImports else BlockRemoteImports
    in runDemo (daDemoscript args) (daTimescaling args) (daMaskSecrets args) ri >>= exitCode
  CmdLintTemplate args   ->
    runCfnWithArgs cli OpLintTemplate (ltaArgsfile args) Nothing
      $ \remoteImports ctx sa fp env emit -> do
          result <- lintTemplate ctx sa fp env emit remoteImports
          handleEither result
  CmdConvertStackToIidy args -> do
      ctx <- createSimpleContext cli OpConvertStackToIidy
      result <- convertStackToIidy ctx
        (caStackname args)
        (caOutputDir args)
        (caMoveParamsToSsm args)
        (caSortkeys args)
        (caProject args)
      case result of
        Left err -> dieTxt err
        Right rc -> exitCode rc
  CmdInitStackArgs args  -> runInitStackArgs args >>= exitCode
  CmdCompletion mShell   -> do
      shellType <- case mShell of
        Just st -> pure st
        Nothing -> do
          mEnv <- lookupEnv "SHELL"
          pure $ case mEnv of
            Just s  -> detectShellType (reverse $ takeWhile (/= '/') (reverse s))
            Nothing -> ShellBash
      case shellType of
        ShellBash -> putStrLn bashCompletionScript
        ShellZsh  -> putStrLn zshCompletionScript
        ShellFish -> putStrLn fishCompletionScript

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Run a CFN operation that requires loading stack args from an argsfile.
-- Creates an output dispatch and passes an emitter to the action callback.
-- For write operations, emits CommandMetadata before and FinalCommandSummary after.
runCfnWithArgs
  :: Cli
  -> CfnOperation
  -> Text            -- ^ argsfile path
  -> Maybe Text      -- ^ stack name override from CLI
  -> (RemoteImports -> CfnContext -> StackArgs -> Maybe FilePath -> Text -> (OutputData -> IO ()) -> IO Int)
  -> IO ()
runCfnWithArgs cli operation argsfile stackNameOverride action = do
  let env = goEnvironment (cliGlobalOpts cli)
      cliAws = cliToAwsSettings cli
      argsfilePath = T.unpack argsfile
      remoteImports = if goRemoteImports (cliGlobalOpts cli) then AllowRemoteImports else BlockRemoteImports

  dispatch <- mkOutputDispatch (cliGlobalOpts cli)
  let emit = renderOutput dispatch

  result <- loadStackArgs argsfilePath env operation cliAws remoteImports Nothing
  case result of
    Left err -> dieTxt err
    Right (LoadedStackArgs sa mergedAws detectionCtx) -> do
      -- Create AWS env with merged settings
      (awsEnv, credStack) <- createAwsEnv detectionCtx mergedAws
      -- Apply global SSM configuration (silently ignored on error)
      sa'' <- applyGlobalConfiguration awsEnv sa
      let sa' = case stackNameOverride of
                  Just sn -> sa'' { saStackName = sn }
                  Nothing -> sa''
      token <- generateToken cli
      let tp = timeProviderForOperation operation
      ctx <- createContextFromEnv awsEnv credStack operation tp token

      -- Emit CommandMetadata for write operations (not lint/estimate-cost)
      if emitsCommandMetadata operation
        then do
          meta <- constructCommandMetadata ctx mergedAws sa' env stackNameOverride
          emit (OdCommandMetadata meta)
        else pure ()

      rc <- action remoteImports ctx sa' (Just argsfilePath) env emit
        `finally` cleanupOutputDispatch dispatch

      -- Emit FinalCommandSummary for write operations
      if emitsCommandMetadata operation
        then do
          elapsed <- ctxElapsedSeconds ctx
          emit (createFinalCommandSummary (rc == 0) elapsed)
        else pure ()

      exitCode rc

-- | Create a simple CfnContext for operations that don't load stack args
createSimpleContext :: Cli -> CfnOperation -> IO CfnContext
createSimpleContext cli operation = do
  let cliAws = cliToAwsSettings cli
  token <- generateToken cli
  createContext cliAws operation (timeProviderForOperation operation) token

-- | Select NTP-backed provider for write ops, system time for read-only.
timeProviderForOperation :: CfnOperation -> TimeProvider
timeProviderForOperation op
  | isReadOnlyOperation op = systemTimeProvider
  | otherwise              = reliableTimeProvider

-- | Convert CLI AWS options to AwsSettings
cliToAwsSettings :: Cli -> AwsSettings
cliToAwsSettings cli = AwsSettings
  { awsProfile = aoProfile (cliAwsOpts cli)
  , awsRegion = aoRegion (cliAwsOpts cli)
  , awsAssumeRoleArn = aoAssumeRoleArn (cliAwsOpts cli)
  }

-- | Generate a client request token (user-provided or auto-generated UUID)
generateToken :: Cli -> IO TokenInfo
generateToken cli = case aoClientRequestToken (cliAwsOpts cli) of
  Just t  -> pure TokenInfo
    { tiValue = t
    , tiSource = UserProvided
    , tiOperationId = t
    }
  Nothing -> do
    uuid <- nextRandom
    let val = T.pack (UUID.toString uuid)
    pure TokenInfo
      { tiValue = val
      , tiSource = AutoGenerated
      , tiOperationId = val
      }

-- | Operations that emit CommandMetadata and FinalCommandSummary.
-- Write operations minus lint and estimate-cost.
emitsCommandMetadata :: CfnOperation -> Bool
emitsCommandMetadata = \case
  OpCreateStack             -> True
  OpUpdateStack             -> True
  OpCreateOrUpdate          -> True
  OpCreateChangeset         -> True
  OpTemplateApprovalRequest -> True
  OpTemplateApprovalReview  -> True
  _                         -> False

-- | Handle Either Text Int result
handleEither :: Either Text Int -> IO Int
handleEither (Left err) = dieTxt err
handleEither (Right rc) = pure rc

-- | Exit with given code
exitCode :: Int -> IO ()
exitCode 0 = exitWith ExitSuccess
exitCode n = exitWith (ExitFailure n)

-- | Detect shell type from a shell name string.
-- Falls back to ShellBash for unknown values.
detectShellType :: String -> ShellType
detectShellType "zsh"  = ShellZsh
detectShellType "fish" = ShellFish
detectShellType _      = ShellBash

-- | Print error to stderr and exit with code 1
dieTxt :: Text -> IO a
dieTxt msg = do
  TIO.hPutStrLn stderr $ "iidy-hs: " <> msg
  exitWith (ExitFailure 1)


------------------------------------------------------------------------
-- Shell completion scripts
------------------------------------------------------------------------

bashCompletionScript :: String
bashCompletionScript = unlines
  [ "_iidy_hs()"
  , "{"
  , "    local CMDLINE"
  , "    local IFS=$'\\n'"
  , "    CMDLINE=(--bash-completion-index $COMP_CWORD)"
  , ""
  , "    for arg in ${COMP_WORDS[@]}; do"
  , "        CMDLINE=(${CMDLINE[@]} --bash-completion-word $arg)"
  , "    done"
  , ""
  , "    COMPREPLY=( $(iidy-hs \"${CMDLINE[@]}\") )"
  , "}"
  , ""
  , "complete -o filenames -F _iidy_hs iidy-hs"
  ]

zshCompletionScript :: String
zshCompletionScript = unlines
  [ "#compdef iidy-hs"
  , ""
  , "_iidy_hs()"
  , "{"
  , "    local CMDLINE"
  , "    local IFS=$'\\n'"
  , "    CMDLINE=(--bash-completion-index $((CURRENT-1)))"
  , ""
  , "    for arg in ${words[@]}; do"
  , "        CMDLINE=(${CMDLINE[@]} --bash-completion-word $arg)"
  , "    done"
  , ""
  , "    local completions"
  , "    completions=($(iidy-hs \"${CMDLINE[@]}\"))"
  , ""
  , "    compadd -a completions"
  , "}"
  , ""
  , "compdef _iidy_hs iidy-hs"
  ]

fishCompletionScript :: String
fishCompletionScript = unlines
  [ "function _iidy_hs"
  , "    set -l cl (commandline --tokenize --current-process)"
  , "    set -l cn (count $cl)"
  , "    set -l tmpline --bash-completion-index $cn"
  , "    for arg in $cl"
  , "        set tmpline $tmpline --bash-completion-word $arg"
  , "    end"
  , "    for opt in (iidy-hs $tmpline)"
  , "        echo -E \"$opt\""
  , "    end"
  , "end"
  , ""
  , "complete -c iidy-hs -f -a '(_iidy_hs)'"
  ]
