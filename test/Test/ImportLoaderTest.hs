module Test.ImportLoaderTest (importLoaderTests) where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Char (isDigit)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (findExecutable)
import System.Environment (setEnv, unsetEnv)
import System.IO.Unsafe (unsafePerformIO)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Iidy.Yaml.Imports.ContentParsing (ParsedDoc (..), parseByExtensionStrict, parseByFormatSuffix)
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig, mkFullDispatcher, mkImportConfig)
import Iidy.Yaml.Imports.Loaders.Env (loadEnvImport)
import Iidy.Yaml.Imports.Loaders.Git (loadGitImport)
import Iidy.Yaml.Imports.Loaders.Http (urlPath)
import Iidy.Yaml.Imports.Loaders.Random (loadRandomImport)
import Iidy.Yaml.Imports.Types (ImportData (..), ImportError (..), ImportType (..), RemoteImports (..), importPolicy, rootBase)
import Iidy.Yaml.OValue (toValue)

defaultImportCfg :: ImportConfig
defaultImportCfg = mkImportConfig Nothing (importPolicy AllowRemoteImports)

importLoaderTests :: [TestTree]
importLoaderTests =
    [ testGroup "Env loader" envTests
    , testGroup "Git loader" gitTests
    , testGroup "Random loader" randomTests
    , testGroup "Http helpers" httpTests
    , testGroup "JSON ordered view" jsonOrderedTests
    , testGroup "Duplicate mapping keys" duplicateKeyTests
    , testGroup "Dispatcher routing" dispatchTests
    ]

------------------------------------------------------------------------
-- Env tests
------------------------------------------------------------------------

envTests :: [TestTree]
envTests =
    [ testCase "loads existing env var" $ do
        setEnv "IIDY_TEST_VAR" "test_value_42"
        result <- loadEnvImport "env:IIDY_TEST_VAR"
        unsetEnv "IIDY_TEST_VAR"
        case result of
            Left (ImportError e) -> fail (T.unpack e)
            Right dat -> do
                idType dat @?= ImportEnv
                idRawData dat @?= "test_value_42"
                idDoc dat @?= String "test_value_42"
    , testCase "uses default value when var missing" $ do
        unsetEnv "IIDY_MISSING_VAR"
        result <- loadEnvImport "env:IIDY_MISSING_VAR:fallback_val"
        case result of
            Left (ImportError e) -> fail (T.unpack e)
            Right dat -> do
                idRawData dat @?= "fallback_val"
                idDoc dat @?= String "fallback_val"
    , testCase "errors on missing var without default" $ do
        unsetEnv "IIDY_DEFINITELY_MISSING"
        result <- loadEnvImport "env:IIDY_DEFINITELY_MISSING"
        case result of
            Left (ImportError e) ->
                assertBool "mentions var name" ("IIDY_DEFINITELY_MISSING" `T.isInfixOf` e)
            Right _ -> fail "Expected error for missing env var"
    ]

------------------------------------------------------------------------
-- Git tests
------------------------------------------------------------------------

-- | Check once at startup whether @git@ is on PATH.
hasGit :: Bool
hasGit = unsafePerformIO (isJust <$> findExecutable "git")
{-# NOINLINE hasGit #-}

-- | Skip a test when @git@ is not available.
requireGit :: IO () -> IO ()
requireGit act
    | hasGit = act
    | otherwise = pure () -- silently skip

gitTests :: [TestTree]
gitTests =
    [ testCase "git:branch returns non-empty text" $ requireGit $ do
        result <- loadGitImport "git:branch" "."
        case result of
            Left (ImportError e) -> fail (T.unpack e)
            Right dat -> do
                idType dat @?= ImportGit
                assertBool "branch non-empty" (not (T.null (idRawData dat)))
    , testCase "git:sha returns 40-char hex" $ requireGit $ do
        result <- loadGitImport "git:sha" "."
        case result of
            Left (ImportError e) -> fail (T.unpack e)
            Right dat -> do
                idType dat @?= ImportGit
                T.length (idRawData dat) @?= 40
                assertBool "all hex" (T.all isHexDigit (idRawData dat))
    , testCase "git:describe returns non-empty text" $ requireGit $ do
        result <- loadGitImport "git:describe" "."
        case result of
            Left (ImportError e) -> fail (T.unpack e)
            Right dat -> do
                idType dat @?= ImportGit
                assertBool "describe non-empty" (not (T.null (idRawData dat)))
    , testCase "invalid git command errors" $ do
        result <- loadGitImport "git:invalid_cmd" "."
        case result of
            Left (ImportError e) ->
                assertBool "mentions invalid" ("Invalid git command" `T.isInfixOf` e)
            Right _ -> fail "Expected error for invalid git command"
    ]

------------------------------------------------------------------------
-- Random tests
------------------------------------------------------------------------

randomTests :: [TestTree]
randomTests =
    [ testCase "random:dashed-name matches word-word pattern" $ do
        result <- loadRandomImport "random:dashed-name"
        case result of
            Left (ImportError e) -> fail (T.unpack e)
            Right dat -> do
                idType dat @?= ImportRandom
                let val = idRawData dat
                assertBool "contains dash" (T.isInfixOf "-" val)
                let parts = T.splitOn "-" val
                assertBool "two parts" (length parts == 2)
                assertBool "both non-empty" (not (any T.null parts))
    , testCase "random:name returns non-empty text" $ do
        result <- loadRandomImport "random:name"
        case result of
            Left (ImportError e) -> fail (T.unpack e)
            Right dat -> do
                idType dat @?= ImportRandom
                assertBool "name non-empty" (not (T.null (idRawData dat)))
    , testCase "random:int returns number in 1-999" $ do
        result <- loadRandomImport "random:int"
        case result of
            Left (ImportError e) -> fail (T.unpack e)
            Right dat -> do
                idType dat @?= ImportRandom
                let n = read (T.unpack (idRawData dat)) :: Int
                assertBool "in range" (n >= 1 && n <= 999)
    , testCase "invalid random type errors" $ do
        result <- loadRandomImport "random:bogus"
        case result of
            Left (ImportError e) ->
                assertBool "mentions unknown" ("Unknown random type" `T.isInfixOf` e)
            Right _ -> fail "Expected error for invalid random type"
    ]

------------------------------------------------------------------------
-- Http helper tests
------------------------------------------------------------------------

httpTests :: [TestTree]
httpTests =
    [ testCase "urlPath extracts path from https URL" $
        urlPath "https://example.com/path/to/file.yaml" @?= "/path/to/file.yaml"
    , testCase "urlPath extracts path from http URL" $
        urlPath "http://example.com/file.json" @?= "/file.json"
    , testCase "urlPath returns / for bare domain" $
        urlPath "https://example.com" @?= "/"
    , testCase "urlPath strips query string" $
        urlPath "https://example.com/file.yaml?v=1" @?= "/file.yaml"
    , testCase "urlPath strips fragment" $
        urlPath "https://example.com/file.json#section" @?= "/file.json"
    ]

------------------------------------------------------------------------
-- Dispatcher routing tests
------------------------------------------------------------------------

dispatchTests :: [TestTree]
dispatchTests =
    [ testCase "dispatches env: to env loader" $ do
        setEnv "IIDY_DISPATCH_TEST" "dispatched"
        result <- mkFullDispatcher defaultImportCfg "env:IIDY_DISPATCH_TEST" (rootBase ".")
        unsetEnv "IIDY_DISPATCH_TEST"
        case result of
            Left (ImportError e) -> fail (T.unpack e)
            Right dat -> do
                idType dat @?= ImportEnv
                idRawData dat @?= "dispatched"
    , testCase "dispatches git: to git loader" $ do
        result <- mkFullDispatcher defaultImportCfg "git:sha" (rootBase ".")
        case result of
            Left (ImportError e) -> fail (T.unpack e)
            Right dat -> do
                idType dat @?= ImportGit
                T.length (idRawData dat) @?= 40
    , testCase "dispatches random: to random loader" $ do
        result <- mkFullDispatcher defaultImportCfg "random:int" (rootBase ".")
        case result of
            Left (ImportError e) -> fail (T.unpack e)
            Right dat -> do
                idType dat @?= ImportRandom
                let n = read (T.unpack (idRawData dat)) :: Int
                assertBool "in range" (n >= 1 && n <= 999)
    , testCase "AWS prefixes return error, not file fallthrough" $ do
        let awsPrefixes = ["cfn:stack/key", "ssm:/param", "ssm-path:/path", "s3://bucket/key"]
        mapM_
            ( \loc -> do
                result <- mkFullDispatcher defaultImportCfg loc (rootBase ".")
                case result of
                    Left (ImportError e) ->
                        assertBool
                            ("AWS error for " <> T.unpack loc)
                            ("AWS import type requires credentials" `T.isInfixOf` e)
                    Right _ -> fail ("Expected AWS error for " <> T.unpack loc)
            )
            awsPrefixes
    ]

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

isHexDigit :: Char -> Bool
isHexDigit c = isDigit c || (c >= 'a' && c <= 'f')

------------------------------------------------------------------------
-- JSON ordered view agrees with the aeson value (C28)
------------------------------------------------------------------------

jsonOrderedTests :: [TestTree]
jsonOrderedTests =
    [ agrees "floats" "{\"f\": 1.5, \"g\": 1.0, \"h\": -2.25e3}"
    , agrees "big integer" "{\"n\": 12345678901234567890}"
    , agrees "u escapes" "{\"s\": \"caf\\u00e9 \\u0041\", \"t\": [\"\\u00e9\"]}"
    ]
  where
    agrees name txt =
        testCase ("idOrdered agrees with idDoc: " <> name) $
            case parseByExtensionStrict "t.json" ".json" txt (TE.encodeUtf8 txt) of
                Left err -> assertBool (show err) False
                Right pd -> do
                    fmap toValue (pdOrdered pd) @?= Just (pdValue pd)
                    Aeson.eitherDecodeStrict (TE.encodeUtf8 txt) @?= Right (pdValue pd)

------------------------------------------------------------------------
-- Duplicate mapping keys are rejected in imported documents (C34)
------------------------------------------------------------------------

duplicateKeyTests :: [TestTree]
duplicateKeyTests =
    [ rejectsExt ".yaml" "template" "a: 1\nz: 1\nz: 2\n" "z"
    , rejectsExt ".yml" "nested mapping" "outer:\n  inner:\n    k: 1\n    k: 2\n" "k"
    , rejectsExt ".yaml" "mapping in a sequence" "- a: 1\n  a: 2\n" "a"
    , rejectsExt ".yaml" "plain and quoted spelling" "a: 1\n\"a\": 2\n" "a"
    , rejectsExt ".yaml" "repeated merge key" "x: 1\n<<: {p: 1}\n<<: {q: 2}\n" "<<"
    , rejectsExt ".json" "json" "{\"a\":1,\"z\":1,\"z\":2}" "z"
    , rejectsExt ".json" "nested json" "{\"o\":[{\"k\":1,\"k\":2}]}" "k"
    , testCase "SSM json suffix rejects" $ rejects (parseByFormatSuffix (Just "json") "{\"q\":1,\"q\":2}") "q"
    , testCase "SSM yaml suffix rejects" $ rejects (parseByFormatSuffix (Just "yaml") "q: 1\nq: 2\n") "q"
    , testCase "a number key and a string key of the same digits are distinct" $
        case parseByExtensionStrict "t.yaml" ".yaml" "1: a\n\"1\": b\n" "" of
            Left err -> assertBool (show err) False
            Right _ -> pure ()
    ]
  where
    rejectsExt ext name txt key =
        testCase ("duplicate key rejected: " <> name) $
            case parseByExtensionStrict "dir/data" ext txt (TE.encodeUtf8 txt) of
                Left (ImportError msg) -> do
                    assertBool (T.unpack msg) ("from dir/data: " `T.isInfixOf` msg)
                    rejects (Left (ImportError msg) :: Either ImportError ()) key
                Right _ -> assertBool "expected a duplicate key error" False
    rejects :: Either ImportError a -> Text -> IO ()
    rejects (Right _) _ = assertBool "expected a duplicate key error" False
    rejects (Left (ImportError msg)) key =
        assertBool (T.unpack msg) (("duplicate entry with key \"" <> key <> "\"") `T.isInfixOf` msg)
