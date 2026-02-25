module Test.TemplateHashTest (templateHashTests) where

import qualified Data.Text as T
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Cfn.TemplateHash (calculateTemplateHash, generateVersionedLocation, parseS3Url)

templateHashTests :: [TestTree]
templateHashTests =
  [ testCase "calculateTemplateHash returns 64 hex chars" $ do
      let hash = calculateTemplateHash "hello world"
      T.length hash @?= 64
      assertBool "all hex" (T.all (\c -> c `elem` ("0123456789abcdef" :: String)) hash)

  , testCase "calculateTemplateHash is deterministic" $ do
      let h1 = calculateTemplateHash "test content"
          h2 = calculateTemplateHash "test content"
      h1 @?= h2

  , testCase "calculateTemplateHash different for different inputs" $ do
      let h1 = calculateTemplateHash "content A"
          h2 = calculateTemplateHash "content B"
      assertBool "different hashes" (h1 /= h2)

  , testCase "parseS3Url valid" $ do
      parseS3Url "s3://mybucket/mykey" @?= Right ("mybucket", "mykey")
      parseS3Url "s3://bucket/path/to/key" @?= Right ("bucket", "path/to/key")

  , testCase "parseS3Url invalid" $ do
      case parseS3Url "http://bucket/key" of
        Left _ -> pure ()
        Right _ -> assertFailure "Expected error for non-s3 URL"
      case parseS3Url "s3://bucket" of
        Left _ -> pure ()
        Right _ -> assertFailure "Expected error for no key"

  , testCase "generateVersionedLocation" $ do
      case generateVersionedLocation "s3://mybucket/templates/" "hello" "template.yaml" of
        Left err -> assertFailure (T.unpack err)
        Right (bucket, key) -> do
          bucket @?= "mybucket"
          assertBool "key starts with templates/" (T.isPrefixOf "templates/" key)
          assertBool "key ends with .yaml" (T.isSuffixOf ".yaml" key)
          assertBool "key has hash" (T.length key > 20)
  ]
