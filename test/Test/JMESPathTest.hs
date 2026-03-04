module Test.JMESPathTest (jmespathTests) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Vector qualified as V
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Data.Text (isInfixOf)
import Iidy.Yaml.JMESPath (JMESPathError (..), applyJmesPath)

jmespathTests :: [TestTree]
jmespathTests =
    [ testCase "field access" $ do
        let input = Object (KM.fromList [("foo", String "bar")])
        applyJmesPath "foo" input @?= Right (String "bar")
    , testCase "nested field access" $ do
        let inner = Object (KM.fromList [("b", String "val")])
            input = Object (KM.fromList [("a", inner)])
        applyJmesPath "a.b" input @?= Right (String "val")
    , testCase "array index" $ do
        let input = Array (V.fromList [String "x", String "y", String "z"])
        applyJmesPath "[1]" input @?= Right (String "y")
    , testCase "negative array index" $ do
        let input = Array (V.fromList [String "x", String "y", String "z"])
        applyJmesPath "[-1]" input @?= Right (String "z")
    , testCase "wildcard on array" $ do
        let input = Array (V.fromList [String "a", String "b"])
        applyJmesPath "[*]" input @?= Right (Array (V.fromList [String "a", String "b"]))
    , testCase "field projection" $ do
        let item1 = Object (KM.fromList [("name", String "alice")])
            item2 = Object (KM.fromList [("name", String "bob")])
            input = Array (V.fromList [item1, item2])
        applyJmesPath "[*].name" input
            @?= Right (Array (V.fromList [String "alice", String "bob"]))
    , testCase "filter expression" $ do
        let mkItem n b = Object (KM.fromList [("name", String n), ("active", Bool b)])
            input = Array (V.fromList [mkItem "a" True, mkItem "b" False, mkItem "c" True])
        result <- case applyJmesPath "[?active].name" input of
            Left e -> assertFailure ("jmespath failed: " <> show e) >> return (Array V.empty)
            Right v -> return v
        result @?= Array (V.fromList [String "a", String "c"])
    , testCase "multi-select hash" $ do
        let input = Object (KM.fromList [("host", String "localhost"), ("port", Number 5432), ("user", String "admin")])
        result <- case applyJmesPath "{host: host, port: port}" input of
            Left e -> assertFailure ("jmespath failed: " <> show e) >> return Null
            Right v -> return v
        result @?= Object (KM.fromList [("host", String "localhost"), ("port", Number 5432)])
    , testCase "identity" $ do
        let input = String "hello"
        applyJmesPath "@" input @?= Right (String "hello")
    , testCase "missing field returns null" $ do
        let input = Object (KM.fromList [("foo", String "bar")])
        applyJmesPath "missing" input @?= Right Null
    , testCase "pipe operator" $ do
        let input = Object (KM.fromList [("a", Object (KM.fromList [("b", String "val")]))])
        applyJmesPath "a|b" input @?= Right (String "val")
    , testCase "comparison eq on strings" $ do
        let input = Object (KM.fromList [("env", String "prod")])
        applyJmesPath "env=='prod'" input @?= Right (Bool True)
    , testCase "flatten" $ do
        let input =
                Array
                    ( V.fromList
                        [ Array (V.fromList [String "a", String "b"])
                        , Array (V.fromList [String "c"])
                        ]
                    )
        applyJmesPath "[]" input @?= Right (Array (V.fromList [String "a", String "b", String "c"]))
    , -- Error messages for unsupported features
      testCase "function call gives clear unsupported error" $ do
        let input = Object (KM.fromList [("items", Array V.empty)])
        case applyJmesPath "length(@)" input of
            Left (JMESPathError msg) ->
                assertBool
                    ("expected 'not supported' in: " <> show msg)
                    ("not supported" `isInfixOf` msg)
            Right _ -> assertFailure "expected parse error for function call"
    , testCase "slice expression [0:5] gives clear unsupported error" $ do
        let input = Array (V.fromList [String "a", String "b"])
        case applyJmesPath "[0:5]" input of
            Left (JMESPathError msg) ->
                assertBool
                    ("expected 'not supported' in: " <> show msg)
                    ("not supported" `isInfixOf` msg)
            Right _ -> assertFailure "expected parse error for slice expression"
    , testCase "slice expression [:5] gives clear unsupported error" $ do
        let input = Array (V.fromList [String "a", String "b"])
        case applyJmesPath "[:5]" input of
            Left (JMESPathError msg) ->
                assertBool
                    ("expected 'not supported' in: " <> show msg)
                    ("not supported" `isInfixOf` msg)
            Right _ -> assertFailure "expected parse error for slice expression"
    , testCase "existing valid expressions still work after error improvements" $ do
        -- Verify that the error detection doesn't break valid expressions
        let input =
                Object
                    ( KM.fromList
                        [
                            ( "items"
                            , Array
                                ( V.fromList
                                    [ Object (KM.fromList [("name", String "a")])
                                    , Object (KM.fromList [("name", String "b")])
                                    ]
                                )
                            )
                        , ("count", Number 42)
                        ]
                    )
        applyJmesPath "items[0].name" input @?= Right (String "a")
        applyJmesPath "items[*].name" input @?= Right (Array (V.fromList [String "a", String "b"]))
        applyJmesPath "count" input @?= Right (Number 42)
        applyJmesPath "{n: count}" input @?= Right (Object (KM.fromList [("n", Number 42)]))
    ]
