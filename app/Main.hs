module Main (main) where

import Control.Exception (SomeException, IOException, catch, fromException, displayException)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.UUID.V4 (nextRandom)
import qualified Data.UUID as UUID
import Foreign.C.Types (CInt(..))
import System.Exit (exitWith, ExitCode(..))
import System.IO (hPutStrLn, stderr)
import System.Posix.Signals (installHandler, sigINT, Handler(..))

import Iidy.Aws.ClientReqToken (TokenInfo(..), TokenSource(..))
import Iidy.Aws.Config (createAwsEnv, createAwsEnvFromSettings)
import Iidy.Aws.CredentialSource (AwsSettings(..))
import Iidy.Aws.Timing (TimeProvider, systemTimeProvider, reliableTimeProvider)
import Iidy.Cfn.Context (CfnContext, createContext, createContextFromEnv)
import Iidy.Cfn.Operations.Changeset (createChangeset, executeChangeset)
import Iidy.Cfn.Operations.ConvertStack (convertStackToIidy)
import Iidy.Cfn.Operations.CreateOrUpdate (createOrUpdate)
import Iidy.Cfn.Operations.CreateStack (createStack)
import Iidy.Cfn.Operations.DeleteStack (deleteStack)
import Iidy.Cfn.Operations.DescribeStack (describeStack, convertEvent)
import Iidy.Cfn.Operations.DescribeStackDrift (detectStackDrift)
import Iidy.Cfn.Operations.EstimateCost (estimateCost)
import Iidy.Cfn.Operations.GetStackTemplate (getStackTemplate)
import Iidy.Cfn.Operations.LintTemplate (lintTemplate)
import Iidy.Cfn.Operations.ListStacks (listStacks)
import Iidy.Cfn.Operations.TemplateApproval (templateApprovalRequest, templateApprovalReview)
import Iidy.Cfn.Operations.UpdateStack (updateStack)
import Iidy.Cfn.Operations.WatchStack (watchStack)
import Iidy.Cfn.StackArgsLoader (loadStackArgs, LoadedStackArgs(..))
import Iidy.Cfn.Types (CfnOperation(..), StackArgs(..), isReadOnlyOperation)
import Iidy.Cli
import Iidy.Cli.Parser (parseCliOpts)
import Iidy.Demo (runDemo)
import Iidy.Explain (explainErrors)
import Iidy.GetImport (runGetImport)
import Iidy.InitStackArgs (runInitStackArgs)
import Iidy.Output.Manager (mkOutputDispatch, renderOutput)
import Iidy.Output.Types (OutputData(..), StackEventWithTiming(..))
import Iidy.Params.Client (paramGet, paramSet, paramGetByPath, paramGetHistory)
import Iidy.Params.Review (paramReview)
import Iidy.Render (runRender)

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
handleUncaughtException :: SomeException -> IO ()
handleUncaughtException e
  | Just ec <- fromException e = exitWith (ec :: ExitCode)
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

------------------------------------------------------------------------
-- Command dispatch
------------------------------------------------------------------------

runCommand :: Cli -> IO ()
runCommand cli = case cliCommand cli of
  CmdRender args        -> runRender args (cliGlobalOpts cli) >>= exitCode
  CmdExplain codes      -> explainErrors codes

  -- CloudFormation operations with stack-args
  CmdCreateStack args   ->
    runCfnWithArgs cli OpCreateStack (csaArgsfile args) (csaStackName args)
      $ \ctx sa fp env -> createStack ctx sa fp env >>= handleEither

  CmdUpdateStack args   ->
    runCfnWithArgs cli OpUpdateStack (sfaArgsfile (usaBase args)) (sfaStackName (usaBase args))
      $ \ctx sa fp env -> updateStack ctx sa fp env >>= handleEither

  CmdCreateOrUpdate args ->
    runCfnWithArgs cli OpCreateOrUpdate (sfaArgsfile (usaBase args)) (sfaStackName (usaBase args))
      $ \ctx sa fp env -> createOrUpdate ctx sa (usaChangeset args) fp env >>= handleEither

  CmdEstimateCost args  ->
    runCfnWithArgs cli OpEstimateCost (sfaArgsfile args) (sfaStackName args)
      $ \ctx sa fp env -> do
          result <- estimateCost ctx sa fp env
          case result of
            Left err  -> dieTxt err
            Right url -> TIO.putStrLn url >> pure 0

  CmdCreateChangeset args ->
    runCfnWithArgs cli OpCreateChangeset (ccsArgsfile args) (ccsStackName args)
      $ \ctx sa fp env -> do
          let csName = maybe "changeset" id (ccsChangesetName args)
          result <- createChangeset ctx sa csName True fp env
          case result of
            Left err -> dieTxt err
            Right _  -> pure 0

  CmdExecChangeset args -> do
      let stackName = maybe "" id (ecsStackName args)
      ctx <- createSimpleContext cli OpExecuteChangeset
      result <- executeChangeset ctx stackName (ecsChangesetName args)
      case result of
        Left err -> dieTxt err
        Right rc -> exitCode rc

  -- Read-only CloudFormation operations
  CmdDescribeStack args -> do
      ctx <- createSimpleContext cli OpDescribeStack
      dispatch <- mkOutputDispatch (cliGlobalOpts cli)
      result <- describeStack ctx (daStackname args) (daEvents args)
      case result of
        Left err    -> dieTxt err
        Right datas -> mapM_ (renderOutput dispatch) datas

  CmdWatchStack args -> do
      ctx <- createSimpleContext cli OpWatchStack
      dispatch <- mkOutputDispatch (cliGlobalOpts cli)
      let onEvents cfnEvents = do
            let converted = map (\e -> StackEventWithTiming (convertEvent e) Nothing) cfnEvents
            renderOutput dispatch (OdNewStackEvents converted)
      result <- watchStack ctx (waStackname args) (waInactivityTimeout args) onEvents
      case result of
        Left err -> dieTxt err
        Right rc -> exitCode rc

  CmdDescribeStackDrift args -> do
      ctx <- createSimpleContext cli OpDescribeStackDrift
      result <- detectStackDrift ctx (drfStackname args)
      case result of
        Left err   -> dieTxt err
        Right did' -> TIO.putStrLn $ "Drift detection initiated: " <> did'

  CmdDeleteStack args -> do
      ctx <- createSimpleContext cli OpDeleteStack
      result <- deleteStack ctx (delStackname args) (delYes args)
      case result of
        Left err -> dieTxt err
        Right rc -> exitCode rc

  CmdGetStackTemplate args -> do
      ctx <- createSimpleContext cli OpGetStackTemplate
      result <- getStackTemplate ctx (gtaStackname args)
      case result of
        Left err  -> dieTxt err
        Right tpl -> TIO.putStrLn tpl

  CmdListStacks args -> do
      ctx <- createSimpleContext cli OpListStacks
      dispatch <- mkOutputDispatch (cliGlobalOpts cli)
      let tagFilters = if null (laTagFilter args) then Nothing else Just (laTagFilter args)
      result <- listStacks ctx tagFilters
      case result of
        Left err    -> dieTxt err
        Right datas -> mapM_ (renderOutput dispatch) datas

  -- SSM Parameter commands
  CmdParam pcmd -> do
      (env, _creds) <- createAwsEnvFromSettings (cliToAwsSettings cli)
      case pcmd of
        ParamGet args -> do
          result <- paramGet env args
          case result of
            Left err  -> dieTxt err
            Right val -> TIO.putStrLn val
        ParamSet args -> do
          result <- paramSet env args
          case result of
            Left err -> dieTxt err
            Right () -> TIO.putStrLn "Parameter set successfully."
        ParamGetByPath args -> do
          result <- paramGetByPath env args
          case result of
            Left err   -> dieTxt err
            Right vals -> mapM_ TIO.putStrLn vals
        ParamGetHistory args -> do
          result <- paramGetHistory env args
          case result of
            Left err   -> dieTxt err
            Right vals -> mapM_ TIO.putStrLn vals
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
        $ \ctx sa fp env -> do
            result <- templateApprovalRequest ctx sa (araLintTemplate args) fp env
            handleEither result
    ApprovalReview args -> do
      ctx <- createSimpleContext cli OpTemplateApprovalReview
      result <- templateApprovalReview ctx (arvUrl args) (arvContext args)
      case result of
        Left err -> dieTxt err
        Right rc -> exitCode rc
  CmdGetImport args      -> runGetImport args >>= exitCode
  CmdDemo args           -> runDemo (daDemoscript args) (daTimescaling args) (daMaskSecrets args) >>= exitCode
  CmdLintTemplate args   ->
    runCfnWithArgs cli OpLintTemplate (ltaArgsfile args) Nothing
      $ \ctx sa fp env -> do
          result <- lintTemplate ctx sa fp env
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
  CmdCompletion mShell   ->
      case maybe "bash" T.unpack mShell of
        "bash" -> putStrLn bashCompletionScript
        "zsh"  -> putStrLn zshCompletionScript
        "fish" -> putStrLn fishCompletionScript
        other  -> hPutStrLn stderr $ "Unsupported shell: " <> other <> ". Use bash, zsh, or fish."

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Run a CFN operation that requires loading stack args from an argsfile.
runCfnWithArgs
  :: Cli
  -> CfnOperation
  -> Text            -- ^ argsfile path
  -> Maybe Text      -- ^ stack name override from CLI
  -> (CfnContext -> StackArgs -> Maybe FilePath -> Text -> IO Int)
  -> IO ()
runCfnWithArgs cli operation argsfile stackNameOverride action = do
  let env = goEnvironment (cliGlobalOpts cli)
      cliAws = cliToAwsSettings cli
      argsfilePath = T.unpack argsfile

  result <- loadStackArgs argsfilePath env operation cliAws
  case result of
    Left err -> dieTxt err
    Right (LoadedStackArgs sa mergedAws detectionCtx) -> do
      let sa' = case stackNameOverride of
                  Just sn -> sa { saStackName = Just sn }
                  Nothing -> sa
      -- Create AWS env with merged settings
      (awsEnv, credStack) <- createAwsEnv detectionCtx mergedAws
      token <- generateToken cli
      let tp = timeProviderForOperation operation
      ctx <- createContextFromEnv awsEnv credStack operation tp token
      rc <- action ctx sa' (Just argsfilePath) env
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

-- | Handle Either Text Int result
handleEither :: Either Text Int -> IO Int
handleEither (Left err) = dieTxt err
handleEither (Right rc) = pure rc

-- | Exit with given code
exitCode :: Int -> IO ()
exitCode 0 = exitWith ExitSuccess
exitCode n = exitWith (ExitFailure n)

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
