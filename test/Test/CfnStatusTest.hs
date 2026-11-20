{- | Tests for "Iidy.Cfn.Status": every status amazonka knows parses to a
known constructor, stack-only statuses that arrive in stack events'
resource status are recognised, and status text not known here is kept
as 'UnknownStatus' rather than shown as a failure.
-}
module Test.CfnStatusTest (cfnStatusTests) where

import Data.List qualified as List
import Data.Text (Text)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Amazonka.CloudFormation.Types qualified as CF

import Iidy.Cfn.Status (
    StackStatus (..),
    fromCfnResourceStatus,
    fromCfnStackStatus,
    isFailed,
    isInProgress,
    isSuccess,
    isTerminal,
    knownStatuses,
    parseStatus,
    toText,
 )

cfnStatusTests :: [TestTree]
cfnStatusTests =
    [ testCase "every amazonka stack status parses to a known status" $
        mapM_ (assertKnown . fromCfnStackStatus) amazonkaStackStatuses
    , testCase "every amazonka resource status parses to a known status" $
        mapM_ (assertKnown . fromCfnResourceStatus) amazonkaResourceStatuses
    , testCase "toText gives the AWS text back for every amazonka stack status" $
        mapM_
            (\s -> toText (fromCfnStackStatus s) @?= CF.fromStackStatus s)
            amazonkaStackStatuses
    , testCase "known statuses have distinct texts" $
        let texts = map toText knownStatuses
         in length (List.nub texts) @?= length texts
    , testCase "UPDATE_COMPLETE_CLEANUP_IN_PROGRESS in a stack event is in progress, not a failure" $ do
        let s = fromCfnResourceStatus (CF.ResourceStatus' "UPDATE_COMPLETE_CLEANUP_IN_PROGRESS")
        s @?= UpdateCompleteCleanupInProgress
        toText s @?= "UPDATE_COMPLETE_CLEANUP_IN_PROGRESS"
        assertBool "in progress" (isInProgress s)
        assertBool "not terminal" (not (isTerminal s))
        assertBool "not failed" (not (isFailed s))
    , testCase "UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS in a stack event is in progress" $ do
        let s = fromCfnResourceStatus (CF.ResourceStatus' "UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS")
        s @?= UpdateRollbackCompleteCleanupInProgress
        assertBool "in progress" (isInProgress s)
        assertBool "not terminal" (not (isTerminal s))
    , testCase "unknown status text is kept and is neither terminal nor failed" $ do
        let s = parseStatus newStatusText
        s @?= UnknownStatus newStatusText
        toText s @?= newStatusText
        assertBool "not terminal" (not (isTerminal s))
        assertBool "not failed" (not (isFailed s))
        assertBool "not success" (not (isSuccess s))
        fromCfnResourceStatus (CF.ResourceStatus' newStatusText) @?= s
        fromCfnStackStatus (CF.StackStatus' newStatusText) @?= s
    ]
  where
    newStatusText :: Text
    newStatusText = "EXPORT_IN_PROGRESS"

    assertKnown :: StackStatus -> Assertion
    assertKnown = \case
        UnknownStatus t -> assertFailure ("not a known status: " <> show t)
        _known -> pure ()

-- | Every stack status pattern amazonka-cloudformation defines.
amazonkaStackStatuses :: [CF.StackStatus]
amazonkaStackStatuses =
    [ CF.StackStatus_CREATE_COMPLETE
    , CF.StackStatus_CREATE_FAILED
    , CF.StackStatus_CREATE_IN_PROGRESS
    , CF.StackStatus_DELETE_COMPLETE
    , CF.StackStatus_DELETE_FAILED
    , CF.StackStatus_DELETE_IN_PROGRESS
    , CF.StackStatus_IMPORT_COMPLETE
    , CF.StackStatus_IMPORT_IN_PROGRESS
    , CF.StackStatus_IMPORT_ROLLBACK_COMPLETE
    , CF.StackStatus_IMPORT_ROLLBACK_FAILED
    , CF.StackStatus_IMPORT_ROLLBACK_IN_PROGRESS
    , CF.StackStatus_REVIEW_IN_PROGRESS
    , CF.StackStatus_ROLLBACK_COMPLETE
    , CF.StackStatus_ROLLBACK_FAILED
    , CF.StackStatus_ROLLBACK_IN_PROGRESS
    , CF.StackStatus_UPDATE_COMPLETE
    , CF.StackStatus_UPDATE_COMPLETE_CLEANUP_IN_PROGRESS
    , CF.StackStatus_UPDATE_FAILED
    , CF.StackStatus_UPDATE_IN_PROGRESS
    , CF.StackStatus_UPDATE_ROLLBACK_COMPLETE
    , CF.StackStatus_UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS
    , CF.StackStatus_UPDATE_ROLLBACK_FAILED
    , CF.StackStatus_UPDATE_ROLLBACK_IN_PROGRESS
    ]

-- | Every resource status pattern amazonka-cloudformation defines.
amazonkaResourceStatuses :: [CF.ResourceStatus]
amazonkaResourceStatuses =
    [ CF.ResourceStatus_CREATE_COMPLETE
    , CF.ResourceStatus_CREATE_FAILED
    , CF.ResourceStatus_CREATE_IN_PROGRESS
    , CF.ResourceStatus_DELETE_COMPLETE
    , CF.ResourceStatus_DELETE_FAILED
    , CF.ResourceStatus_DELETE_IN_PROGRESS
    , CF.ResourceStatus_DELETE_SKIPPED
    , CF.ResourceStatus_IMPORT_COMPLETE
    , CF.ResourceStatus_IMPORT_FAILED
    , CF.ResourceStatus_IMPORT_IN_PROGRESS
    , CF.ResourceStatus_IMPORT_ROLLBACK_COMPLETE
    , CF.ResourceStatus_IMPORT_ROLLBACK_FAILED
    , CF.ResourceStatus_IMPORT_ROLLBACK_IN_PROGRESS
    , CF.ResourceStatus_ROLLBACK_COMPLETE
    , CF.ResourceStatus_ROLLBACK_FAILED
    , CF.ResourceStatus_ROLLBACK_IN_PROGRESS
    , CF.ResourceStatus_UPDATE_COMPLETE
    , CF.ResourceStatus_UPDATE_FAILED
    , CF.ResourceStatus_UPDATE_IN_PROGRESS
    , CF.ResourceStatus_UPDATE_ROLLBACK_COMPLETE
    , CF.ResourceStatus_UPDATE_ROLLBACK_FAILED
    , CF.ResourceStatus_UPDATE_ROLLBACK_IN_PROGRESS
    ]
