module Iidy.Cli.Parser
  ( parseCliOpts
  , cliParserInfo  -- exported for testing
  ) where

import Control.Monad (when)
import Data.Char (toLower)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Version (showVersion)
import qualified Paths_iidy_hs as Paths
import qualified System.Environment
import qualified System.Exit
import Options.Applicative
import Options.Applicative.Help.Pretty (Doc, hardline, pretty)

import Iidy.Cli
import Iidy.Cli.Help
import Iidy.Types (ColorChoice(..), OutputMode(..), Theme(..), YamlSpec(..))

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

parseCliOpts :: IO Cli
parseCliOpts = do
  args <- System.Environment.getArgs
  when (shouldShowTopLevelHelp args) $ do
    renderTopLevelHelp
    System.Exit.exitSuccess
  let parserPrefs = prefs mempty
  case execParserPure parserPrefs cliParserInfo args of
    Success cli -> pure cli
    Failure failure -> do
      let (msg, _) = renderFailure failure "iidy-hs"
          (parserHelp, exitCode, _) = execFailure failure "iidy-hs"
      case exitCode of
        System.Exit.ExitSuccess -> do
          renderHelpForArgs args msg
          System.Exit.exitSuccess
        _ -> do
          renderParserFailure parserHelp
          System.Exit.exitWith exitCode
    CompletionInvoked compl -> do
      msg <- execCompletion compl "iidy-hs"
      putStr msg
      System.Exit.exitSuccess

cliParserInfo :: ParserInfo Cli
cliParserInfo = info (cliParser <**> helper <**> versionOption)
  ( fullDesc
  <> progDesc "CloudFormation with Confidence"
  <> header "iidy-hs - Is it done yet? CloudFormation preprocessor and deployer"
  <> footerDoc (Just statusCodesDoc)
  )

versionOption :: Parser (a -> a)
versionOption =
  infoOption ("iidy-hs " <> showVersion Paths.version)
    ( long "version"
   <> short 'V'
   <> help "Print version"
    )

statusCodesDoc :: Doc
statusCodesDoc =
  pretty ("Status Codes:" :: String) <> hardline
  <> pretty ("  Success (0)       Command successfully completed" :: String) <> hardline
  <> pretty ("  Error (1)         An error was encountered while executing command" :: String) <> hardline
  <> pretty ("  Cancelled (130)   User responded 'No' to iidy prompt or interrupt (CTRL-C) was received" :: String)

cliParser :: Parser Cli
cliParser = Cli
  <$> globalOptsParser
  <*> awsOptsParser
  <*> commandsParser

------------------------------------------------------------------------
-- Global options
------------------------------------------------------------------------

globalOptsParser :: Parser GlobalOpts
globalOptsParser = GlobalOpts
  <$> option textReader
      ( long "environment"
      <> short 'e'
      <> value "development"
      <> metavar "ENV"
      <> help "Used to load environment based settings: AWS Profile, Region, etc."
      )
  <*> option colorChoiceReader
      ( long "color"
      <> value ColorAuto
      <> metavar "WHEN"
      <> help "Whether to color output using ANSI escape codes (auto|always|never)"
      )
  <*> option themeReader
      ( long "theme"
      <> value ThemeAuto
      <> metavar "THEME"
      <> help "Color theme to use for output (auto|light|dark|high-contrast)"
      )
  <*> optional (option outputModeReader
      ( long "output-mode"
      <> metavar "MODE"
      <> help "Output mode for console display (plain|interactive|json)"
      ))
  <*> switch
      ( long "debug"
      <> help "Log debug information to stderr."
      )
  <*> switch
      ( long "log-full-error"
      <> help "Log full error information to stderr."
      )

------------------------------------------------------------------------
-- AWS options
------------------------------------------------------------------------

awsOptsParser :: Parser AwsOpts
awsOptsParser = AwsOpts
  <$> optional (option textReader
      ( long "region"
      <> metavar "REGION"
      <> help "AWS region. Can also be set via --environment & stack-args.yaml:Region."
      ))
  <*> optional (option textReader
      ( long "profile"
      <> metavar "PROFILE"
      <> help "AWS profile. Can also be set via --environment & stack-args.yaml:Profile."
      ))
  <*> optional (option textReader
      ( long "assume-role-arn"
      <> metavar "ARN"
      <> help "AWS role ARN to assume. Can also be set via --environment & stack-args.yaml:AssumeRoleArn."
      ))
  <*> optional (option textReader
      ( long "client-request-token"
      <> metavar "TOKEN"
      <> help "A unique, case-sensitive string of up to 64 ASCII characters used to ensure idempotent retries."
      ))

------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------

commandsParser :: Parser Commands
commandsParser = visibleCommands <|> hiddenCommands

visibleCommands :: Parser Commands
visibleCommands = subparser
  ( command "create-stack"
      (info (CmdCreateStack <$> createStackArgsParser <**> helper)
            (progDesc "create a cfn stack based on stack-args.yaml"))
  <> command "update-stack"
      (info (CmdUpdateStack <$> updateStackArgsParser <**> helper)
            (progDesc "update a cfn stack based on stack-args.yaml"))
  <> command "create-or-update"
      (info (CmdCreateOrUpdate <$> updateStackArgsParser <**> helper)
            (progDesc "create or update a cfn stack based on stack-args.yaml"))
  <> command "estimate-cost"
      (info (CmdEstimateCost <$> stackFileArgsParser <**> helper)
            (progDesc "estimate aws costs based on stack-args.yaml"))
  <> command "create-changeset"
      (info (CmdCreateChangeset <$> createChangeSetArgsParser <**> helper)
            (progDesc "create a cfn changeset based on stack-args.yaml"))
  <> command "exec-changeset"
      (info (CmdExecChangeset <$> execChangeSetArgsParser <**> helper)
            (progDesc "execute a cfn changeset based on stack-args.yaml"))
  <> command "describe-stack"
      (info (CmdDescribeStack <$> describeArgsParser <**> helper)
            (progDesc "describe a stack"))
  <> command "watch-stack"
      (info (CmdWatchStack <$> watchArgsParser <**> helper)
            (progDesc "watch a stack that is already being created or updated"))
  <> command "describe-stack-drift"
      (info (CmdDescribeStackDrift <$> driftArgsParser <**> helper)
            (progDesc "describe stack drift"))
  <> command "delete-stack"
      (info (CmdDeleteStack <$> deleteArgsParser <**> helper)
            (progDesc "delete a stack (after confirmation)"))
  <> command "get-stack-template"
      (info (CmdGetStackTemplate <$> getTemplateArgsParser <**> helper)
            (progDesc "download the template of a live stack"))
  <> command "list-stacks"
      (info (CmdListStacks <$> listArgsParser <**> helper)
            (progDesc "list all stacks within a region"))
  <> command "param"
      (info (CmdParam <$> paramCommandsParser <**> helper)
            (progDesc "sub commands for working with AWS SSM Parameter Store"))
  <> command "template-approval"
      (info (CmdTemplateApproval <$> approvalCommandsParser <**> helper)
            (progDesc "sub commands for template approval"))
  <> command "render"
      (info (CmdRender <$> renderArgsParser <**> helper)
            (progDesc "pre-process and render yaml template"))
  <> command "get-import"
      (info (CmdGetImport <$> getImportArgsParser <**> helper)
            (progDesc "retrieve and print an $import value directly"))
  <> command "demo"
      (info (CmdDemo <$> demoArgsParser <**> helper)
            (progDesc "run a demo script"))
  <> command "lint-template"
      (info (CmdLintTemplate <$> lintTemplateArgsParser <**> helper)
            (progDesc "lint a CloudFormation template"))
  <> command "convert-stack-to-iidy"
      (info (CmdConvertStackToIidy <$> convertArgsParser <**> helper)
            (progDesc "create an iidy project directory from an existing CFN stack"))
  <> command "init-stack-args"
      (info (CmdInitStackArgs <$> initStackArgsParser <**> helper)
            (progDesc "initialize stack-args.yaml and cfn-template.yaml"))
  <> command "completion"
      (info (CmdCompletion <$> optional (argument shellTypeReader
            ( metavar "SHELL"
            <> help "Shell name (bash|zsh|fish)")) <**> helper)
            (progDesc "generate shell completion script"))
  <> command "explain"
      (info (CmdExplain <$> many (argument textReader (metavar "CODE...")) <**> helper)
            (progDesc "explain error codes"))
  )

-- | Hidden/removed commands — still parseable but not shown in help
hiddenCommands :: Parser Commands
hiddenCommands = subparser
  ( command "get-stack-instances"
      (info (CmdGetStackInstances <$> getStackInstancesArgsParser <**> helper)
            (progDesc "list the ec2 instances of a live stack [removed]"))
  <> internal
  )

------------------------------------------------------------------------
-- Param sub-commands
------------------------------------------------------------------------

paramCommandsParser :: Parser ParamCommands
paramCommandsParser = subparser
  ( command "set"
      (info (ParamSet <$> paramSetArgsParser <**> helper)
            (progDesc "set a parameter value"))
  <> command "review"
      (info (ParamReview <$> paramPathArgParser <**> helper)
            (progDesc "review a pending change"))
  <> command "get"
      (info (ParamGet <$> paramGetArgsParser <**> helper)
            (progDesc "get a parameter value"))
  <> command "get-by-path"
      (info (ParamGetByPath <$> paramGetByPathArgsParser <**> helper)
            (progDesc "get parameters by path"))
  <> command "get-history"
      (info (ParamGetHistory <$> paramGetArgsParser <**> helper)
            (progDesc "get a parameter's history"))
  )

------------------------------------------------------------------------
-- Approval sub-commands
------------------------------------------------------------------------

approvalCommandsParser :: Parser ApprovalCommands
approvalCommandsParser = subparser
  ( command "request"
      (info (ApprovalRequest <$> approvalRequestArgsParser <**> helper)
            (progDesc "request template approval"))
  <> command "review"
      (info (ApprovalReview <$> approvalReviewArgsParser <**> helper)
            (progDesc "review pending template approval request"))
  )

------------------------------------------------------------------------
-- Arg parsers
------------------------------------------------------------------------

stackFileArgsParser :: Parser StackFileArgs
stackFileArgsParser = StackFileArgs
  <$> argument textReader (metavar "ARGSFILE" <> help "Path to stack-args.yaml")
  <*> optional (option textReader
      ( long "stack-name"
      <> metavar "NAME"
      <> help "Override stack name from stack-args.yaml"
      ))

createStackArgsParser :: Parser CreateStackArgs
createStackArgsParser = CreateStackArgs
  <$> argument textReader (metavar "ARGSFILE" <> help "Path to stack-args.yaml")
  <*> optional (option textReader
      ( long "stack-name"
      <> metavar "NAME"
      <> help "Override stack name from stack-args.yaml"
      ))

updateStackArgsParser :: Parser UpdateStackArgs
updateStackArgsParser = UpdateStackArgs
  <$> stackFileArgsParser
  <*> optional (option auto
      ( long "lint-template"
      <> metavar "BOOL"
      <> help "Whether to lint the template before updating"
      ))
  <*> switch (long "changeset" <> help "Use a changeset for the update")
  <*> switch (long "yes" <> help "Skip confirmation prompt")
  <*> flag True False (long "no-diff" <> help "Don't show diff before updating")
  <*> optional (option textReader
      ( long "stack-policy-during-update"
      <> metavar "POLICY"
      <> help "Stack policy to apply during the update"
      ))

createChangeSetArgsParser :: Parser CreateChangeSetArgs
createChangeSetArgsParser = CreateChangeSetArgs
  <$> argument textReader (metavar "ARGSFILE" <> help "Path to stack-args.yaml")
  <*> optional (argument textReader (metavar "CHANGESET_NAME" <> help "Name for the changeset"))
  <*> switch (long "watch" <> help "Watch the changeset after creation")
  <*> option auto
      ( long "watch-inactivity-timeout"
      <> value 180
      <> metavar "SECONDS"
      <> help "Inactivity timeout for watch mode in seconds (default: 180)"
      )
  <*> optional (option textReader
      ( long "description"
      <> metavar "DESC"
      <> help "Description for the changeset"
      ))
  <*> optional (option textReader
      ( long "stack-name"
      <> metavar "NAME"
      <> help "Override stack name from stack-args.yaml"
      ))

execChangeSetArgsParser :: Parser ExecChangeSetArgs
execChangeSetArgsParser = ExecChangeSetArgs
  <$> argument textReader (metavar "ARGSFILE" <> help "Path to stack-args.yaml")
  <*> argument textReader (metavar "CHANGESET_NAME" <> help "Name of the changeset to execute")
  <*> optional (option textReader
      ( long "stack-name"
      <> metavar "NAME"
      <> help "Override stack name from stack-args.yaml"
      ))

describeArgsParser :: Parser DescribeArgs
describeArgsParser = DescribeArgs
  <$> argument textReader (metavar "STACKNAME" <> help "Name of the stack to describe")
  <*> option auto
      ( long "events"
      <> value 50
      <> metavar "N"
      <> help "Number of events to display (default: 50)"
      )
  <*> optional (option textReader
      ( long "query"
      <> metavar "JMESPATH"
      <> help "JMESPath query to filter output"
      ))

watchArgsParser :: Parser WatchArgs
watchArgsParser = WatchArgs
  <$> argument textReader (metavar "STACKNAME" <> help "Name of the stack to watch")
  <*> option auto
      ( long "inactivity-timeout"
      <> value 180
      <> metavar "SECONDS"
      <> help "Inactivity timeout in seconds (default: 180)"
      )

driftArgsParser :: Parser DriftArgs
driftArgsParser = DriftArgs
  <$> argument textReader (metavar "STACKNAME" <> help "Name of the stack to check drift on")
  <*> option auto
      ( long "drift-cache"
      <> value 300
      <> metavar "SECONDS"
      <> help "Cache duration for drift results in seconds (default: 300)"
      )

deleteArgsParser :: Parser DeleteArgs
deleteArgsParser = DeleteArgs
  <$> argument textReader (metavar "STACKNAME" <> help "Name of the stack to delete")
  <*> optional (option textReader
      ( long "role-arn"
      <> metavar "ARN"
      <> help "IAM role ARN to use for deletion"
      ))
  <*> many (option textReader
      ( long "retain-resources"
      <> metavar "RESOURCE"
      <> help "Logical resource IDs to retain after deletion"
      ))
  <*> switch (long "yes" <> help "Skip confirmation prompt")
  <*> switch (long "fail-if-absent" <> help "Exit with error if stack does not exist")

getTemplateArgsParser :: Parser GetTemplateArgs
getTemplateArgsParser = GetTemplateArgs
  <$> argument textReader (metavar "STACKNAME" <> help "Name of the stack")
  <*> option templateFormatReader
      ( long "format"
      <> value FormatOriginal
      <> metavar "FORMAT"
      <> help "Output format: json|yaml|original (default: original)"
      )
  <*> option templateStageReader
      ( long "stage"
      <> value StageOriginal
      <> metavar "STAGE"
      <> help "Template stage: original|processed (default: original)"
      )

getStackInstancesArgsParser :: Parser GetStackInstancesArgs
getStackInstancesArgsParser = GetStackInstancesArgs
  <$> argument textReader (metavar "STACKNAME" <> help "Name of the stack")
  <*> switch (long "short" <> help "Show only DNS names/IP addresses")

listArgsParser :: Parser ListArgs
listArgsParser = ListArgs
  <$> many (option textReader
      ( long "tag-filter"
      <> metavar "TAG=VALUE"
      <> help "Filter stacks by tag (can be repeated)"
      ))
  <*> optional (option textReader
      ( long "jmespath-filter"
      <> metavar "EXPR"
      <> help "JMESPath filter expression"
      ))
  <*> optional (option textReader
      ( long "query"
      <> metavar "JMESPATH"
      <> help "JMESPath query to filter output"
      ))
  <*> switch (long "tags" <> help "Show tags in output")
  <*> optional (option textReader
      ( long "columns"
      <> metavar "COLS"
      <> help "Custom columns to display (comma-separated)"
      ))

paramSetArgsParser :: Parser ParamSetArgs
paramSetArgsParser = ParamSetArgs
  <$> argument textReader (metavar "PATH" <> help "SSM parameter path")
  <*> argument textReader (metavar "VALUE" <> help "Parameter value")
  <*> optional (option textReader
      ( long "message"
      <> metavar "MSG"
      <> help "Description message for the parameter"
      ))
  <*> switch (long "overwrite" <> help "Overwrite existing parameter")
  <*> switch (long "with-approval" <> help "Require approval before setting")
  <*> option paramTypeReader
      ( long "type"
      <> value ParamSecureString
      <> metavar "TYPE"
      <> help "Parameter type: String|StringList|SecureString (default: SecureString)"
      )

paramPathArgParser :: Parser ParamPathArg
paramPathArgParser = ParamPathArg
  <$> argument textReader (metavar "PATH" <> help "SSM parameter path")

paramGetArgsParser :: Parser ParamGetArgs
paramGetArgsParser = ParamGetArgs
  <$> argument textReader (metavar "PATH" <> help "SSM parameter path")
  <*> flag True False (long "no-decrypt" <> help "Don't decrypt SecureString values")
  <*> option paramFormatReader
      ( long "format"
      <> value ParamFormatRaw
      <> metavar "FORMAT"
      <> help "Output format: raw|json|yaml (default: raw)"
      )

paramGetByPathArgsParser :: Parser ParamGetByPathArgs
paramGetByPathArgsParser = ParamGetByPathArgs
  <$> argument textReader (metavar "PATH" <> help "SSM parameter path prefix")
  <*> flag True False (long "no-decrypt" <> help "Don't decrypt SecureString values")
  <*> option paramFormatReader
      ( long "format"
      <> value ParamFormatRaw
      <> metavar "FORMAT"
      <> help "Output format: raw|json|yaml (default: raw)"
      )
  <*> switch (long "recursive" <> help "Recursively list parameters under path")

approvalRequestArgsParser :: Parser ApprovalRequestArgs
approvalRequestArgsParser = ApprovalRequestArgs
  <$> argument textReader (metavar "ARGSFILE" <> help "Path to stack-args.yaml")
  <*> flag True False (long "no-lint-template" <> help "Skip linting the template before requesting approval")

approvalReviewArgsParser :: Parser ApprovalReviewArgs
approvalReviewArgsParser = ApprovalReviewArgs
  <$> argument textReader (metavar "URL" <> help "Approval request URL")
  <*> option auto
      ( long "context"
      <> value 500
      <> metavar "LINES"
      <> help "Number of context lines to show in diff (default: 500)"
      )

renderArgsParser :: Parser RenderArgs
renderArgsParser = RenderArgs
  <$> argument textReader
      ( metavar "TEMPLATE"
      <> help "Template file path or '-' to read from stdin"
      )
  <*> option textReader
      ( long "outfile"
      <> value "stdout"
      <> metavar "FILE"
      <> help "Output file path or 'stdout' for stdout (default: stdout)"
      )
  <*> option renderFormatReader
      ( long "format"
      <> value RenderYaml
      <> metavar "FORMAT"
      <> help "Output format: yaml|json|yaml-cloudformation (default: yaml)"
      )
  <*> optional (option textReader
      ( long "query"
      <> metavar "JMESPATH"
      <> help "JMESPath query to filter output"
      ))
  <*> switch (long "overwrite" <> help "Overwrite output file if it exists")
  <*> option yamlSpecReader
      ( long "yaml-spec"
      <> value YamlAuto
      <> metavar "SPEC"
      <> help "YAML specification version for input parsing: 1.1|1.2|auto (default: auto)"
      )

getImportArgsParser :: Parser GetImportArgs
getImportArgsParser = GetImportArgs
  <$> argument textReader (metavar "IMPORT" <> help "Import specifier to retrieve")
  <*> option getImportFormatReader
      ( long "format"
      <> value RenderYaml
      <> metavar "FORMAT"
      <> help "Output format: yaml|json (default: yaml)"
      )
  <*> optional (option textReader
      ( long "query"
      <> metavar "JMESPATH"
      <> help "JMESPath query to filter output"
      ))

demoArgsParser :: Parser DemoArgs
demoArgsParser = DemoArgs
  <$> argument textReader
      ( metavar "DEMOSCRIPT"
      <> help "Path to demo script file"
      )
  <*> option auto
      ( long "timescaling"
      <> value 1.0
      <> metavar "FACTOR"
      <> help "Time scaling factor for demo playback (default: 1.0)"
      )
  <*> switch
      ( long "mask-secrets"
      <> help "Mask secrets (AWS account numbers, ARNs) in command output"
      )

lintTemplateArgsParser :: Parser LintTemplateArgs
lintTemplateArgsParser = LintTemplateArgs
  <$> argument textReader (metavar "ARGSFILE" <> help "Path to stack-args.yaml")
  <*> switch (long "use-parameters" <> help "Use parameter values when linting")

convertArgsParser :: Parser ConvertArgs
convertArgsParser = ConvertArgs
  <$> argument textReader (metavar "STACKNAME" <> help "Name of the existing CFN stack")
  <*> argument textReader (metavar "OUTPUT_DIR" <> help "Directory to write iidy project files")
  <*> switch (long "move-params-to-ssm" <> help "Move stack parameters to SSM Parameter Store")
  <*> flag True False (long "no-sortkeys" <> help "Don't sort YAML keys in output")
  <*> optional (option textReader
      ( long "project"
      <> metavar "NAME"
      <> help "Project name for the iidy project"
      ))

initStackArgsParser :: Parser InitStackArgs
initStackArgsParser = InitStackArgs
  <$> switch (long "force" <> help "Overwrite all existing files")
  <*> switch (long "force-stack-args" <> help "Overwrite stack-args.yaml if it exists")
  <*> switch (long "force-cfn-template" <> help "Overwrite cfn-template.yaml if it exists")

------------------------------------------------------------------------
-- Value readers
------------------------------------------------------------------------

textReader :: ReadM Text
textReader = T.pack <$> str

colorChoiceReader :: ReadM ColorChoice
colorChoiceReader = eitherReader $ \s -> case s of
  "auto"   -> Right ColorAuto
  "always" -> Right ColorAlways
  "never"  -> Right ColorNever
  _        -> Left $ "Unknown color choice: " <> s <> ". Expected: auto|always|never"

themeReader :: ReadM Theme
themeReader = eitherReader $ \s -> case s of
  "auto"          -> Right ThemeAuto
  "light"         -> Right ThemeLight
  "dark"          -> Right ThemeDark
  "high-contrast" -> Right ThemeHighContrast
  _               -> Left $ "Unknown theme: " <> s <> ". Expected: auto|light|dark|high-contrast"

outputModeReader :: ReadM OutputMode
outputModeReader = eitherReader $ \s -> case s of
  "plain"       -> Right Plain
  "interactive" -> Right Interactive
  "json"        -> Right Json
  _             -> Left $ "Unknown output mode: " <> s <> ". Expected: plain|interactive|json"

templateFormatReader :: ReadM TemplateFormat
templateFormatReader = eitherReader $ \s -> case s of
  "json"     -> Right FormatJson
  "yaml"     -> Right FormatYaml
  "original" -> Right FormatOriginal
  _          -> Left $ "Unknown format: " <> s <> ". Expected: json|yaml|original"

templateStageReader :: ReadM TemplateStageArg
templateStageReader = eitherReader $ \s -> case s of
  "original"  -> Right StageOriginal
  "processed" -> Right StageProcessed
  _           -> Left $ "Unknown stage: " <> s <> ". Expected: original|processed"

yamlSpecReader :: ReadM YamlSpec
yamlSpecReader = eitherReader $ \s -> case s of
  "1.1"  -> Right YamlV11
  "1.2"  -> Right YamlV12
  "auto" -> Right YamlAuto
  _      -> Left $ "Unknown yaml-spec: " <> s <> ". Expected: 1.1|1.2|auto"

renderFormatReader :: ReadM RenderFormat
renderFormatReader = eitherReader $ \s -> case map toLower s of
  "json"                -> Right RenderJson
  "yaml"                -> Right RenderYaml
  "yml"                 -> Right RenderYaml
  "yaml-cloudformation" -> Right RenderCfnYaml
  _                     -> Left $ "Unknown output format: " <> s
                                <> ". Valid formats: json, yaml, yaml-cloudformation"

getImportFormatReader :: ReadM RenderFormat
getImportFormatReader = eitherReader $ \s -> case map toLower s of
  "json" -> Right RenderJson
  "yaml" -> Right RenderYaml
  "yml"  -> Right RenderYaml
  _      -> Left $ "Unknown output format: " <> s
                 <> ". Valid formats: json, yaml"

paramTypeReader :: ReadM ParamType
paramTypeReader = eitherReader $ \s -> case map toLower s of
  "string"       -> Right ParamString
  "securestring" -> Right ParamSecureString
  "stringlist"   -> Right ParamStringList
  _              -> Left $ "Unknown parameter type: " <> s <> ". Expected: String|SecureString|StringList"

paramFormatReader :: ReadM ParamFormat
paramFormatReader = eitherReader $ \s -> case map toLower s of
  "raw"    -> Right ParamFormatRaw
  "json"   -> Right ParamFormatJson
  "yaml"   -> Right ParamFormatYaml
  "simple" -> Right ParamFormatRaw
  _        -> Left $ "Unknown format: " <> s <> ". Expected: raw|json|yaml"

shellTypeReader :: ReadM ShellType
shellTypeReader = eitherReader $ \s -> case map toLower s of
  "bash" -> Right ShellBash
  "zsh"  -> Right ShellZsh
  "fish" -> Right ShellFish
  _      -> Left $ "Unknown shell: " <> s <> ". Expected: bash|zsh|fish"
