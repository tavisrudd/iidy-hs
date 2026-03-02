module Iidy.Cli
  ( -- * Top-level CLI
    Cli(..)
  , GlobalOpts(..)
  , AwsOpts(..)
  , NormalizedAwsOpts(..)
    -- * Commands
  , Commands(..)
  , ParamCommands(..)
  , ApprovalCommands(..)
    -- * Arg types
  , StackFileArgs(..)
  , CreateStackArgs(..)
  , UpdateStackArgs(..)
  , CreateChangeSetArgs(..)
  , ExecChangeSetArgs(..)
  , DescribeArgs(..)
  , WatchArgs(..)
  , DriftArgs(..)
  , DeleteArgs(..)
  , GetTemplateArgs(..)
  , GetStackInstancesArgs(..)
  , ListArgs(..)
  , ParamSetArgs(..)
  , ParamPathArg(..)
  , ParamGetArgs(..)
  , ParamGetByPathArgs(..)
  , ApprovalRequestArgs(..)
  , ApprovalReviewArgs(..)
  , RenderArgs(..)
  , GetImportArgs(..)
  , DemoArgs(..)
  , LintTemplateArgs(..)
  , ConvertArgs(..)
  , InitStackArgs(..)
    -- * Format enums
  , TemplateFormat(..)
  , TemplateStageArg(..)
  , RenderFormat(..)
  , ParamType(..)
  , ParamFormat(..)
  , ShellType(..)
  ) where

import Data.Text (Text)
import Iidy.Aws.ClientReqToken (TokenInfo)
import Iidy.Types (ColorChoice, OutputMode, Theme, YamlSpec)

------------------------------------------------------------------------
-- Top-level CLI types
------------------------------------------------------------------------

data Cli = Cli
  { cliGlobalOpts :: !GlobalOpts
  , cliAwsOpts    :: !AwsOpts
  , cliCommand    :: !Commands
  } deriving stock (Show, Eq)

data GlobalOpts = GlobalOpts
  { goEnvironment   :: !Text
  , goColor         :: !ColorChoice
  , goTheme         :: !Theme
  , goOutputMode    :: !(Maybe OutputMode)
  , goDebug         :: !Bool
  , goLogFullError  :: !Bool
  } deriving stock (Show, Eq)

data AwsOpts = AwsOpts
  { aoRegion             :: !(Maybe Text)
  , aoProfile            :: !(Maybe Text)
  , aoAssumeRoleArn      :: !(Maybe Text)
  , aoClientRequestToken :: !(Maybe Text)
  } deriving stock (Show, Eq)

data NormalizedAwsOpts = NormalizedAwsOpts
  { naoRegion             :: !(Maybe Text)
  , naoProfile            :: !(Maybe Text)
  , naoAssumeRoleArn      :: !(Maybe Text)
  , naoClientRequestToken :: !TokenInfo
  , naoFixtureSet         :: !(Maybe Text)
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------

data Commands
  = CmdCreateStack !CreateStackArgs
  | CmdUpdateStack !UpdateStackArgs
  | CmdCreateOrUpdate !UpdateStackArgs
  | CmdEstimateCost !StackFileArgs
  | CmdCreateChangeset !CreateChangeSetArgs
  | CmdExecChangeset !ExecChangeSetArgs
  | CmdDescribeStack !DescribeArgs
  | CmdWatchStack !WatchArgs
  | CmdDescribeStackDrift !DriftArgs
  | CmdDeleteStack !DeleteArgs
  | CmdGetStackTemplate !GetTemplateArgs
  | CmdGetStackInstances !GetStackInstancesArgs
  | CmdListStacks !ListArgs
  | CmdParam !ParamCommands
  | CmdTemplateApproval !ApprovalCommands
  | CmdRender !RenderArgs
  | CmdGetImport !GetImportArgs
  | CmdDemo !DemoArgs
  | CmdLintTemplate !LintTemplateArgs
  | CmdConvertStackToIidy !ConvertArgs
  | CmdInitStackArgs !InitStackArgs
  | CmdCompletion !(Maybe ShellType)      -- ^ shell name
  | CmdExplain ![Text]                    -- ^ error codes
  deriving stock (Show, Eq)

data ParamCommands
  = ParamSet !ParamSetArgs
  | ParamReview !ParamPathArg
  | ParamGet !ParamGetArgs
  | ParamGetByPath !ParamGetByPathArgs
  | ParamGetHistory !ParamGetArgs
  deriving stock (Show, Eq)

data ApprovalCommands
  = ApprovalRequest !ApprovalRequestArgs
  | ApprovalReview !ApprovalReviewArgs
  deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Format enums
------------------------------------------------------------------------

data TemplateFormat = FormatJson | FormatYaml | FormatOriginal
  deriving stock (Show, Eq, Ord)

data TemplateStageArg = StageOriginal | StageProcessed
  deriving stock (Show, Eq, Ord)

-- | Output format for render and get-import commands
data RenderFormat = RenderJson | RenderYaml | RenderCfnYaml
  deriving stock (Show, Eq, Ord)

-- | SSM parameter type
data ParamType = ParamString | ParamSecureString | ParamStringList
  deriving stock (Show, Eq)

-- | Parameter output format
data ParamFormat = ParamFormatRaw | ParamFormatJson | ParamFormatYaml
  deriving stock (Show, Eq)

-- | Shell type for completion generation
data ShellType = ShellBash | ShellZsh | ShellFish
  deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Arg types
------------------------------------------------------------------------

data StackFileArgs = StackFileArgs
  { sfaArgsfile  :: !Text
  , sfaStackName :: !(Maybe Text)
  } deriving stock (Show, Eq)

data CreateStackArgs = CreateStackArgs
  { csaArgsfile  :: !Text
  , csaStackName :: !(Maybe Text)
  } deriving stock (Show, Eq)

data UpdateStackArgs = UpdateStackArgs
  { usaBase                    :: !StackFileArgs
  , usaLintTemplate            :: !(Maybe Bool)
  , usaChangeset               :: !Bool
  , usaYes                     :: !Bool
  , usaDiff                    :: !Bool
  , usaStackPolicyDuringUpdate :: !(Maybe Text)
  } deriving stock (Show, Eq)

data CreateChangeSetArgs = CreateChangeSetArgs
  { ccsArgsfile                 :: !Text
  , ccsChangesetName            :: !(Maybe Text)
  , ccsWatch                    :: !Bool
  , ccsWatchInactivityTimeout   :: !Int
  , ccsDescription              :: !(Maybe Text)
  , ccsStackName                :: !(Maybe Text)
  } deriving stock (Show, Eq)

data ExecChangeSetArgs = ExecChangeSetArgs
  { ecsArgsfile      :: !Text
  , ecsChangesetName :: !Text
  , ecsStackName     :: !(Maybe Text)
  } deriving stock (Show, Eq)

data DescribeArgs = DescribeArgs
  { daStackname :: !Text
  , daEvents    :: !Int
  , daQuery     :: !(Maybe Text)
  } deriving stock (Show, Eq)

data WatchArgs = WatchArgs
  { waStackname          :: !Text
  , waInactivityTimeout  :: !Int
  } deriving stock (Show, Eq)

data DriftArgs = DriftArgs
  { drfStackname  :: !Text
  , drfDriftCache :: !Int
  } deriving stock (Show, Eq)

data DeleteArgs = DeleteArgs
  { delStackname       :: !Text
  , delRoleArn         :: !(Maybe Text)
  , delRetainResources :: ![Text]
  , delYes             :: !Bool
  , delFailIfAbsent    :: !Bool
  } deriving stock (Show, Eq)

data GetTemplateArgs = GetTemplateArgs
  { gtaStackname :: !Text
  , gtaFormat    :: !TemplateFormat
  , gtaStage     :: !TemplateStageArg
  } deriving stock (Show, Eq)

data GetStackInstancesArgs = GetStackInstancesArgs
  { gsiStackname :: !Text
  , gsiShort     :: !Bool
  } deriving stock (Show, Eq)

data ListArgs = ListArgs
  { laTagFilter      :: ![Text]
  , laJmespathFilter :: !(Maybe Text)
  , laQuery          :: !(Maybe Text)
  , laTags           :: !Bool
  , laColumns        :: !(Maybe Text)
  } deriving stock (Show, Eq)

data ParamSetArgs = ParamSetArgs
  { psaPath         :: !Text
  , psaValue        :: !Text
  , psaMessage      :: !(Maybe Text)
  , psaOverwrite    :: !Bool
  , psaWithApproval :: !Bool
  , psaType         :: !ParamType
  } deriving stock (Show, Eq)

newtype ParamPathArg = ParamPathArg
  { ppaPath :: Text
  } deriving stock (Show, Eq)

data ParamGetArgs = ParamGetArgs
  { pgaPath    :: !Text
  , pgaDecrypt :: !Bool
  , pgaFormat  :: !ParamFormat
  } deriving stock (Show, Eq)

data ParamGetByPathArgs = ParamGetByPathArgs
  { gpbPath      :: !Text
  , gpbDecrypt   :: !Bool
  , gpbFormat    :: !ParamFormat
  , gpbRecursive :: !Bool
  } deriving stock (Show, Eq)

data ApprovalRequestArgs = ApprovalRequestArgs
  { araArgsfile      :: !Text
  , araLintTemplate  :: !Bool
  } deriving stock (Show, Eq)

data ApprovalReviewArgs = ApprovalReviewArgs
  { arvUrl     :: !Text
  , arvContext :: !Int
  } deriving stock (Show, Eq)

data RenderArgs = RenderArgs
  { raTemplate  :: !Text
  , raOutfile   :: !Text
  , raFormat    :: !RenderFormat
  , raQuery     :: !(Maybe Text)
  , raOverwrite :: !Bool
  , raYamlSpec  :: !YamlSpec
  } deriving stock (Show, Eq)

data GetImportArgs = GetImportArgs
  { giaImport :: !Text
  , giaFormat :: !RenderFormat
  , giaQuery  :: !(Maybe Text)
  } deriving stock (Show, Eq)

data DemoArgs = DemoArgs
  { daDemoscript  :: !Text
  , daTimescaling :: !Double
  , daMaskSecrets :: !Bool
  } deriving stock (Show, Eq)

data LintTemplateArgs = LintTemplateArgs
  { ltaArgsfile      :: !Text
  , ltaUseParameters :: !Bool
  } deriving stock (Show, Eq)

data ConvertArgs = ConvertArgs
  { caStackname      :: !Text
  , caOutputDir      :: !Text
  , caMoveParamsToSsm :: !Bool
  , caSortkeys       :: !Bool
  , caProject        :: !(Maybe Text)
  } deriving stock (Show, Eq)

data InitStackArgs = InitStackArgs
  { isaForce          :: !Bool
  , isaForceStackArgs :: !Bool
  , isaForceCfnTemplate :: !Bool
  } deriving stock (Show, Eq)
