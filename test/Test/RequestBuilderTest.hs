{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
module Test.RequestBuilderTest (requestBuilderTests) where

import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Amazonka.CloudFormation.Types as CF
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Cfn.RequestBuilder (mapCapability, mapCapabilities, mapParameters, mapTags, mapOnFailure, serializeStackPolicy)

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

  , testCase "serializeStackPolicy: Nothing -> Nothing" $
      serializeStackPolicy Nothing @?= Nothing

  , testCase "serializeStackPolicy: serializes JSON object to text" $ do
      let policy = Aeson.object [ "Statement" Aeson..= ([] :: [Aeson.Value]) ]
      case serializeStackPolicy (Just policy) of
        Just txt -> assertBool "contains Statement" (T.isInfixOf "Statement" txt)
        Nothing -> assertFailure "expected Just"

  , testCase "serializeStackPolicy: round-trips through JSON decode" $ do
      let policy = Aeson.object
            [ "Statement" Aeson..= ([] :: [Aeson.Value])
            , "Effect" Aeson..= ("Allow" :: Text)
            ]
      case serializeStackPolicy (Just policy) of
        Just txt -> case Aeson.decodeStrict (TE.encodeUtf8 txt) of
          Just (v :: Aeson.Value) -> v @?= policy
          Nothing -> assertFailure "failed to parse serialized policy"
        Nothing -> assertFailure "expected Just"
  ]
