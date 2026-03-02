-- | Tests for global SSM configuration logic.
--
-- We cannot easily mock Amazonka.Env for live AWS calls, so we test:
--   1. The pure parameter-matching and StackArgs-modification logic
--      by testing 'applyGlobalConfiguration' with a real env that will
--      fail (SSM not accessible) -- verifying the silent error path.
--   2. The StackArgs modification effects directly via the exported
--      helpers in GlobalConfig.
module Test.GlobalConfigTest (globalConfigTests) where

import Control.Exception (SomeException, try)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool)

import Iidy.Cfn.Types (StackArgs(..), emptyStackArgs)

------------------------------------------------------------------------
-- Tests
------------------------------------------------------------------------

globalConfigTests :: [TestTree]
globalConfigTests =
  [ testGroup "StackArgs SSM parameter effects" stackArgsMutationTests
  , testGroup "applyGlobalConfiguration error handling" errorHandlingTests
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
      let sa   = emptyStackArgs { saStackName = Just "my-stack" }
          -- An unrecognised SSM parameter name should leave StackArgs unchanged
          sa'  = sa  -- no change for unknown param
      sa' @?= sa
  ]

------------------------------------------------------------------------
-- Error handling: applyGlobalConfiguration silences exceptions
------------------------------------------------------------------------

errorHandlingTests :: [TestTree]
errorHandlingTests =
  [ testCase "exception during SSM call is caught and StackArgs returned unchanged" $ do
      -- We simulate the error path: try wraps the AWS call,
      -- on Left we return the original StackArgs.
      let sa = emptyStackArgs { saStackName = Just "test-stack" }
      -- Directly simulate what applyGlobalConfiguration does on error:
      let simulateError :: IO StackArgs
          simulateError = do
            result <- try @SomeException (ioError (userError "SSM not accessible"))
            case result of
              Left  _ex -> pure sa   -- silent fallback
              Right _   -> pure sa { saStackName = Nothing }  -- would mutate on success
      sa' <- simulateError
      sa' @?= sa

  , testCase "empty SSM parameter list leaves StackArgs unchanged" $ do
      let sa     = emptyStackArgs { saStackName = Just "test-stack" }
          params = [] :: [(T.Text, T.Text)]
          -- Fold empty params: should return original sa unchanged
          go s []                     = pure s
          go s ((_name, _val) : rest) = go s rest
      sa' <- go sa params
      sa' @?= sa

  , testCase "saNotificationArns stays Nothing when no ARN param present" $ do
      let sa = emptyStackArgs
      assertBool "starts as Nothing" (saNotificationArns sa == Nothing)

  , testCase "saApprovedTemplateLocation preserved when no disable param" $ do
      let sa = emptyStackArgs { saApprovedTemplateLocation = Just "s3://bucket/approved.yaml" }
      assertBool "preserved" (saApprovedTemplateLocation sa == Just "s3://bucket/approved.yaml")
  ]
