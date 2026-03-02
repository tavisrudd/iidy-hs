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

import Iidy.Cfn.RequestBuilder (toAmazonkaCapability, mapCapabilities, mapParameters, mapTags, toAmazonkaOnFailure, serializeStackPolicy)
import Iidy.Cfn.Types (Capability(..), OnFailure(..))

requestBuilderTests :: [TestTree]
requestBuilderTests =
  [ testCase "toAmazonkaCapability: CapIAM" $
      toAmazonkaCapability CapIAM @?= CF.Capability_CAPABILITY_IAM

  , testCase "toAmazonkaCapability: CapNamedIAM" $
      toAmazonkaCapability CapNamedIAM @?= CF.Capability_CAPABILITY_NAMED_IAM

  , testCase "toAmazonkaCapability: CapAutoExpand" $
      toAmazonkaCapability CapAutoExpand @?= CF.Capability_CAPABILITY_AUTO_EXPAND

  , testCase "mapCapabilities: Nothing -> Nothing" $
      mapCapabilities Nothing @?= Nothing

  , testCase "mapCapabilities: empty list -> Nothing" $
      mapCapabilities (Just []) @?= Nothing

  , testCase "mapCapabilities: maps all values" $
      mapCapabilities (Just [CapIAM, CapNamedIAM])
        @?= Just [CF.Capability_CAPABILITY_IAM, CF.Capability_CAPABILITY_NAMED_IAM]

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

  , testCase "toAmazonkaOnFailure: Delete" $
      toAmazonkaOnFailure Delete @?= CF.OnFailure_DELETE

  , testCase "toAmazonkaOnFailure: Rollback" $
      toAmazonkaOnFailure Rollback @?= CF.OnFailure_ROLLBACK

  , testCase "toAmazonkaOnFailure: DoNothing" $
      toAmazonkaOnFailure DoNothing @?= CF.OnFailure_DO_NOTHING

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
