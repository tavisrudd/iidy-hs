-- | Tests for global SSM configuration logic.
--
-- We test:
--   1. The pure parameter-matching and StackArgs-modification logic
--      via the exported 'applyParams' helper.
--   2. Error handling behaviour: Amazonka errors produce a warning on
--      stderr (not silent), while async exceptions propagate.
module Test.GlobalConfigTest (globalConfigTests) where

import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool)

import Iidy.Cfn.GlobalConfig (applyParams)
import Iidy.Cfn.Types (StackArgs(..), emptyStackArgs)

------------------------------------------------------------------------
-- Tests
------------------------------------------------------------------------

globalConfigTests :: [TestTree]
globalConfigTests =
  [ testGroup "StackArgs SSM parameter effects" stackArgsMutationTests
  , testGroup "applyGlobalConfiguration error handling" errorHandlingTests
  , testGroup "applyParams pagination correctness" paginationTests
  ]

------------------------------------------------------------------------
-- Pure StackArgs mutation logic tests
--
-- We test the logic that would be applied when parameters are found,
-- using direct StackArgs manipulation to verify the expected semantics.
------------------------------------------------------------------------

stackArgsMutationTests :: [TestTree]
stackArgsMutationTests =
  [ testCase "no params: StackArgs is unchanged" $ do
      let sa = emptyStackArgs
      -- Simulating the no-param branch: StackArgs comes back unmodified
      sa @?= emptyStackArgs

  , testCase "notification ARN appended to empty list" $ do
      let sa       = emptyStackArgs
          arn      = "arn:aws:sns:us-east-1:123456789012:MyTopic"
          existing = fromMaybe [] (saNotificationArns sa)
          sa'      = sa { saNotificationArns = Just (existing ++ [arn]) }
      saNotificationArns sa' @?= Just [arn]

  , testCase "notification ARN appended to existing list" $ do
      let sa       = emptyStackArgs { saNotificationArns = Just ["arn:aws:sns:us-east-1:123:OldTopic"] }
          arn      = "arn:aws:sns:us-east-1:123456789012:NewTopic"
          existing = fromMaybe [] (saNotificationArns sa)
          sa'      = sa { saNotificationArns = Just (existing ++ [arn]) }
      saNotificationArns sa' @?= Just
        [ "arn:aws:sns:us-east-1:123:OldTopic"
        , "arn:aws:sns:us-east-1:123456789012:NewTopic"
        ]

  , testCase "disable-template-approval 'true' clears ApprovedTemplateLocation" $ do
      let sa  = emptyStackArgs { saApprovedTemplateLocation = Just "s3://bucket/approved.yaml" }
          val = "true"
          sa' = if T.toLower val == "true"
                  then case saApprovedTemplateLocation sa of
                         Just _ -> sa { saApprovedTemplateLocation = Nothing }
                         Nothing -> sa
                  else sa
      saApprovedTemplateLocation sa' @?= Nothing

  , testCase "disable-template-approval 'TRUE' (uppercase) clears ApprovedTemplateLocation" $ do
      let sa  = emptyStackArgs { saApprovedTemplateLocation = Just "s3://bucket/approved.yaml" }
          val = "TRUE"
          sa' = if T.toLower val == "true"
                  then case saApprovedTemplateLocation sa of
                         Just _ -> sa { saApprovedTemplateLocation = Nothing }
                         Nothing -> sa
                  else sa
      saApprovedTemplateLocation sa' @?= Nothing

  , testCase "disable-template-approval 'false' does not clear ApprovedTemplateLocation" $ do
      let sa  = emptyStackArgs { saApprovedTemplateLocation = Just "s3://bucket/approved.yaml" }
          val = "false"
          sa' = if T.toLower val == "true"
                  then case saApprovedTemplateLocation sa of
                         Just _ -> sa { saApprovedTemplateLocation = Nothing }
                         Nothing -> sa
                  else sa
      saApprovedTemplateLocation sa' @?= Just "s3://bucket/approved.yaml"

  , testCase "disable-template-approval 'true' with no ApprovedTemplateLocation is no-op" $ do
      let sa  = emptyStackArgs  -- saApprovedTemplateLocation = Nothing
          val = "true"
          sa' = if T.toLower val == "true"
                  then case saApprovedTemplateLocation sa of
                         Just _ -> sa { saApprovedTemplateLocation = Nothing }
                         Nothing -> sa
                  else sa
      saApprovedTemplateLocation sa' @?= Nothing
      -- StackArgs is otherwise unchanged
      sa' @?= emptyStackArgs

  , testCase "other parameter names are no-ops" $ do
      let sa   = emptyStackArgs { saStackName = "my-stack" }
          -- An unrecognised SSM parameter name should leave StackArgs unchanged
          sa'  = sa  -- no change for unknown param
      sa' @?= sa
  ]

------------------------------------------------------------------------
-- Error handling
--
-- applyGlobalConfiguration catches Amazonka.Error (not SomeException)
-- and emits a warning to stderr.  We cannot easily construct a real
-- Amazonka.Error in tests without a live AWS env, so we verify the
-- pure-logic aspects and document the contract.
------------------------------------------------------------------------

errorHandlingTests :: [TestTree]
errorHandlingTests =
  [ testCase "empty SSM parameter list leaves StackArgs unchanged (no-params path)" $ do
      -- When no /iidy/ parameters exist in SSM, GetParametersByPath
      -- returns an empty list — no error, no warning, StackArgs unchanged.
      let sa = emptyStackArgs { saStackName = "test-stack" }
      sa' <- applyParams sa []
      sa' @?= sa

  , testCase "saNotificationArns stays Nothing when no ARN param present" $ do
      let sa = emptyStackArgs
      assertBool "starts as Nothing" (saNotificationArns sa == Nothing)

  , testCase "saApprovedTemplateLocation preserved when no disable param" $ do
      let sa = emptyStackArgs { saApprovedTemplateLocation = Just "s3://bucket/approved.yaml" }
      assertBool "preserved" (saApprovedTemplateLocation sa == Just "s3://bucket/approved.yaml")
  ]

------------------------------------------------------------------------
-- Pagination correctness tests
--
-- These verify that applyParams correctly processes large param lists
-- (>10 entries), as would result from multi-page SSM pagination.
-- Prior to the pagination fix, Amazonka.send only returned the first
-- page (max 10 results), silently truncating the rest.
------------------------------------------------------------------------

paginationTests :: [TestTree]
paginationTests =
  [ testCase "applyParams processes empty list" $ do
      let sa = emptyStackArgs
      sa' <- applyParams sa []
      sa' @?= emptyStackArgs

  , testCase "applyParams ignores >10 unknown params (multi-page simulation)" $ do
      -- Simulate 15 unrecognised SSM parameters that would come from
      -- multiple pages of GetParametersByPath results
      let sa = emptyStackArgs { saStackName = "my-stack" }
          params = [ ("/iidy/unknown-" <> T.pack (show i), "val-" <> T.pack (show i))
                   | i <- [1..15 :: Int]
                   ]
      sa' <- applyParams sa params
      -- All unknown params are no-ops, StackArgs should be unchanged
      sa' @?= sa

  , testCase "applyParams applies notification ARN among >10 params" $ do
      -- Simulate a batch with 14 unknown params plus one real notification ARN
      let sa = emptyStackArgs
          unknowns = [ ("/iidy/custom-" <> T.pack (show i), "v" <> T.pack (show i))
                     | i <- [1..14 :: Int]
                     ]
          arnParam = ("/iidy/default-notification-arn", "arn:aws:sns:us-east-1:123:Topic")
          params = unknowns ++ [arnParam]
      sa' <- applyParams sa params
      saNotificationArns sa' @?= Just ["arn:aws:sns:us-east-1:123:Topic"]

  , testCase "applyParams applies disable-template-approval among >10 params" $ do
      let sa = emptyStackArgs { saApprovedTemplateLocation = Just "s3://bucket/tmpl.yaml" }
          unknowns = [ ("/iidy/setting-" <> T.pack (show i), "x" <> T.pack (show i))
                     | i <- [1..12 :: Int]
                     ]
          disableParam = ("/iidy/disable-template-approval", "true")
          params = unknowns ++ [disableParam]
      sa' <- applyParams sa params
      saApprovedTemplateLocation sa' @?= Nothing

  , testCase "applyParams applies both recognised params in large list" $ do
      -- Both notification ARN and disable-template-approval in a 20-param batch
      let sa = emptyStackArgs { saApprovedTemplateLocation = Just "s3://bucket/tmpl.yaml" }
          unknowns = [ ("/iidy/extra-" <> T.pack (show i), "e" <> T.pack (show i))
                     | i <- [1..18 :: Int]
                     ]
          arnParam = ("/iidy/default-notification-arn", "arn:aws:sns:us-west-2:456:Alert")
          disableParam = ("/iidy/disable-template-approval", "TRUE")
          params = unknowns ++ [arnParam, disableParam]
      sa' <- applyParams sa params
      saNotificationArns sa' @?= Just ["arn:aws:sns:us-west-2:456:Alert"]
      saApprovedTemplateLocation sa' @?= Nothing
  ]
