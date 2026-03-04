{-# LANGUAGE OverloadedStrings #-}

module Test.EngineTest (engineTests) where

import Data.Aeson (Value(..))
import Data.Text (Text)
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Yaml.Ast
import Iidy.Yaml.Engine (preprocessYaml, PreprocessError(..))
import Iidy.Yaml.Imports.Types (ImportData(..), ImportError(..), ImportType(..))
import Iidy.Yaml.Location (zeroPosition)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Shared zero-position source metadata for test ASTs.
m :: SrcMeta
m = SrcMeta "<test>" zeroPosition zeroPosition

-- | A mock loader that always succeeds with a simple string value.
alwaysSucceedLoader :: Text -> Text -> IO (Either ImportError ImportData)
alwaysSucceedLoader _loc _base = pure $ Right $ ImportData
  { idType     = ImportFile
  , idLocation = "mock"
  , idRawData  = "value"
  , idDoc      = String "value"
  }

------------------------------------------------------------------------
-- Tests
------------------------------------------------------------------------

engineTests :: [TestTree]
engineTests =
  [ testGroup "Import cycle detection"
    [ testCase "importing same location as base file triggers cycle error" $ do
        -- YAML that imports itself (same as base location)
        let ast = AstMapping
              [ ( AstPlainString "$imports" m
                , AstMapping
                    [ (AstPlainString "self" m, AstPlainString "test.yaml" m)
                    ]
                    m
                )
              ] m
        result <- preprocessYaml alwaysSucceedLoader ast "test.yaml"
        case result of
          Left (PeCycleError err) ->
            assertBool "mentions Circular import"
              (T.isInfixOf "Circular import" err)
          Left other -> assertFailure $ "Expected cycle error, got: " <> show other
          Right _ -> assertFailure "Expected cycle error when importing self"

    , testCase "distinct import locations succeed" $ do
        -- YAML with two imports pointing to different locations
        let ast = AstMapping
              [ ( AstPlainString "$imports" m
                , AstMapping
                    [ (AstPlainString "a" m, AstPlainString "file-a.yaml" m)
                    , (AstPlainString "b" m, AstPlainString "file-b.yaml" m)
                    ]
                    m
                )
              ] m
        result <- preprocessYaml alwaysSucceedLoader ast "test.yaml"
        case result of
          Left err -> assertFailure $ "Expected success, got: " <> show err
          Right _ -> pure ()

    , testCase "sibling imports of same file are allowed (not a cycle)" $ do
        -- Two imports of the same file in the same $imports block is fine;
        -- cycle detection is for recursive chains, not sibling reuse.
        let ast = AstMapping
              [ ( AstPlainString "$imports" m
                , AstMapping
                    [ (AstPlainString "first" m, AstPlainString "shared.yaml" m)
                    , (AstPlainString "second" m, AstPlainString "shared.yaml" m)
                    ]
                    m
                )
              ] m
        result <- preprocessYaml alwaysSucceedLoader ast "test.yaml"
        case result of
          Left err -> assertFailure $ "Expected success for sibling imports, got: " <> show err
          Right _ -> pure ()

    , testCase "cycle error message includes the import chain" $ do
        -- Importing self should show the chain: test.yaml -> test.yaml
        let ast = AstMapping
              [ ( AstPlainString "$imports" m
                , AstMapping
                    [ (AstPlainString "self" m, AstPlainString "base.yaml" m)
                    ]
                    m
                )
              ] m
        result <- preprocessYaml alwaysSucceedLoader ast "base.yaml"
        case result of
          Left (PeCycleError err) -> do
            assertBool "mentions base.yaml" (T.isInfixOf "base.yaml" err)
            assertBool "contains arrow separator" (T.isInfixOf "\x2192" err)
          Left other -> assertFailure $ "Expected cycle error, got: " <> show other
          Right _ -> assertFailure "Expected cycle error when importing self"
    ]
  ]
