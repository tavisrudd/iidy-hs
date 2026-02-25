module Test.EmitterTest (emitterTests) where

import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.OValue (OValue(..))

emitterTests :: [TestTree]
emitterTests =
  [ testCase "emit null" $
      emitYaml ONull @?= "null"

  , testCase "emit true" $
      emitYaml (OBool True) @?= "true"

  , testCase "emit false" $
      emitYaml (OBool False) @?= "false"

  , testCase "emit integer" $
      emitYaml (ONumber 42) @?= "42"

  , testCase "emit float" $
      emitYaml (ONumber 3.14) @?= "3.14"

  , testCase "emit simple string" $
      emitYaml (OString "hello") @?= "hello"

  , testCase "emit string needing quotes (bool word)" $
      emitYaml (OString "true") @?= "'true'"

  , testCase "emit string needing quotes (null word)" $
      emitYaml (OString "null") @?= "'null'"

  , testCase "emit empty string with quotes" $
      emitYaml (OString "") @?= "''"

  , testCase "emit empty array" $
      emitYaml (OArray []) @?= "[]"

  , testCase "emit simple array" $
      emitYaml (OArray [OString "a", OString "b"]) @?= "\n- a\n- b"

  , testCase "emit empty object" $
      emitYaml (OObject []) @?= "{}"

  , testCase "emit simple mapping" $
      emitYaml (OObject [("key", OString "value")]) @?= "key: value"

  , testCase "emit nested mapping" $
      let inner = OObject [("b", ONumber 1)]
          outer = OObject [("a", inner)]
      in emitYaml outer @?= "a:\n  b: 1"

  , testCase "emit CloudFormation tag" $ do
      let cfn = OObject [("!Ref", OString "Bucket")]
      emitYaml cfn @?= "!Ref Bucket"

  , testCase "emit multiline string" $ do
      let s = OString "line1\nline2"
      emitYaml s @?= "|-\n  line1\n  line2"
  ]
