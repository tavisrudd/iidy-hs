{-# LANGUAGE DisambiguateRecordFields #-}
module Test.ChangesetTest (changesetTests) where

import Data.List (nub)
import qualified Data.Text as T
import qualified Amazonka.CloudFormation.Types as CF
import qualified Amazonka.CloudFormation.Types.Change as CChange
import qualified Amazonka.CloudFormation.Types.ResourceChange as CRC
import qualified Amazonka.CloudFormation.Types.ResourceChangeDetail as CRCD
import qualified Amazonka.CloudFormation.Types.ResourceTargetDefinition as CRTD
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Cfn.Operations.Changeset (convertChange, convertDetail, generateDashedName)
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
  ]
