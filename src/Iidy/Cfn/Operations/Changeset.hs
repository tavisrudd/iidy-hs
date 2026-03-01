-- | CloudFormation changeset operations: create, execute, describe.
--
-- Provides createChangeset, executeChangeset, and describeChangeset,
-- which correspond to the CloudFormation CreateChangeSet, ExecuteChangeSet,
-- and DescribeChangeSet API calls respectively.
--
-- Also provides shared helpers for changeset flows:
-- generateDashedName (random name gen), checkStackState (existence +
-- REVIEW_IN_PROGRESS detection), and confirmChangesetExecution.
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.Changeset
  ( createChangeset
  , executeChangeset
  , describeChangeset
  , buildChangeSetCreationResult
  -- * Shared helpers for changeset flows
  , generateDashedName
  , StackState(..)
  , checkStackState
  , confirmChangesetExecution
  -- * Internal (exported for testing)
  , convertChange
  , convertDetail
  , percentEncode
  , extractRegionFromArn
  , buildChangesetConsoleUrl
  , formatAmazonkaError
  , isNonRetryableError
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (catch)
import Control.Lens (set, view)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Conduit (runConduit, (.|))
import qualified Data.Conduit.List as CL
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import System.Random (randomRIO)

import qualified Amazonka
import qualified Amazonka.CloudFormation as CF
import qualified Amazonka.CloudFormation.Types as CF
import qualified Amazonka.CloudFormation.CreateChangeSet as CCS
import qualified Amazonka.CloudFormation.ExecuteChangeSet as ECS
import qualified Amazonka.CloudFormation.DescribeChangeSet as DCS
import qualified Amazonka.CloudFormation.ListChangeSets as LCS

import Iidy.Confirm (requestConfirmation)
import Iidy.Aws.ClientReqToken (TokenInfo(..))
import Iidy.Cfn.Context
  ( CfnContext(..)
  , createSuccessStates
  , updateSuccessStates
  , ctxDeriveToken
  , changesetTerminalStatuses
  )
import Iidy.Cfn.RequestBuilder (buildCreateChangeSetRequest)
import Iidy.Cfn.Operations.DescribeStack (buildEventsDisplay, mkStandardPollConfig, emitStackDefinition)
import Iidy.Cfn.StackOperations
  ( fetchStackEvents
  , getStackId
  , getStack
  , collectStackContents
  , pollForCompletion
  , percentEncode
  , PollResult(..)
  )
import Iidy.Cfn.Types (StackArgs(..), getStackName)
import Iidy.Output.Types
  ( OutputData(..)
  , ChangeSetInfo(..), ChangeInfo(..), ChangeDetail(..)
  , ChangeSetCreationResult(..)
  )

------------------------------------------------------------------------
-- Changeset creation
------------------------------------------------------------------------

-- | Create a CloudFormation change set, poll until it reaches a terminal
-- state, then return the ChangeSetInfo.
--
-- Steps:
--   1. Build the CreateChangeSet request (type = CREATE or UPDATE based on stackExists).
--   2. Send it.
--   3. Extract the changeset ID from the response.
--   4. Poll DescribeChangeSet every 2s until status is CREATE_COMPLETE or FAILED.
--   5. Return the final ChangeSetInfo.
--
-- Exceptions from the AWS API propagate to the caller; this function does not
-- wrap them in Either.
createChangeset
  :: CfnContext
  -> StackArgs
  -> Text            -- ^ changeset name
  -> Bool            -- ^ stack exists? (True => UPDATE, False => CREATE type)
  -> Maybe FilePath  -- ^ argsfile path for template resolution
  -> Text            -- ^ environment name
  -> IO ChangeSetInfo
createChangeset ctx args csName stackExists argsfilePath env = do
  let csType = if stackExists
                 then CF.ChangeSetType_UPDATE
                 else CF.ChangeSetType_CREATE
      stackName = getStackName args

  -- Step 1 & 2: Build and send the CreateChangeSet request
  (req, _token) <- buildCreateChangeSetRequest ctx args csName csType argsfilePath env
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req

  -- Step 3: Extract the changeset ARN/ID (fall back to name for polling).
  -- OverloadedRecordDot cannot be used for 'id' (conflicts with Prelude.id);
  -- use the generated lens accessor instead.
  let csId = fromMaybe csName (view CCS.createChangeSetResponse_id resp)

  -- Step 4: Poll until CREATE_COMPLETE or FAILED
  pollChangesetCompletion ctx stackName csId

-- | Poll DescribeChangeSet every 2s until the changeset reaches a terminal
-- state (CREATE_COMPLETE or FAILED).  Returns the ChangeSetInfo on completion.
-- Retries transient errors up to 30 times (60 seconds).
-- Overall cap of 300 iterations (600 seconds / 10 minutes) to prevent
-- infinite polling on stuck changesets.
pollChangesetCompletion :: CfnContext -> Text -> Text -> IO ChangeSetInfo
pollChangesetCompletion ctx stackName csId = go (0 :: Int) (0 :: Int)
  where
    maxRetries :: Int
    maxRetries = 30

    maxIterations :: Int
    maxIterations = 300

    go :: Int -> Int -> IO ChangeSetInfo
    go errorCount totalIterations
      | totalIterations >= maxIterations =
          mkFailedInfo ("Changeset polling timed out after " <> T.pack (show maxIterations) <> " iterations")
      | otherwise = do
          threadDelay (2 * 1000000)  -- 2 seconds
          result <- describeChangeset ctx stackName csId
          case result of
            Left err
              | isNonRetryableError err ->
                  -- Permanent error (not found, access denied) — fail immediately
                  mkFailedInfo (formatAmazonkaError err)
              | errorCount >= maxRetries ->
                  -- Transient errors exhausted retry budget
                  mkFailedInfo ("Polling failed after " <> T.pack (show maxRetries) <> " retries: " <> formatAmazonkaError err)
              | otherwise -> go (errorCount + 1) (totalIterations + 1)
            Right info ->
              if isTerminalCsStatus (csiStatus info)
                then pure info
                else go 0 (totalIterations + 1)  -- reset error count on success

    mkFailedInfo :: Text -> IO ChangeSetInfo
    mkFailedInfo reason = pure ChangeSetInfo
      { csiChangeSetName  = csId
      , csiChangeSetId    = csId
      , csiStackId        = ""
      , csiStackName      = stackName
      , csiDescription    = Nothing
      , csiStatus         = "FAILED"
      , csiStatusReason   = Just reason
      , csiCreationTime   = Nothing
      , csiExecutionStatus = Nothing
      , csiChanges        = []
      }

    isTerminalCsStatus :: Text -> Bool
    isTerminalCsStatus s = s `elem` ["CREATE_COMPLETE", "FAILED", "DELETE_COMPLETE", "DELETE_FAILED"]

------------------------------------------------------------------------
-- Changeset execution
------------------------------------------------------------------------

-- | Execute a CloudFormation change set and poll the stack for completion.
--
-- Steps:
--   1. Build and send ExecuteChangeSet.
--   2. Emit StackDefinition + previous events.
--   3. Poll for completion; both CREATE_COMPLETE and UPDATE_COMPLETE are success states.
--   4. Emit StackContents on completion.
--   5. Return exit code (0 = success, 1 = failure).
executeChangeset
  :: CfnContext
  -> Text                   -- ^ stack name
  -> Text                   -- ^ changeset name
  -> (OutputData -> IO ())  -- ^ output emitter for progress display
  -> IO (Either Text Int)
executeChangeset ctx stackName csName emit = do
  -- Step 1: Build and send ExecuteChangeSet request
  token <- ctxDeriveToken ctx "execute-changeset"
  let baseReq = ECS.newExecuteChangeSet csName
      req = baseReq
        { ECS.stackName           = Just stackName
        , ECS.clientRequestToken  = Just (tiValue token)
        }
  _resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req

  -- Step 2: Get stack ID for polling
  mStackId <- getStackId ctx stackName
  let stackId = fromMaybe stackName mStackId

  -- Step 2b: Emit StackDefinition
  emitStackDefinition ctx stackId emit

  -- Step 2c: Emit previous events (unique to exec-changeset)
  prevEvents <- fetchStackEvents ctx stackName
  let eventsDisplay = buildEventsDisplay 10 prevEvents
  emit (OdStackEvents eventsDisplay)

  -- Step 3: Poll for completion, emitting events through renderer
  emit (OdPollingStarted "Loading live events...")
  let pollCfg = mkStandardPollConfig ctx emit
  pollResult <- pollForCompletion ctx stackId changesetTerminalStatuses pollCfg

  -- Step 4: Emit StackContents
  let successStates = createSuccessStates ++ updateSuccessStates
  case pollResult of
    PollSuccess "DELETE_COMPLETE" -> pure (Right 1)
    PollSuccess finalStatus -> do
      contents <- collectStackContents ctx stackName
      emit (OdStackContents contents)
      -- Step 5: Return exit code
      if finalStatus `elem` successStates
        then pure (Right 0)
        else pure (Right 1)
    _ -> pure (Right 1)  -- timeout = failure

------------------------------------------------------------------------
-- Changeset description
------------------------------------------------------------------------

-- | Call DescribeChangeSet and convert the response to ChangeSetInfo.
-- Returns Left on Amazonka errors (preserving the error for retryability
-- checks), Right on success.
describeChangeset
  :: CfnContext
  -> Text  -- ^ stack name
  -> Text  -- ^ changeset name (or ARN)
  -> IO (Either Amazonka.Error ChangeSetInfo)
describeChangeset ctx stackName csName = do
  let req = set DCS.describeChangeSet_stackName (Just stackName)
              (DCS.newDescribeChangeSet csName)
  result <- fmap Right (runResourceT $ Amazonka.send (cfnEnv ctx) req)
    `catch` (\e -> pure (Left (e :: Amazonka.Error)))
  case result of
    Left err   -> pure (Left err)
    Right resp -> pure (Right (convertDescribeResponse resp))

-- | Convert a DescribeChangeSetResponse to ChangeSetInfo.
convertDescribeResponse :: DCS.DescribeChangeSetResponse -> ChangeSetInfo
convertDescribeResponse resp = ChangeSetInfo
  { csiChangeSetName   = fromMaybe "" resp.changeSetName
  , csiChangeSetId     = fromMaybe "" resp.changeSetId
  , csiStackId         = fromMaybe "" resp.stackId
  , csiStackName       = fromMaybe "" resp.stackName
  , csiDescription     = resp.description
  , csiStatus          = CF.fromChangeSetStatus resp.status
  , csiStatusReason    = resp.statusReason
  , csiCreationTime    = fmap (.fromTime) resp.creationTime
  , csiExecutionStatus = CF.fromExecutionStatus <$> resp.executionStatus
  , csiChanges         = mapMaybe convertChange (fromMaybe [] resp.changes)
  }

-- | Extract a clean, user-friendly error message from an Amazonka error.
formatAmazonkaError :: Amazonka.Error -> Text
formatAmazonkaError (Amazonka.ServiceError se) =
  let Amazonka.ErrorCode code = se.code
      msg = maybe "" Amazonka.fromErrorMessage se.message
  in code <> ": " <> msg
formatAmazonkaError e = T.pack (show e)

-- | Check if an Amazonka error is non-retryable (permanent).
-- Access denied and not-found errors will not resolve on retry.
isNonRetryableError :: Amazonka.Error -> Bool
isNonRetryableError (Amazonka.ServiceError se) =
  se.code `elem` map Amazonka.ErrorCode
    [ "ChangeSetNotFoundException"
    , "AccessDeniedException"
    , "ValidationError"
    ]
isNonRetryableError _ = False

------------------------------------------------------------------------
-- AWS type conversion helpers
------------------------------------------------------------------------

-- | Convert a CF.Change to ChangeInfo (returns Nothing if resourceChange absent).
convertChange :: CF.Change -> Maybe ChangeInfo
convertChange ch = do
  rc <- ch.resourceChange
  logId <- rc.logicalResourceId
  rType <- rc.resourceType
  pure ChangeInfo
    { ciAction             = maybe "" CF.fromChangeAction rc.action
    , ciLogicalResourceId  = logId
    , ciPhysicalResourceId = rc.physicalResourceId
    , ciResourceType       = rType
    , ciReplacement        = CF.fromReplacement <$> rc.replacement
    , ciScope              = fmap (map CF.fromResourceAttribute) rc.scope
    , ciDetails            = map convertDetail (fromMaybe [] rc.details)
    }

-- | Convert a CF.ResourceChangeDetail to ChangeDetail.
convertDetail :: CF.ResourceChangeDetail -> ChangeDetail
convertDetail d =
  let targetText = case d.target of
        Nothing -> ""
        Just t  -> fromMaybe "" (fmap CF.fromResourceAttribute t.attribute)
  in ChangeDetail
       { cdTarget        = targetText
       , cdEvaluation    = CF.fromEvaluationType <$> d.evaluation
       , cdChangeSource  = CF.fromChangeSource <$> d.changeSource
       , cdCausingEntity = d.causingEntity
       }

------------------------------------------------------------------------
-- Changeset creation result
------------------------------------------------------------------------

-- | Build a ChangeSetCreationResult from a ChangeSetInfo for rendering.
-- Constructs the console URL and next-steps instructions.
buildChangeSetCreationResult
  :: ChangeSetInfo
  -> Bool            -- ^ stack existed before? (True = UPDATE, False = CREATE)
  -> Text            -- ^ argsfile path
  -> ChangeSetCreationResult
buildChangeSetCreationResult info stackExists argsfile =
  let csType = if stackExists then "UPDATE" else "CREATE" :: Text
      regionText = extractRegionFromArn (csiStackId info)
      consoleUrl = buildChangesetConsoleUrl regionText (csiStackId info) (csiChangeSetId info)
      hasChanges = not (null (csiChanges info))
      -- Only show REVIEW_IN_PROGRESS instructions for CREATE changesets;
      -- UPDATE changesets do not put the stack into that state.
      nextSteps =
        if csType == "CREATE"
          then
            [ "Your new stack is now in REVIEW_IN_PROGRESS state. To create the resources run the following"
            , "  iidy --region " <> regionText <> " exec-changeset --stack-name "
              <> csiStackName info <> " " <> argsfile <> " " <> csiChangeSetName info
            ]
          else
            [ "  iidy --region " <> regionText <> " exec-changeset --stack-name "
              <> csiStackName info <> " " <> argsfile <> " " <> csiChangeSetName info
            ]
  in ChangeSetCreationResult
    { csrChangesetName     = csiChangeSetName info
    , csrStackName         = csiStackName info
    , csrChangesetType     = csType
    , csrStatus            = csiStatus info
    , csrConsoleUrl        = consoleUrl
    , csrHasChanges        = hasChanges
    , csrPendingChangesets = [info]
    , csrNextSteps         = nextSteps
    }

-- | Build a changeset console URL with URL-encoded ARNs.
-- Changeset URLs DO encode ARN characters (unlike stack info URLs).
buildChangesetConsoleUrl :: Text -> Text -> Text -> Text
buildChangesetConsoleUrl region stackArn changesetArn =
  "https://" <> region <> ".console.aws.amazon.com/cloudformation/home?region="
  <> region <> "#/changeset/detail?stackId="
  <> percentEncode stackArn <> "&changeSetId=" <> percentEncode changesetArn

-- | Extract region from a CloudFormation ARN.
-- ARN format: arn:aws:cloudformation:REGION:ACCOUNT:stack/NAME/ID
extractRegionFromArn :: Text -> Text
extractRegionFromArn arn =
  case drop 3 (T.splitOn ":" arn) of
    (region:_) -> region
    _          -> "us-east-1"  -- Fallback matches Rust; ARNs from AWS are always well-formed

------------------------------------------------------------------------
-- Shared helpers for changeset flows
------------------------------------------------------------------------

-- | Stack state for changeset operations.
data StackState
  = StackDoesNotExist                -- ^ No stack with this name
  | StackNormal                      -- ^ Stack exists in a normal terminal state
  | StackReviewInProgress Text       -- ^ Stack has a pending changeset (name)
  deriving stock (Show, Eq)

-- | Check the state of a stack for changeset operations.
-- Detects REVIEW_IN_PROGRESS (pending changeset) and returns the
-- existing changeset name if found.
checkStackState :: CfnContext -> Text -> IO StackState
checkStackState ctx stackName = do
  mStack <- getStack ctx stackName
  case mStack of
    Nothing -> pure StackDoesNotExist
    Just s
      | s.stackStatus == CF.StackStatus_DELETE_COMPLETE ->
          pure StackDoesNotExist
      | s.stackStatus == CF.StackStatus_REVIEW_IN_PROGRESS -> do
          -- Stack is in REVIEW_IN_PROGRESS — find the pending changeset
          csName <- findPendingChangeset ctx stackName
          pure (StackReviewInProgress csName)
      | otherwise ->
          pure StackNormal

-- | Find the name of a pending changeset on a stack in REVIEW_IN_PROGRESS.
-- Paginates ListChangeSets to handle stacks with many changesets.
findPendingChangeset :: CfnContext -> Text -> IO Text
findPendingChangeset ctx stackName = do
  csPages <- runResourceT $ runConduit $
    Amazonka.paginate (cfnEnv ctx) (LCS.newListChangeSets stackName)
    .| CL.consume
  let allSummaries = concatMap (fromMaybe [] . (.summaries)) csPages
      pending = [ s | s <- allSummaries
                , fmap CF.fromExecutionStatus s.executionStatus == Just "AVAILABLE"
                ]
  case pending of
    (s:_) -> pure (fromMaybe "unknown" s.changeSetName)
    []    -> pure "unknown"

-- | Generate a random dashed name (docker-style: adjective-noun).
-- Used as default changeset name when user doesn't provide one.
-- 20 adjectives x 20 nouns = 400 unique combinations.
generateDashedName :: IO Text
generateDashedName = do
  adjIdx <- randomRIO (0, V.length adjectives - 1)
  nounIdx <- randomRIO (0, V.length nouns - 1)
  pure $ (adjectives V.! adjIdx) <> "-" <> (nouns V.! nounIdx)
  where
    adjectives :: V.Vector Text
    adjectives = V.fromList
      [ "admiring", "adoring", "affectionate", "agitated", "amazing"
      , "angry", "awesome", "blissful", "bold", "brave"
      , "clever", "cool", "dazzling", "determined", "dreamy"
      , "eager", "elastic", "elated", "elegant", "epic"
      ]
    nouns :: V.Vector Text
    nouns = V.fromList
      [ "albattani", "allen", "almeida", "antonelli", "agnesi"
      , "archimedes", "ardinghelli", "aryabhata", "austin", "babbage"
      , "banach", "banzai", "bardeen", "bartik", "bassi"
      , "beaver", "bell", "benz", "bhabha", "bhaskara"
      ]

-- | Prompt the user to confirm changeset execution.
-- Returns True if confirmed (or if --yes flag was provided), False otherwise.
confirmChangesetExecution :: Bool -> IO Bool
confirmChangesetExecution yesFlag
  | yesFlag   = pure True
  | otherwise = requestConfirmation "Do you want to execute this changeset now?"
