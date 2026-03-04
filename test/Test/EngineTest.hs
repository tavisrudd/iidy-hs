{-# LANGUAGE OverloadedStrings #-}

module Test.EngineTest (engineTests) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.IORef (newIORef, modifyIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Yaml.Ast
import Iidy.Yaml.Engine (preprocessYaml, PreprocessResult(..), PreprocessError(..))
import Iidy.Yaml.Imports.Types (ImportData(..), ImportError(..), ImportType(..))
import Iidy.Yaml.Location (zeroPosition)
import Iidy.Yaml.OValue (toValue)

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

  , testGroup "Recursive import preprocessing"
    [ testCase "recursively preprocesses imported doc with nested $imports" $ do
        -- Track which locations the loader is called with
        callsRef <- newIORef ([] :: [Text])
        -- outer.yaml has $imports that reference inner.yaml
        let nestedLoader loc _base = do
              modifyIORef callsRef (loc :)
              case loc of
                "outer.yaml" ->
                  pure $ Right $ ImportData
                    { idType = ImportFile
                    , idLocation = "outer.yaml"
                    , idRawData = "$imports:\n  nested: inner.yaml\nvalue: from-outer"
                    , idDoc = Object $ KM.fromList
                        [ (Key.fromText "$imports", Object $ KM.fromList
                            [(Key.fromText "nested", String "inner.yaml")])
                        , (Key.fromText "value", String "from-outer")
                        ]
                    }
                "inner.yaml" ->
                  pure $ Right $ ImportData
                    { idType = ImportFile
                    , idLocation = "inner.yaml"
                    , idRawData = "hello"
                    , idDoc = String "hello"
                    }
                other ->
                  pure $ Left $ ImportError $ "Unknown: " <> other

        -- Main document imports outer.yaml
        let ast = AstMapping
              [ ( AstPlainString "$imports" m
                , AstMapping
                    [ (AstPlainString "data" m, AstPlainString "outer.yaml" m)
                    ]
                    m
                )
              ] m
        result <- preprocessYaml nestedLoader ast "test.yaml"
        case result of
          Left err -> assertFailure $ "Expected success, got: " <> show err
          Right _ -> do
            calls <- readIORef callsRef
            -- Verify inner.yaml was loaded (proving recursion into outer.yaml's $imports)
            assertBool "inner.yaml should have been loaded via recursive preprocessing"
              ("inner.yaml" `elem` calls)

    , testCase "recursively resolves $defs in imported doc" $ do
        -- outer.yaml has $defs that define a variable used in the doc
        let defsLoader loc _base = case loc of
              "with-defs.yaml" ->
                pure $ Right $ ImportData
                  { idType = ImportFile
                  , idLocation = "with-defs.yaml"
                  , idRawData = "$defs:\n  greeting: hello\nresult: \"{{greeting}}\""
                  , idDoc = Object $ KM.fromList
                      [ (Key.fromText "$defs", Object $ KM.fromList
                          [(Key.fromText "greeting", String "hello")])
                      , (Key.fromText "result", String "{{greeting}}")
                      ]
                  }
              other ->
                pure $ Left $ ImportError $ "Unknown: " <> other

        let ast = AstMapping
              [ ( AstPlainString "$imports" m
                , AstMapping
                    [ (AstPlainString "data" m, AstPlainString "with-defs.yaml" m)
                    ]
                    m
                )
              , (AstPlainString "output" m, AstTemplatedString "{{data.result}}" m)
              ] m
        result <- preprocessYaml defsLoader ast "test.yaml"
        case result of
          Left err -> assertFailure $ "Expected success, got: " <> show err
          Right (PreprocessResult val _manifest) -> do
            let v = toValue val
            case v of
              Object obj -> case KM.lookup (Key.fromText "output") obj of
                Just (String s) ->
                  assertEqual "should resolve nested $defs" "hello" s
                other -> assertFailure $ "Expected String output, got: " <> show other
              _ -> assertFailure $ "Expected Object, got: " <> show v

    , testCase "imported doc without $imports/$defs is not re-parsed" $ do
        -- A plain imported doc should just be converted via fromValue as before
        let plainLoader loc _base = case loc of
              "plain.yaml" ->
                pure $ Right $ ImportData
                  { idType = ImportFile
                  , idLocation = "plain.yaml"
                  , idRawData = "key: value"
                  , idDoc = Object $ KM.fromList
                      [(Key.fromText "key", String "value")]
                  }
              other ->
                pure $ Left $ ImportError $ "Unknown: " <> other

        let ast = AstMapping
              [ ( AstPlainString "$imports" m
                , AstMapping
                    [ (AstPlainString "data" m, AstPlainString "plain.yaml" m)
                    ]
                    m
                )
              , (AstPlainString "output" m, AstTemplatedString "{{data.key}}" m)
              ] m
        result <- preprocessYaml plainLoader ast "test.yaml"
        case result of
          Left err -> assertFailure $ "Expected success, got: " <> show err
          Right (PreprocessResult val _manifest) -> do
            let v = toValue val
            case v of
              Object obj -> case KM.lookup (Key.fromText "output") obj of
                Just (String s) ->
                  assertEqual "should pass through plain import" "value" s
                other -> assertFailure $ "Expected String output, got: " <> show other
              _ -> assertFailure $ "Expected Object, got: " <> show v
    ]
  ]
