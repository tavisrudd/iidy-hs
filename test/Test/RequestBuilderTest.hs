{-# LANGUAGE DisambiguateRecordFields #-}
module Test.RequestBuilderTest (requestBuilderTests) where

import qualified Data.Map.Strict
import qualified Amazonka.CloudFormation.Types as CF
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Cfn.RequestBuilder (mapCapability, mapCapabilities, mapParameters, mapTags, mapOnFailure)

requestBuilderTests :: [TestTree]
requestBuilderTests =
  [ testCase "mapCapability: CAPABILITY_IAM" $
      mapCapability "CAPABILITY_IAM" @?= Just CF.Capability_CAPABILITY_IAM

  , testCase "mapCapability: CAPABILITY_NAMED_IAM" $
      mapCapability "CAPABILITY_NAMED_IAM" @?= Just CF.Capability_CAPABILITY_NAMED_IAM

  , testCase "mapCapability: CAPABILITY_AUTO_EXPAND" $
      mapCapability "CAPABILITY_AUTO_EXPAND" @?= Just CF.Capability_CAPABILITY_AUTO_EXPAND

  , testCase "mapCapability: case insensitive" $
      mapCapability "capability_iam" @?= Just CF.Capability_CAPABILITY_IAM

  , testCase "mapCapability: unknown returns Nothing" $
      mapCapability "INVALID_CAP" @?= Nothing

  , testCase "mapCapabilities: Nothing -> Nothing" $
      mapCapabilities Nothing @?= Nothing

  , testCase "mapCapabilities: empty list -> Nothing" $
      mapCapabilities (Just []) @?= Nothing

  , testCase "mapCapabilities: filters invalid" $
      mapCapabilities (Just ["CAPABILITY_IAM", "INVALID"])
        @?= Just [CF.Capability_CAPABILITY_IAM]

  , testCase "mapParameters: Nothing -> Nothing" $
      mapParameters Nothing @?= Nothing

  , testCase "mapParameters: empty map -> Nothing" $
      mapParameters (Just Data.Map.Strict.empty) @?= Nothing

  , testCase "mapParameters: non-empty map has params" $
      let result = mapParameters (Just (Data.Map.Strict.singleton "key" "value"))
      in assertBool "Just with params" (result /= Nothing)

  , testCase "mapTags: Nothing -> Nothing" $
      mapTags Nothing @?= Nothing

  , testCase "mapTags: empty map -> Nothing" $
      mapTags (Just Data.Map.Strict.empty) @?= Nothing

  , testCase "mapTags: non-empty map has tags" $
      let result = mapTags (Just (Data.Map.Strict.singleton "env" "prod"))
      in assertBool "Just with tags" (result /= Nothing)

  , testCase "mapOnFailure: DELETE" $
      mapOnFailure (Just "DELETE") @?= Just CF.OnFailure_DELETE

  , testCase "mapOnFailure: ROLLBACK" $
      mapOnFailure (Just "ROLLBACK") @?= Just CF.OnFailure_ROLLBACK

  , testCase "mapOnFailure: DO_NOTHING" $
      mapOnFailure (Just "DO_NOTHING") @?= Just CF.OnFailure_DO_NOTHING

  , testCase "mapOnFailure: case insensitive" $
      mapOnFailure (Just "delete") @?= Just CF.OnFailure_DELETE

  , testCase "mapOnFailure: Nothing -> Nothing" $
      mapOnFailure Nothing @?= Nothing

  , testCase "mapOnFailure: unknown -> Nothing" $
      mapOnFailure (Just "INVALID") @?= Nothing
  ]
