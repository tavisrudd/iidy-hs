module Test.ImportLoaderTest (importLoaderTests) where

import Data.Aeson (Value(..))
import qualified Data.Text as T
import System.Environment (setEnv, unsetEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool)

import Iidy.Yaml.Imports.Loaders.Env (loadEnvImport)
import Iidy.Yaml.Imports.Loaders.Git (loadGitImport)
import Iidy.Yaml.Imports.Loaders.Http (urlPath)
import Iidy.Yaml.Imports.Loaders.Random (loadRandomImport)
import Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher)
import Iidy.Yaml.Imports.Types (ImportData(..), ImportType(..), ImportError(..))

importLoaderTests :: [TestTree]
importLoaderTests =
  [ testGroup "Env loader" envTests
  , testGroup "Git loader" gitTests
  , testGroup "Random loader" randomTests
  , testGroup "Http helpers" httpTests
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

gitTests :: [TestTree]
gitTests =
  [ testCase "git:branch returns non-empty text" $ do
      result <- loadGitImport "git:branch" "."
      case result of
        Left (ImportError e) -> fail (T.unpack e)
        Right dat -> do
          idType dat @?= ImportGit
          assertBool "branch non-empty" (not (T.null (idRawData dat)))

  , testCase "git:sha returns 40-char hex" $ do
      result <- loadGitImport "git:sha" "."
      case result of
        Left (ImportError e) -> fail (T.unpack e)
        Right dat -> do
          idType dat @?= ImportGit
          T.length (idRawData dat) @?= 40
          assertBool "all hex" (T.all isHexDigit (idRawData dat))

  , testCase "git:describe returns non-empty text" $ do
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
          assertBool "both non-empty" (all (not . T.null) parts)

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
      result <- mkFullDispatcher Nothing "env:IIDY_DISPATCH_TEST" "."
      unsetEnv "IIDY_DISPATCH_TEST"
      case result of
        Left (ImportError e) -> fail (T.unpack e)
        Right dat -> do
          idType dat @?= ImportEnv
          idRawData dat @?= "dispatched"

  , testCase "dispatches git: to git loader" $ do
      result <- mkFullDispatcher Nothing "git:sha" "."
      case result of
        Left (ImportError e) -> fail (T.unpack e)
        Right dat -> do
          idType dat @?= ImportGit
          T.length (idRawData dat) @?= 40

  , testCase "dispatches random: to random loader" $ do
      result <- mkFullDispatcher Nothing "random:int" "."
      case result of
        Left (ImportError e) -> fail (T.unpack e)
        Right dat -> do
          idType dat @?= ImportRandom
          let n = read (T.unpack (idRawData dat)) :: Int
          assertBool "in range" (n >= 1 && n <= 999)

  , testCase "AWS prefixes return error, not file fallthrough" $ do
      let awsPrefixes = ["cfn:stack/key", "ssm:/param", "ssm-path:/path", "s3://bucket/key"]
      mapM_ (\loc -> do
        result <- mkFullDispatcher Nothing loc "."
        case result of
          Left (ImportError e) ->
            assertBool ("AWS error for " <> T.unpack loc)
              ("AWS import type requires credentials" `T.isInfixOf` e)
          Right _ -> fail ("Expected AWS error for " <> T.unpack loc)
        ) awsPrefixes
  ]

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

isHexDigit :: Char -> Bool
isHexDigit c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
