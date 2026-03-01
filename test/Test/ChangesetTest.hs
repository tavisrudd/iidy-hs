{-# LANGUAGE DisambiguateRecordFields #-}
module Test.ChangesetTest (changesetTests) where

import Data.List (nub)
import qualified Data.Text as T
import qualified Amazonka
import qualified Amazonka.Types as AT
import qualified Amazonka.CloudFormation.Types as CF
import qualified Amazonka.CloudFormation.Types.Change as CChange
import qualified Amazonka.CloudFormation.Types.ResourceChange as CRC
import qualified Amazonka.CloudFormation.Types.ResourceChangeDetail as CRCD
import qualified Amazonka.CloudFormation.Types.ResourceTargetDefinition as CRTD
import Network.HTTP.Types.Status (status400)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Cfn.Operations.Changeset (convertChange, convertDetail, generateDashedName, formatAmazonkaError, isNonRetryableError)
import Iidy.Output.Types (ChangeInfo(..), ChangeDetail(..))

changesetTests :: [TestTree]
changesetTests =
  [ testCase "convertChange: Nothing resourceChange returns Nothing" $ do
      let ch = CChange.newChange
      convertChange ch @?= Nothing

  , testCase "convertChange: missing logicalResourceId returns Nothing" $ do
      let rc = CRC.newResourceChange { CRC.resourceType = Just "AWS::S3::Bucket" }
          ch = CChange.newChange { CChange.resourceChange = Just rc }
      convertChange ch @?= Nothing

  , testCase "convertChange: missing resourceType returns Nothing" $ do
      let rc = CRC.newResourceChange { CRC.logicalResourceId = Just "MyBucket" }
          ch = CChange.newChange { CChange.resourceChange = Just rc }
      convertChange ch @?= Nothing

  , testCase "convertChange: valid change extracts fields" $ do
      let rc = CRC.newResourceChange
                 { CRC.logicalResourceId = Just "MyBucket"
                 , CRC.resourceType = Just "AWS::S3::Bucket"
                 , CRC.physicalResourceId = Just "arn:aws:s3:::my-bucket"
                 , CRC.action = Just CF.ChangeAction_Add
                 }
          ch = CChange.newChange { CChange.resourceChange = Just rc }
      case convertChange ch of
        Nothing -> assertFailure "Expected Just ChangeInfo"
        Just ci -> do
          ciLogicalResourceId ci @?= "MyBucket"
          ciResourceType ci @?= "AWS::S3::Bucket"
          ciPhysicalResourceId ci @?= Just "arn:aws:s3:::my-bucket"
          ciAction ci @?= "Add"

  , testCase "convertChange: minimal valid change (no optionals)" $ do
      let rc = CRC.newResourceChange
                 { CRC.logicalResourceId = Just "MyFunc"
                 , CRC.resourceType = Just "AWS::Lambda::Function"
                 }
          ch = CChange.newChange { CChange.resourceChange = Just rc }
      case convertChange ch of
        Nothing -> assertFailure "Expected Just ChangeInfo"
        Just ci -> do
          ciLogicalResourceId ci @?= "MyFunc"
          ciResourceType ci @?= "AWS::Lambda::Function"
          ciPhysicalResourceId ci @?= Nothing
          ciReplacement ci @?= Nothing
          ciScope ci @?= Nothing
          ciDetails ci @?= []

  , testCase "convertDetail: all fields populated" $ do
      let tgt = CRTD.newResourceTargetDefinition
                  { CRTD.attribute = Just CF.ResourceAttribute_Properties }
          det = CRCD.newResourceChangeDetail
                  { CRCD.target = Just tgt
                  , CRCD.evaluation = Just CF.EvaluationType_Static
                  , CRCD.changeSource = Just CF.ChangeSource_DirectModification
                  , CRCD.causingEntity = Just "MyParam"
                  }
          cd = convertDetail det
      cdTarget cd @?= "Properties"
      cdEvaluation cd @?= Just "Static"
      cdChangeSource cd @?= Just "DirectModification"
      cdCausingEntity cd @?= Just "MyParam"

  , testCase "convertDetail: empty detail" $ do
      let det = CRCD.newResourceChangeDetail
          cd = convertDetail det
      cdTarget cd @?= ""
      cdEvaluation cd @?= Nothing
      cdChangeSource cd @?= Nothing
      cdCausingEntity cd @?= Nothing

  , testCase "generateDashedName: produces adjective-noun format" $ do
      name <- generateDashedName
      let parts = T.splitOn "-" name
      assertEqual "should have exactly 2 parts" 2 (length parts)
      case parts of
        [adj, noun] -> do
          assertBool "adjective should not be empty" (T.length adj > 0)
          assertBool "noun should not be empty" (T.length noun > 0)
        _ -> assertFailure "expected exactly 2 parts"

  , testCase "generateDashedName: produces non-empty name" $ do
      name <- generateDashedName
      assertBool "name should not be empty" (T.length name > 0)
      assertBool "name should contain a dash" (T.isInfixOf "-" name)

  , testCase "generateDashedName: different calls can produce different names" $ do
      names <- mapM (\_ -> generateDashedName) [(1::Int)..10]
      let uniqueNames = length (nub names)
      assertBool "should produce some variety" (uniqueNames > 1)

  -- formatAmazonkaError tests
  , testGroup "formatAmazonkaError"
    [ testCase "extracts code and message from ServiceError" $
        formatAmazonkaError (mkServiceError "ValidationError" "Stack does not exist")
          @?= "ValidationError: Stack does not exist"
    , testCase "handles ServiceError with no message" $
        formatAmazonkaError (mkServiceErrorNoMsg "InternalFailure")
          @?= "InternalFailure: "
    , testCase "falls back to show for non-ServiceError" $ do
        let err = formatAmazonkaError (mkSerializeError "parse failure")
        assertBool "should contain error info" (T.length err > 0)
    ]

  -- isNonRetryableError tests
  , testGroup "isNonRetryableError"
    [ testCase "ChangeSetNotFoundException is non-retryable" $
        isNonRetryableError (mkServiceError "ChangeSetNotFoundException" "not found") @?= True
    , testCase "AccessDeniedException is non-retryable" $
        isNonRetryableError (mkServiceError "AccessDeniedException" "denied") @?= True
    , testCase "ValidationError is non-retryable" $
        isNonRetryableError (mkServiceError "ValidationError" "invalid") @?= True
    , testCase "Throttling is retryable" $
        isNonRetryableError (mkServiceError "Throttling" "rate exceeded") @?= False
    , testCase "InternalFailure is retryable" $
        isNonRetryableError (mkServiceError "InternalFailure" "oops") @?= False
    , testCase "non-ServiceError is retryable" $
        isNonRetryableError (mkSerializeError "parse") @?= False
    ]
  ]
  where
    mkServiceError :: T.Text -> T.Text -> Amazonka.Error
    mkServiceError code msg =
      Amazonka.ServiceError (AT.ServiceError' "CloudFormation" status400 []
        (Amazonka.ErrorCode code) (Just (Amazonka.ErrorMessage msg)) Nothing)

    mkServiceErrorNoMsg :: T.Text -> Amazonka.Error
    mkServiceErrorNoMsg code =
      Amazonka.ServiceError (AT.ServiceError' "CloudFormation" status400 []
        (Amazonka.ErrorCode code) Nothing Nothing)

    mkSerializeError :: String -> Amazonka.Error
    mkSerializeError msg =
      Amazonka.SerializeError (AT.SerializeError' "CloudFormation" status400 Nothing msg)
