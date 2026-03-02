module Test.OValueTest (oValueTests) where

import qualified Data.Text as T
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.OValue (OValue(..), oIsTruthy, toValue, fromValue)

oValueTests :: [TestTree]
oValueTests =
  [ testCase "truthiness: null is falsy" $
      oIsTruthy ONull @?= False

  , testCase "truthiness: false is falsy" $
      oIsTruthy (OBool False) @?= False

  , testCase "truthiness: true is truthy" $
      oIsTruthy (OBool True) @?= True

  , testCase "truthiness: empty string is falsy" $
      oIsTruthy (OString "") @?= False

  , testCase "truthiness: non-empty string is truthy" $
      oIsTruthy (OString "hello") @?= True

  , testCase "truthiness: zero is falsy (matches Rust: n != 0.0)" $
      oIsTruthy (ONumber 0) @?= False

  , testCase "truthiness: positive number is truthy" $
      oIsTruthy (ONumber 42) @?= True

  , testCase "truthiness: empty array is falsy" $
      oIsTruthy (OArray []) @?= False

  , testCase "truthiness: non-empty array is truthy" $
      oIsTruthy (OArray [ONull]) @?= True

  , testCase "toValue/fromValue round-trip null" $
      fromValue (toValue ONull) @?= ONull

  , testCase "toValue/fromValue round-trip string" $
      fromValue (toValue (OString "test")) @?= OString "test"

  , testCase "toValue/fromValue round-trip number" $
      fromValue (toValue (ONumber 3.14)) @?= ONumber 3.14

  , testCase "toValue/fromValue round-trip bool" $
      fromValue (toValue (OBool True)) @?= OBool True

  , testCase "toValue/fromValue round-trip array" $ do
      let val = OArray [OString "a", ONumber 1, OBool False]
      fromValue (toValue val) @?= val

  , testCase "emitter: string with colon needs quoting" $
      assertBool "quoted" (T.head (emitYaml (OString "key: value")) == '\'')

  , testCase "emitter: string starting with # needs quoting" $
      assertBool "quoted" (T.head (emitYaml (OString "# comment")) == '\'')

  , testCase "emitter: string yes needs quoting" $
      emitYaml (OString "yes") @?= "'yes'"

  , testCase "emitter: string no needs quoting" $
      emitYaml (OString "no") @?= "'no'"

  , testCase "emitter: string on needs quoting" $
      emitYaml (OString "on") @?= "'on'"

  , testCase "emitter: string off needs quoting" $
      emitYaml (OString "off") @?= "'off'"

  , testCase "emitter: numeric string needs quoting" $
      assertBool "quoted" (T.head (emitYaml (OString "42")) == '\'')

  , testCase "emitter: array of objects" $ do
      let val = OArray [OObject [("k", OString "v1")], OObject [("k", OString "v2")]]
          result = emitYaml val
      assertBool "starts with newline-dash" (T.isPrefixOf "\n-" result)
      assertBool "contains k: v1" (T.isInfixOf "k: v1" result)
      assertBool "contains k: v2" (T.isInfixOf "k: v2" result)
  ]
