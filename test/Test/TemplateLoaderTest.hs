{- | Integration tests for Iidy.Cfn.TemplateLoader.

Tests the loadCfnTemplate function across its main dispatch paths:
S3/HTTP URL passthrough, render: preprocessing, local file loading,
and error conditions (returned as Left values).
-}
module Test.TemplateLoaderTest (templateLoaderTests) where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Iidy.Cfn.TemplateLoader (
    TemplateResult (..),
    loadCfnTemplate,
    templateMaxBytes,
 )
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig, mkImportConfig)
import Iidy.Yaml.Imports.Types (RemoteImports (..), importPolicy)

------------------------------------------------------------------------
-- Helpers (shared config)
------------------------------------------------------------------------

defaultImportCfg :: ImportConfig
defaultImportCfg = mkImportConfig Nothing (importPolicy AllowRemoteImports)

------------------------------------------------------------------------
-- Test groups
------------------------------------------------------------------------

templateLoaderTests :: [TestTree]
templateLoaderTests =
    [ testGroup "URL passthrough" urlTests
    , testGroup "render: success" renderSuccessTests
    , testGroup "Local file" localFileTests
    , testGroup "Failure paths" failureTests
    ]

------------------------------------------------------------------------
-- URL passthrough
------------------------------------------------------------------------

urlTests :: [TestTree]
urlTests =
    [ testCase "s3:// URL returned as trTemplateUrl" $ do
        result <- loadCfnTemplate (Just "s3://my-bucket/cfn/template.yaml") Nothing "" defaultImportCfg
        case result of
            Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
            Right tr -> do
                trTemplateUrl tr @?= Just "s3://my-bucket/cfn/template.yaml"
                trTemplateBody tr @?= Nothing
    , testCase "https://s3... URL returned as trTemplateUrl" $ do
        result <- loadCfnTemplate (Just "https://s3.amazonaws.com/bucket/key.yaml") Nothing "" defaultImportCfg
        case result of
            Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
            Right tr -> do
                trTemplateUrl tr @?= Just "https://s3.amazonaws.com/bucket/key.yaml"
                trTemplateBody tr @?= Nothing
    , testCase "https:// URL returned as trTemplateUrl" $ do
        result <- loadCfnTemplate (Just "https://example.com/template.yaml") Nothing "" defaultImportCfg
        case result of
            Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
            Right tr -> do
                trTemplateUrl tr @?= Just "https://example.com/template.yaml"
                trTemplateBody tr @?= Nothing
    , testCase "http:// URL returned as trTemplateUrl" $ do
        result <- loadCfnTemplate (Just "http://example.com/template.yaml") Nothing "" defaultImportCfg
        case result of
            Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
            Right tr -> do
                trTemplateUrl tr @?= Just "http://example.com/template.yaml"
                trTemplateBody tr @?= Nothing
    , testCase "Nothing input returns empty result" $ do
        result <- loadCfnTemplate Nothing Nothing "" defaultImportCfg
        case result of
            Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
            Right tr -> do
                trTemplateUrl tr @?= Nothing
                trTemplateBody tr @?= Nothing
    ]

------------------------------------------------------------------------
-- render: success paths
------------------------------------------------------------------------

-- | Fixture directory relative to project root (where cabal test runs).
fixtureDir :: FilePath
fixtureDir = "test-fixtures" </> "template-loader"

{- | A fake argsfile path in fixtureDir so resolveTemplatePath resolves
relative template paths against fixtureDir.
-}
argsfileInFixtureDir :: FilePath
argsfileInFixtureDir = fixtureDir </> "stack-args.yaml"

-- | Load @text@ as a @render:@ template.
renderTemplateText :: BS.ByteString -> IO (Either T.Text TemplateResult)
renderTemplateText text = withSystemTempDirectory "tpl-loader-dup" $ \dir -> do
    let fp = dir </> "t.yaml"
    BS.writeFile fp text
    loadCfnTemplate (Just (T.pack ("render:" <> fp))) Nothing "dev" defaultImportCfg

-- | The load failed as a parse error naming the repeated key at (line, column).
assertDuplicate :: T.Text -> (Int, Int) -> Either T.Text TemplateResult -> IO ()
assertDuplicate key (line, col) r = case r of
    Right _ -> assertFailure "expected a duplicate key parse error"
    Left err -> do
        assertBool ("Parse error: " <> T.unpack err) ("Parse error" `T.isInfixOf` err)
        assertBool
            ("message: " <> T.unpack err)
            (("duplicate entry with key \"" <> key <> "\" at line " <> T.pack (show line) <> " column " <> T.pack (show col)) `T.isInfixOf` err)

renderSuccessTests :: [TestTree]
renderSuccessTests =
    [ testCase "render: simple template returns trTemplateBody" $ do
        result <-
            loadCfnTemplate
                (Just "render:simple.yaml")
                (Just argsfileInFixtureDir)
                "dev"
                defaultImportCfg
        case result of
            Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
            Right tr -> do
                assertBodyPresent tr
                assertNoTemplateUrl tr
    , testCase "render: body does not contain $defs: or $imports: keys" $ do
        result <-
            loadCfnTemplate
                (Just "render:simple.yaml")
                (Just argsfileInFixtureDir)
                "dev"
                defaultImportCfg
        case result of
            Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
            Right tr -> do
                let body = extractBody tr
                assertBool "no $defs: in output" (not ("$defs:" `T.isInfixOf` body))
                assertBool "no $imports: in output" (not ("$imports:" `T.isInfixOf` body))
    , testCase "render: with $defs resolves variable references" $ do
        result <-
            loadCfnTemplate
                (Just "render:with-defs.yaml")
                (Just argsfileInFixtureDir)
                "dev"
                defaultImportCfg
        case result of
            Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
            Right tr -> do
                let body = extractBody tr
                assertBool "$defs variable resolved to 'bar'" ("bar" `T.isInfixOf` body)
                assertBool "$defs key filtered from output" (not ("$defs:" `T.isInfixOf` body))
    , testCase "render: env name injected as $envValues (filtered from output)" $ do
        -- \$envValues is injected into the AST and filtered from output by the resolver.
        -- The environment name is NOT accessible via Handlebars {{$envValues.environment}}
        -- in the current implementation (engine doesn't expose $envValues as a variable),
        -- but the template still renders successfully and $envValues is absent from output.
        result <-
            loadCfnTemplate
                (Just "render:simple.yaml")
                (Just argsfileInFixtureDir)
                "staging"
                defaultImportCfg
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
        result <-
            loadCfnTemplate
                (Just "test-fixtures/template-loader/simple.yaml")
                Nothing
                "dev"
                defaultImportCfg
        case result of
            Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
            Right tr -> do
                assertBodyPresent tr
                assertNoTemplateUrl tr
    , testCase "local file body contains AWSTemplateFormatVersion" $ do
        result <-
            loadCfnTemplate
                (Just "test-fixtures/template-loader/simple.yaml")
                Nothing
                "dev"
                defaultImportCfg
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
            result <-
                loadCfnTemplate
                    (Just (T.pack ("render:" <> fp)))
                    Nothing
                    "dev"
                    defaultImportCfg
            case result of
                Right _ -> assertFailure "expected Left for malformed YAML"
                Left err ->
                    assertBool
                        "error mentions 'Parse error'"
                        ("Parse error" `T.isInfixOf` err)
    , testCase "render: a repeated key at the top level is a parse error" $
        renderTemplateText "a: 1\nb: 2\na: 3\n" >>= assertDuplicate "a" (3, 1)
    , testCase "render: a repeated key nested in a mapping is a parse error" $
        renderTemplateText "Resources:\n  R:\n    Type: X\n    Type: Y\n" >>= assertDuplicate "Type" (4, 5)
    , testCase "render: a and \"a\" are the same key" $
        renderTemplateText "a: 1\n\"a\": 2\n" >>= assertDuplicate "a" (2, 1)
    , testCase "render: 1 and \"1\" are different keys" $
        renderTemplateText "1: x\n\"1\": y\n" >>= either (assertFailure . ("expected success, got: " <>) . T.unpack) (const (pure ()))
    , testCase "local file with $imports: but no render: prefix returns Left" $
        withSystemTempDirectory "tpl-loader-imports" $ \dir -> do
            let fp = dir </> "has-imports.yaml"
            BS.writeFile fp "$imports:\n  x: env:HOME\nResources: {}\n"
            result <-
                loadCfnTemplate
                    (Just (T.pack fp))
                    Nothing
                    "dev"
                    defaultImportCfg
            case result of
                Right _ -> assertFailure "expected Left for $imports: without render:"
                Left err ->
                    assertBool
                        "error mentions 'render:'"
                        ("render:" `T.isInfixOf` err)
    , testCase "render: with AWS import but no AWS env returns Left" $
        withSystemTempDirectory "tpl-loader-ssm" $ \dir -> do
            let fp = dir </> "uses-ssm.yaml"
            BS.writeFile fp "$imports:\n  dbPass: ssm:/my/param\nAWSTemplateFormatVersion: \"2010-09-09\"\nResources: {}\n"
            result <-
                loadCfnTemplate
                    (Just (T.pack ("render:" <> fp)))
                    Nothing
                    "dev"
                    defaultImportCfg
            case result of
                Right _ -> assertFailure "expected Left for AWS import without credentials"
                Left err ->
                    assertBool
                        "error mentions AWS credentials or Preprocess error"
                        ( "AWS import type requires credentials" `T.isInfixOf` err
                            || "Preprocess error" `T.isInfixOf` err
                        )
    , testCase "local file with invalid UTF-8 bytes returns Left" $
        withSystemTempDirectory "tpl-loader-utf8" $ \dir -> do
            let fp = dir </> "bad-utf8.yaml"
            -- Write bytes that are invalid UTF-8: 0xFF 0xFE are not valid UTF-8 lead bytes
            BS.writeFile fp (BS.pack [0xFF, 0xFE, 0x00, 0x01])
            result <-
                loadCfnTemplate
                    (Just (T.pack fp))
                    Nothing
                    "dev"
                    defaultImportCfg
            case result of
                Right _ -> assertFailure "expected Left for invalid UTF-8 file"
                Left err ->
                    assertBool
                        "error mentions 'Invalid UTF-8'"
                        ("Invalid UTF-8" `T.isInfixOf` err)
    , testCase "render: template exceeding size limit returns Left" $
        withSystemTempDirectory "tpl-loader-huge" $ \dir -> do
            let fp = dir </> "huge.yaml"
            -- Build a YAML template whose rendered output exceeds templateMaxBytes.
            -- We use a $defs variable with a very long value that gets inlined into
            -- the rendered output, so the emitter produces content > 51199 bytes.
            let longVal = T.replicate (templateMaxBytes + 100) "a"
                content =
                    T.unlines
                        [ "$defs:"
                        , "  bigval: " <> longVal
                        , "AWSTemplateFormatVersion: \"2010-09-09\""
                        , "BigOutput: !$ bigval"
                        , "Resources: {}"
                        ]
            BS.writeFile fp (TE.encodeUtf8 content)
            result <-
                loadCfnTemplate
                    (Just (T.pack ("render:" <> fp)))
                    Nothing
                    "dev"
                    defaultImportCfg
            case result of
                Right _ -> assertFailure "expected Left for oversized template"
                Left err ->
                    assertBool
                        "error mentions size limit"
                        ("exceeds maximum size" `T.isInfixOf` err)
    , testCase "inline content with $imports: returns Left" $ do
        result <-
            loadCfnTemplate
                (Just "$imports:\n  x: env:HOME\nResources: {}")
                Nothing
                "dev"
                defaultImportCfg
        case result of
            Right _ -> assertFailure "expected Left for inline $imports: without render:"
            Left err ->
                assertBool
                    "error mentions 'render:'"
                    ("render:" `T.isInfixOf` err)
    , testCase "missing path returns Left naming the path" $ do
        result <-
            loadCfnTemplate
                (Just "no-such-dir/missing.yaml")
                Nothing
                "dev"
                defaultImportCfg
        assertMissingPath "no-such-dir/missing.yaml" result
    , testCase "missing bare word returns Left naming the path" $ do
        result <-
            loadCfnTemplate
                (Just "missing-template")
                Nothing
                "dev"
                defaultImportCfg
        assertMissingPath "missing-template" result
    , testCase "missing path resolves against the argsfile directory" $ do
        result <-
            loadCfnTemplate
                (Just "missing-template")
                (Just "some-dir/stack-args.yaml")
                "dev"
                defaultImportCfg
        assertMissingPath "some-dir/missing-template" result
    , testCase "inline JSON object is used as the body" $
        assertInlineBody "{\"Resources\": {}}"
    , testCase "inline JSON array is used as the body" $
        assertInlineBody "[1, 2]"
    , testCase "inline body with leading whitespace before a brace" $
        assertInlineBody "  {\"Resources\": {}}"
    , testCase "inline multi-line YAML is used as the body" $
        assertInlineBody "AWSTemplateFormatVersion: \"2010-09-09\"\nResources: {}"
    ]

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Assert a 'Left' whose message names the resolved path.
assertMissingPath :: T.Text -> Either T.Text TemplateResult -> IO ()
assertMissingPath path result =
    case result of
        Right tr -> assertFailure $ "expected Left, got " <> show tr
        Left err ->
            assertBool
                ("error names " <> T.unpack path <> ": " <> T.unpack err)
                (path `T.isInfixOf` err)

-- | Assert that a spec is used verbatim as the template body.
assertInlineBody :: T.Text -> IO ()
assertInlineBody spec = do
    result <- loadCfnTemplate (Just spec) Nothing "dev" defaultImportCfg
    case result of
        Left err -> assertFailure $ "unexpected Left: " <> T.unpack err
        Right tr -> trTemplateBody tr @?= Just spec

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
        Nothing -> error "extractBody: trTemplateBody is Nothing (test setup error)"
