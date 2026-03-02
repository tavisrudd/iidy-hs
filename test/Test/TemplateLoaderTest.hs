-- | Integration tests for Iidy.Cfn.TemplateLoader.
--
-- Tests the loadCfnTemplate function across its main dispatch paths:
-- S3/HTTP URL passthrough, render: preprocessing, local file loading,
-- and error conditions (returned as Left values).
module Test.TemplateLoaderTest (templateLoaderTests) where

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
      case result of
        Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
        Right tr -> do
          trTemplateUrl  tr @?= Just "s3://my-bucket/cfn/template.yaml"
          trTemplateBody tr @?= Nothing

  , testCase "https://s3... URL returned as trTemplateUrl" $ do
      result <- loadCfnTemplate (Just "https://s3.amazonaws.com/bucket/key.yaml") Nothing "" Nothing
      case result of
        Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
        Right tr -> do
          trTemplateUrl  tr @?= Just "https://s3.amazonaws.com/bucket/key.yaml"
          trTemplateBody tr @?= Nothing

  , testCase "https:// URL returned as trTemplateUrl" $ do
      result <- loadCfnTemplate (Just "https://example.com/template.yaml") Nothing "" Nothing
      case result of
        Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
        Right tr -> do
          trTemplateUrl  tr @?= Just "https://example.com/template.yaml"
          trTemplateBody tr @?= Nothing

  , testCase "http:// URL returned as trTemplateUrl" $ do
      result <- loadCfnTemplate (Just "http://example.com/template.yaml") Nothing "" Nothing
      case result of
        Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
        Right tr -> do
          trTemplateUrl  tr @?= Just "http://example.com/template.yaml"
          trTemplateBody tr @?= Nothing

  , testCase "Nothing input returns empty result" $ do
      result <- loadCfnTemplate Nothing Nothing "" Nothing
      case result of
        Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
        Right tr -> do
          trTemplateUrl  tr @?= Nothing
          trTemplateBody tr @?= Nothing
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
      case result of
        Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
        Right tr -> do
          assertBodyPresent tr
          assertNoTemplateUrl tr

  , testCase "render: body does not contain $defs: or $imports: keys" $ do
      result <- loadCfnTemplate
        (Just "render:simple.yaml")
        (Just argsfileInFixtureDir)
        "dev"
        Nothing
      case result of
        Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
        Right tr -> do
          let body = extractBody tr
          assertBool "no $defs: in output"    (not ("$defs:"    `T.isInfixOf` body))
          assertBool "no $imports: in output" (not ("$imports:" `T.isInfixOf` body))

  , testCase "render: with $defs resolves variable references" $ do
      result <- loadCfnTemplate
        (Just "render:with-defs.yaml")
        (Just argsfileInFixtureDir)
        "dev"
        Nothing
      case result of
        Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
        Right tr -> do
          let body = extractBody tr
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
      case result of
        Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
        Right tr -> do
          assertBodyPresent tr
          let body = extractBody tr
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
      case result of
        Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
        Right tr -> do
          assertBodyPresent tr
          assertNoTemplateUrl tr

  , testCase "local file body contains AWSTemplateFormatVersion" $ do
      result <- loadCfnTemplate
        (Just "test-fixtures/template-loader/simple.yaml")
        Nothing
        "dev"
        Nothing
      case result of
        Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
        Right tr -> do
          let body = extractBody tr
          assertBool "body has version key" ("AWSTemplateFormatVersion" `T.isInfixOf` body)
  ]

------------------------------------------------------------------------
-- Failure paths
------------------------------------------------------------------------

failureTests :: [TestTree]
failureTests =
  [ testCase "render: with malformed YAML returns Left with parse error" $
      withSystemTempDirectory "tpl-loader-malformed" $ \dir -> do
        let fp = dir </> "malformed.yaml"
        BS.writeFile fp "key: [\n  unclosed: bracket"
        result <- loadCfnTemplate
          (Just (T.pack ("render:" <> fp)))
          Nothing
          "dev"
          Nothing
        case result of
          Right _ -> assertFailure "expected Left for malformed YAML"
          Left err ->
            assertBool "error mentions 'Parse error'"
              ("Parse error" `T.isInfixOf` err)

  , testCase "local file with $imports: but no render: prefix returns Left" $
      withSystemTempDirectory "tpl-loader-imports" $ \dir -> do
        let fp = dir </> "has-imports.yaml"
        BS.writeFile fp "$imports:\n  x: env:HOME\nResources: {}\n"
        result <- loadCfnTemplate
          (Just (T.pack fp))
          Nothing
          "dev"
          Nothing
        case result of
          Right _ -> assertFailure "expected Left for $imports: without render:"
          Left err ->
            assertBool "error mentions 'render:'"
              ("render:" `T.isInfixOf` err)

  , testCase "render: with AWS import but no AWS env returns Left" $
      withSystemTempDirectory "tpl-loader-ssm" $ \dir -> do
        let fp = dir </> "uses-ssm.yaml"
        BS.writeFile fp "$imports:\n  dbPass: ssm:/my/param\nAWSTemplateFormatVersion: \"2010-09-09\"\nResources: {}\n"
        result <- loadCfnTemplate
          (Just (T.pack ("render:" <> fp)))
          Nothing
          "dev"
          Nothing
        case result of
          Right _ -> assertFailure "expected Left for AWS import without credentials"
          Left err ->
            assertBool "error mentions AWS credentials or Preprocess error"
              (  "AWS import type requires credentials" `T.isInfixOf` err
              || "Preprocess error" `T.isInfixOf` err
              )

  , testCase "local file with invalid UTF-8 bytes returns Left" $
      withSystemTempDirectory "tpl-loader-utf8" $ \dir -> do
        let fp = dir </> "bad-utf8.yaml"
        -- Write bytes that are invalid UTF-8: 0xFF 0xFE are not valid UTF-8 lead bytes
        BS.writeFile fp (BS.pack [0xFF, 0xFE, 0x00, 0x01])
        result <- loadCfnTemplate
          (Just (T.pack fp))
          Nothing
          "dev"
          Nothing
        case result of
          Right _ -> assertFailure "expected Left for invalid UTF-8 file"
          Left err ->
            assertBool "error mentions 'Invalid UTF-8'"
              ("Invalid UTF-8" `T.isInfixOf` err)

  , testCase "render: template exceeding size limit returns Left" $
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
        result <- loadCfnTemplate
          (Just (T.pack ("render:" <> fp)))
          Nothing
          "dev"
          Nothing
        case result of
          Right _ -> assertFailure "expected Left for oversized template"
          Left err ->
            assertBool "error mentions size limit"
              ("exceeds maximum size" `T.isInfixOf` err)

  , testCase "inline content with $imports: returns Left" $ do
      result <- loadCfnTemplate
        (Just "$imports:\n  x: env:HOME\nResources: {}")
        Nothing
        "dev"
        Nothing
      case result of
        Right _ -> assertFailure "expected Left for inline $imports: without render:"
        Left err ->
          assertBool "error mentions 'render:'"
            ("render:" `T.isInfixOf` err)

  , testCase "missing file treated as inline content (not an error)" $ do
      -- A non-existent file path that doesn't contain $imports: is treated as
      -- inline template content, not as a missing-file error.
      result <- loadCfnTemplate
        (Just "nonexistent-file-as-inline-content")
        Nothing
        "dev"
        Nothing
      case result of
        Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
        Right tr ->
          trTemplateBody tr @?= Just "nonexistent-file-as-inline-content"
  ]

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Assert that trTemplateBody is present.
assertBodyPresent :: TemplateResult -> IO ()
assertBodyPresent tr =
  case trTemplateBody tr of
    Nothing -> assertFailure "expected trTemplateBody to be Just, got Nothing"
    Just body -> assertBool "body is non-empty" (not (T.null body))

-- | Assert that trTemplateUrl is Nothing.
assertNoTemplateUrl :: TemplateResult -> IO ()
assertNoTemplateUrl tr =
  case trTemplateUrl tr of
    Nothing -> pure ()
    Just url -> assertFailure $ "expected trTemplateUrl = Nothing, got: " <> T.unpack url

-- | Extract the body from a TemplateResult; fail if absent.
extractBody :: TemplateResult -> T.Text
extractBody tr =
  case trTemplateBody tr of
    Just body -> body
    Nothing   -> error "extractBody: trTemplateBody is Nothing (test setup error)"
