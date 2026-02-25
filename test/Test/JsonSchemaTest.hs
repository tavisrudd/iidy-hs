module Test.JsonSchemaTest (jsonSchemaTests) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Vector as V
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Yaml.CustomResources.JsonSchema (validateSchema)

jsonSchemaTests :: [TestTree]
jsonSchemaTests =
  [ testCase "validates string type" $
      validateSchema (Object (KM.fromList [("type", String "string")])) (String "hello")
        @?= Right ()

  , testCase "rejects wrong type" $ do
      let result = validateSchema (Object (KM.fromList [("type", String "string")])) (Number 42)
      assertBool "Left" (either (const True) (const False) result)

  , testCase "validates integer type" $
      validateSchema (Object (KM.fromList [("type", String "integer")])) (Number 42)
        @?= Right ()

  , testCase "validates object with required fields" $ do
      let schema = Object (KM.fromList
            [ ("type", String "object")
            , ("required", Array (V.fromList [String "host", String "port"]))
            , ("properties", Object (KM.fromList
                [ ("host", Object (KM.fromList [("type", String "string")]))
                , ("port", Object (KM.fromList [("type", String "integer")]))
                ]))
            ])
          value = Object (KM.fromList
            [ ("host", String "db.example.com")
            , ("port", Number 5432)
            ])
      validateSchema schema value @?= Right ()

  , testCase "rejects missing required field" $ do
      let schema = Object (KM.fromList
            [ ("type", String "object")
            , ("required", Array (V.fromList [String "host", String "port"]))
            ])
          value = Object (KM.fromList [("host", String "db.example.com")])
      assertBool "Left" (either (const True) (const False) (validateSchema schema value))

  , testCase "validates array items" $ do
      let schema = Object (KM.fromList
            [ ("type", String "array")
            , ("items", Object (KM.fromList [("type", String "string")]))
            ])
          value = Array (V.fromList [String "a", String "b"])
      validateSchema schema value @?= Right ()

  , testCase "rejects invalid array item" $ do
      let schema = Object (KM.fromList
            [ ("type", String "array")
            , ("items", Object (KM.fromList [("type", String "string")]))
            ])
          value = Array (V.fromList [String "a", Number 42])
      assertBool "Left" (either (const True) (const False) (validateSchema schema value))

  , testCase "validates minimum" $
      validateSchema
        (Object (KM.fromList [("type", String "integer"), ("minimum", Number 1)]))
        (Number 5)
        @?= Right ()

  , testCase "rejects below minimum" $ do
      let result = validateSchema
            (Object (KM.fromList [("type", String "integer"), ("minimum", Number 10)]))
            (Number 5)
      assertBool "Left" (either (const True) (const False) result)

  , testCase "validates maximum" $
      validateSchema
        (Object (KM.fromList [("type", String "integer"), ("maximum", Number 100)]))
        (Number 50)
        @?= Right ()

  , testCase "validates string pattern" $
      validateSchema
        (Object (KM.fromList [("type", String "string"), ("pattern", String "^[a-z]+$")]))
        (String "hello")
        @?= Right ()

  , testCase "rejects invalid pattern match" $ do
      let result = validateSchema
            (Object (KM.fromList [("type", String "string"), ("pattern", String "^[a-z]+$")]))
            (String "HELLO")
      assertBool "Left" (either (const True) (const False) result)

  , testCase "validates minItems" $
      validateSchema
        (Object (KM.fromList [("type", String "array"), ("minItems", Number 1)]))
        (Array (V.fromList [String "a"]))
        @?= Right ()

  , testCase "rejects below minItems" $ do
      let result = validateSchema
            (Object (KM.fromList [("type", String "array"), ("minItems", Number 2)]))
            (Array (V.fromList [String "a"]))
      assertBool "Left" (either (const True) (const False) result)

  , testCase "boolean schema true accepts anything" $
      validateSchema (Bool True) (String "anything") @?= Right ()

  , testCase "boolean schema false rejects everything" $ do
      let result = validateSchema (Bool False) (String "anything")
      assertBool "Left" (either (const True) (const False) result)
  ]
