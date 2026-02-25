module Test.ParserTest (parserTests) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Yaml.Parser (parseYaml)

parserTests :: [TestTree]
parserTests =
  [ testCase "parse null" $ do
      let input = "null\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse simple mapping" $ do
      let input = "key: value\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse sequence" $ do
      let input = "- a\n- b\n- c\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse boolean true" $ do
      let input = "true\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse integer" $ do
      let input = "42\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse float" $ do
      let input = "3.14\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse nested mapping" $ do
      let input = "outer:\n  inner: value\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "detect templated string" $ do
      let input = "key: '{{foo}}'\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "detect preprocessing tag" $ do
      let input = "key: !$ myvar\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "detect CloudFormation Ref tag" $ do
      let input = "key: !Ref Bucket\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "detect CloudFormation Sub tag" $ do
      let input = "key: !Sub '${AWS::Region}-bucket'\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse empty document" $ do
      let input = "~\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()
  ]
