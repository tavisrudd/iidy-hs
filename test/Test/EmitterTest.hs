module Test.EmitterTest (emitterTests) where

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Yaml.Emitter (SeqStyle (..), emitYaml, emitYamlWith)
import Iidy.Yaml.OValue (OValue (..))

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
    , testGroup "SeqFlush (serde_yaml layout)" seqFlushTests
    ]

seqFlushTests :: [TestTree]
seqFlushTests =
    [ testCase "sequence under a key: dashes at the key's column" $
        emitYamlWith SeqFlush nested @?= "a:\n  c:\n  - x\n  - y"
    , testCase "same value with SeqIndented keeps the indented dashes" $
        emitYamlWith SeqIndented nested @?= "a:\n  c:\n    - x\n    - y"
    , testCase "root sequence has no leading newline" $
        emitYamlWith SeqFlush (OArray [OString "a", OString "b"]) @?= "- a\n- b"
    , testCase "sequence of sequences is inline" $
        emitYamlWith SeqFlush (OObject [("g", OArray [OArray [ONumber 1, ONumber 2]])])
            @?= "g:\n- - 1\n  - 2"
    ]
  where
    nested = OObject [("a", OObject [("c", OArray [OString "x", OString "y"])])]
