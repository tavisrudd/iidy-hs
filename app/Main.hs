module Main (main) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.UUID.V4 (nextRandom)
import qualified Data.UUID as UUID
import System.Exit (exitWith, ExitCode(..))
import System.IO (hPutStrLn, stderr)

import Iidy.Aws.ClientReqToken (TokenInfo(..), TokenSource(..))
import Iidy.Aws.Config (createAwsEnv, createAwsEnvFromSettings)
import Iidy.Aws.CredentialSource (AwsSettings(..))
import Iidy.Aws.Timing (systemTimeProvider)
import Iidy.Cfn.Context (CfnContext, createContext, createContextFromEnv)
import Iidy.Cfn.Operations.Changeset (createChangeset, executeChangeset)
import Iidy.Cfn.Operations.CreateOrUpdate (createOrUpdate)
import Iidy.Cfn.Operations.CreateStack (createStack)
import Iidy.Cfn.Operations.DeleteStack (deleteStack)
import Iidy.Cfn.Operations.DescribeStack (describeStack)
import Iidy.Cfn.Operations.DescribeStackDrift (detectStackDrift)
import Iidy.Cfn.Operations.EstimateCost (estimateCost)
import Iidy.Cfn.Operations.GetStackTemplate (getStackTemplate)
import Iidy.Cfn.Operations.ListStacks (listStacks)
import Iidy.Cfn.Operations.UpdateStack (updateStack)
import Iidy.Cfn.Operations.WatchStack (watchStack)
import Iidy.Cfn.StackArgsLoader (loadStackArgs, LoadedStackArgs(..))
import Iidy.Cfn.Types (CfnOperation(..), StackArgs(..))
import Iidy.Cli
import Iidy.Cli.Parser (parseCliOpts)
import Iidy.Explain (explainErrors)
import Iidy.GetImport (runGetImport)
import Iidy.Output.Types (OutputData)
import Iidy.Params.Client (paramGet, paramSet, paramGetByPath, paramGetHistory)
import Iidy.Render (runRender)

main :: IO ()
main = do
  cli <- parseCliOpts
  runCommand cli

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
      result <- describeStack ctx (daStackname args) (daEvents args)
      case result of
        Left err    -> dieTxt err
        Right datas -> mapM_ (TIO.putStrLn . showOutputData) datas

  CmdWatchStack args -> do
      ctx <- createSimpleContext cli OpWatchStack
      result <- watchStack ctx (waStackname args) (waInactivityTimeout args) TIO.putStrLn
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
      let tagFilters = if null (laTagFilter args) then Nothing else Just (laTagFilter args)
      result <- listStacks ctx tagFilters
      case result of
        Left err    -> dieTxt err
        Right datas -> mapM_ (TIO.putStrLn . showOutputData) datas

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
        ParamReview _args ->
          notImplemented "param review"

  -- Not yet implemented
  CmdGetStackInstances _ -> notImplemented "get-stack-instances"
  CmdTemplateApproval _  -> notImplemented "template-approval"
  CmdGetImport args      -> runGetImport args >>= exitCode
  CmdDemo _              -> notImplemented "demo"
  CmdLintTemplate _      -> notImplemented "lint-template"
  CmdConvertStackToIidy _ -> notImplemented "convert-stack-to-iidy"
  CmdInitStackArgs _     -> notImplemented "init-stack-args"
  CmdCompletion mShell   -> do
      let shellName = maybe "bash" T.unpack mShell
      hPutStrLn stderr $
        "Shell completion is available via optparse-applicative's built-in support.\n"
        <> "Run: source <(iidy-hs --bash-completion-script $(which iidy-hs))\n"
        <> "For " <> shellName <> " completion."

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
      ctx <- createContextFromEnv awsEnv credStack operation systemTimeProvider token
      rc <- action ctx sa' (Just argsfilePath) env
      exitCode rc

-- | Create a simple CfnContext for operations that don't load stack args
createSimpleContext :: Cli -> CfnOperation -> IO CfnContext
createSimpleContext cli operation = do
  let cliAws = cliToAwsSettings cli
  token <- generateToken cli
  createContext cliAws operation systemTimeProvider token

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

notImplemented :: String -> IO ()
notImplemented cmd = do
  hPutStrLn stderr $ "iidy-hs: command '" <> cmd <> "' not yet implemented"
  exitWith (ExitFailure 1)

-- | Basic display for OutputData (used for describe/list operations)
showOutputData :: OutputData -> Text
showOutputData = T.pack . show
