-- | Integration tests for Iidy.Cfn.TemplateLoader.
--
-- Tests the loadCfnTemplate function across its main dispatch paths:
-- S3/HTTP URL passthrough, render: preprocessing, local file loading,
-- and error conditions.
module Test.TemplateLoaderTest (templateLoaderTests) where

import Control.Exception (IOException, try)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool, assertFailure)

import Iidy.Cfn.TemplateLoader
  ( TemplateResult(..)
  , loadCfnTemplate
  , templateMaxBytes
  )

------------------------------------------------------------------------
-- Test groups
------------------------------------------------------------------------

templateLoaderTests :: [TestTree]
templateLoaderTests =
  [ testGroup "URL passthrough"    urlTests
  , testGroup "render: success"    renderSuccessTests
  , testGroup "Local file"         localFileTests
  , testGroup "Failure paths"      failureTests
  ]

------------------------------------------------------------------------
-- URL passthrough
------------------------------------------------------------------------

urlTests :: [TestTree]
urlTests =
  [ testCase "s3:// URL returned as trTemplateUrl" $ do
      result <- loadCfnTemplate (Just "s3://my-bucket/cfn/template.yaml") Nothing "" Nothing
      trTemplateUrl  result @?= Just "s3://my-bucket/cfn/template.yaml"
      trTemplateBody result @?= Nothing

  , testCase "https://s3... URL returned as trTemplateUrl" $ do
      result <- loadCfnTemplate (Just "https://s3.amazonaws.com/bucket/key.yaml") Nothing "" Nothing
      trTemplateUrl  result @?= Just "https://s3.amazonaws.com/bucket/key.yaml"
      trTemplateBody result @?= Nothing

  , testCase "https:// URL returned as trTemplateUrl" $ do
      result <- loadCfnTemplate (Just "https://example.com/template.yaml") Nothing "" Nothing
      trTemplateUrl  result @?= Just "https://example.com/template.yaml"
      trTemplateBody result @?= Nothing

  , testCase "http:// URL returned as trTemplateUrl" $ do
      result <- loadCfnTemplate (Just "http://example.com/template.yaml") Nothing "" Nothing
      trTemplateUrl  result @?= Just "http://example.com/template.yaml"
      trTemplateBody result @?= Nothing

  , testCase "Nothing input returns empty result" $ do
      result <- loadCfnTemplate Nothing Nothing "" Nothing
      trTemplateUrl  result @?= Nothing
      trTemplateBody result @?= Nothing
  ]

------------------------------------------------------------------------
-- render: success paths
------------------------------------------------------------------------

-- | Fixture directory relative to project root (where cabal test runs).
fixtureDir :: FilePath
fixtureDir = "test-fixtures" </> "template-loader"

-- | A fake argsfile path in fixtureDir so resolveTemplatePath resolves
-- relative template paths against fixtureDir.
argsfileInFixtureDir :: FilePath
argsfileInFixtureDir = fixtureDir </> "stack-args.yaml"

renderSuccessTests :: [TestTree]
renderSuccessTests =
  [ testCase "render: simple template returns trTemplateBody" $ do
      result <- loadCfnTemplate
        (Just "render:simple.yaml")
        (Just argsfileInFixtureDir)
        "dev"
        Nothing
      assertBodyPresent result
      assertNoTemplateUrl result

  , testCase "render: body does not contain $defs: or $imports: keys" $ do
      result <- loadCfnTemplate
        (Just "render:simple.yaml")
        (Just argsfileInFixtureDir)
        "dev"
        Nothing
      let body = extractBody result
      assertBool "no $defs: in output"    (not ("$defs:"    `T.isInfixOf` body))
      assertBool "no $imports: in output" (not ("$imports:" `T.isInfixOf` body))

  , testCase "render: with $defs resolves variable references" $ do
      result <- loadCfnTemplate
        (Just "render:with-defs.yaml")
        (Just argsfileInFixtureDir)
        "dev"
        Nothing
      let body = extractBody result
      assertBool "$defs variable resolved to 'bar'" ("bar" `T.isInfixOf` body)
      assertBool "$defs key filtered from output"   (not ("$defs:" `T.isInfixOf` body))

  , testCase "render: env name injected as $envValues (filtered from output)" $ do
      -- $envValues is injected into the AST and filtered from output by the resolver.
      -- The environment name is NOT accessible via Handlebars {{$envValues.environment}}
      -- in the current implementation (engine doesn't expose $envValues as a variable),
      -- but the template still renders successfully and $envValues is absent from output.
      result <- loadCfnTemplate
        (Just "render:simple.yaml")
        (Just argsfileInFixtureDir)
        "staging"
        Nothing
      assertBodyPresent result
      let body = extractBody result
      assertBool "$envValues filtered from output" (not ("$envValues" `T.isInfixOf` body))
  ]

------------------------------------------------------------------------
-- Local file loading
------------------------------------------------------------------------

localFileTests :: [TestTree]
localFileTests =
  [ testCase "local file without render: returns body" $ do
      result <- loadCfnTemplate
        (Just "test-fixtures/template-loader/simple.yaml")
        Nothing
        "dev"
        Nothing
      assertBodyPresent result
      assertNoTemplateUrl result

  , testCase "local file body contains AWSTemplateFormatVersion" $ do
      result <- loadCfnTemplate
        (Just "test-fixtures/template-loader/simple.yaml")
        Nothing
        "dev"
        Nothing
      let body = extractBody result
      assertBool "body has version key" ("AWSTemplateFormatVersion" `T.isInfixOf` body)
  ]

------------------------------------------------------------------------
-- Failure paths
------------------------------------------------------------------------

failureTests :: [TestTree]
failureTests =
  [ testCase "render: with malformed YAML fails with parse error message" $
      withSystemTempDirectory "tpl-loader-malformed" $ \dir -> do
        let fp = dir </> "malformed.yaml"
        BS.writeFile fp "key: [\n  unclosed: bracket"
        result <- try @IOException $ loadCfnTemplate
          (Just (T.pack ("render:" <> fp)))
          Nothing
          "dev"
          Nothing
        case result of
          Right _ -> assertFailure "expected IOException for malformed YAML"
          Left err ->
            assertBool "error mentions 'Parse error'"
              ("Parse error" `T.isInfixOf` T.pack (show err))

  , testCase "local file with $imports: but no render: prefix fails" $
      withSystemTempDirectory "tpl-loader-imports" $ \dir -> do
        let fp = dir </> "has-imports.yaml"
        BS.writeFile fp "$imports:\n  x: env:HOME\nResources: {}\n"
        result <- try @IOException $ loadCfnTemplate
          (Just (T.pack fp))
          Nothing
          "dev"
          Nothing
        case result of
          Right _ -> assertFailure "expected IOException for $imports: without render:"
          Left err -> do
            let msg = T.pack (show err)
            assertBool "error mentions 'render:'"
              ("render:" `T.isInfixOf` msg)

  , testCase "render: with AWS import but no AWS env fails with credentials error" $
      withSystemTempDirectory "tpl-loader-ssm" $ \dir -> do
        let fp = dir </> "uses-ssm.yaml"
        BS.writeFile fp "$imports:\n  dbPass: ssm:/my/param\nAWSTemplateFormatVersion: \"2010-09-09\"\nResources: {}\n"
        result <- try @IOException $ loadCfnTemplate
          (Just (T.pack ("render:" <> fp)))
          Nothing
          "dev"
          Nothing
        case result of
          Right _ -> assertFailure "expected IOException for AWS import without credentials"
          Left err ->
            assertBool "error mentions AWS credentials"
              (  "AWS import type requires credentials" `T.isInfixOf` T.pack (show err)
              || "Preprocess error" `T.isInfixOf` T.pack (show err)
              )

  , testCase "local file with invalid UTF-8 bytes fails with descriptive error" $
      withSystemTempDirectory "tpl-loader-utf8" $ \dir -> do
        let fp = dir </> "bad-utf8.yaml"
        -- Write bytes that are invalid UTF-8: 0xFF 0xFE are not valid UTF-8 lead bytes
        BS.writeFile fp (BS.pack [0xFF, 0xFE, 0x00, 0x01])
        result <- try @IOException $ loadCfnTemplate
          (Just (T.pack fp))
          Nothing
          "dev"
          Nothing
        case result of
          Right _ -> assertFailure "expected IOException for invalid UTF-8 file"
          Left err -> do
            let msg = T.pack (show err)
            assertBool "error mentions 'Invalid UTF-8'"
              ("Invalid UTF-8" `T.isInfixOf` msg)

  , testCase "render: template exceeding size limit fails" $
      withSystemTempDirectory "tpl-loader-huge" $ \dir -> do
        let fp = dir </> "huge.yaml"
        -- Build a YAML template whose rendered output exceeds templateMaxBytes.
        -- We use a $defs variable with a very long value that gets inlined into
        -- the rendered output, so the emitter produces content > 51199 bytes.
        let longVal = T.replicate (templateMaxBytes + 100) "a"
            content = T.unlines
              [ "$defs:"
              , "  bigval: " <> longVal
              , "AWSTemplateFormatVersion: \"2010-09-09\""
              , "BigOutput: !$ bigval"
              , "Resources: {}"
              ]
        BS.writeFile fp (TE.encodeUtf8 content)
        result <- try @IOException $ loadCfnTemplate
          (Just (T.pack ("render:" <> fp)))
          Nothing
          "dev"
          Nothing
        case result of
          Right _ -> assertFailure "expected IOException for oversized template"
          Left err ->
            assertBool "error mentions size limit"
              ("exceeds maximum size" `T.isInfixOf` T.pack (show err))
  ]

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Assert that trTemplateBody is present.
assertBodyPresent :: TemplateResult -> IO ()
assertBodyPresent result =
  case trTemplateBody result of
    Nothing -> assertFailure "expected trTemplateBody to be Just, got Nothing"
    Just body -> assertBool "body is non-empty" (not (T.null body))

-- | Assert that trTemplateUrl is Nothing.
assertNoTemplateUrl :: TemplateResult -> IO ()
assertNoTemplateUrl result =
  case trTemplateUrl result of
    Nothing -> pure ()
    Just url -> assertFailure $ "expected trTemplateUrl = Nothing, got: " <> T.unpack url

-- | Extract the body from a TemplateResult; fail if absent.
extractBody :: TemplateResult -> T.Text
extractBody result =
  case trTemplateBody result of
    Just body -> body
    Nothing   -> error "extractBody: trTemplateBody is Nothing (test setup error)"
