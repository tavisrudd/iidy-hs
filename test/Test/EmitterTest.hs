module Test.EmitterTest (emitterTests) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Yaml.Emitter (SeqStyle (..), emitYaml, emitYamlWith)
import Iidy.Yaml.Imports.ContentParsing (parseYamlOrdered)
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
    , nonPrintableTests
    , testCase "tag with a sequence argument containing a mapping has no blank line" $
        emitYaml taggedSeqWithMapping @?= "c: !Sub\n  - a${B}\n  - B: x\nd: e"
    ]
  where
    nested = OObject [("a", OObject [("c", OArray [OString "x", OString "y"])])]
    taggedSeqWithMapping =
        OObject
            [ ("c", OObject [("!Sub", OArray [OString "a${B}", OObject [("B", OString "x")]])])
            , ("d", OString "e")
            ]

-- | Strings with non-printable characters are double-quoted with YAML escapes.
nonPrintableTests :: TestTree
nonPrintableTests =
    testGroup
        "non-printable characters"
        ( map case_ cases
            <> [ testCase "TAB-only string keeps its single-quoted form" $
                    emitYaml (OString "a\tb") @?= "'a\tb'"
               , testCase "mapping key is double-quoted" $
                    roundTrip (OObject [("k\ESCey", OString "v")])
               , testCase "key and value in a mapping" $
                    emitYaml (OObject [("k\SOHy", OString "v\ESC")]) @?= "\"k\\x01y\": \"v\\e\""
               , testCase "sequence element" $
                    emitYaml (OArray [OString "x\ay"]) @?= "\n- \"x\\ay\""
               , testCase "tag argument" $
                    emitYaml (OObject [("!Sub", OString "x\ay")]) @?= "!Sub \"x\\ay\""
               , testCase "multi-line string with a control character" $
                    emitYaml (OString "a\nb\SOH") @?= "\"a\\nb\\x01\""
               , testCase "SeqFlush round trip" $
                    roundTripWith SeqFlush (OObject [("a", OArray [OString "\ESC[0m"])])
               ]
        )
  where
    case_ (name, input, expected) =
        testCase name $ do
            emitYaml (OString input) @?= expected
            roundTrip (OString input)
            roundTrip (OObject [("a", OString input)])
            roundTrip (OArray [OString input, OString input])
    roundTrip = roundTripWith SeqIndented
    roundTripWith st v = do
        let out = emitYamlWith st v
        case parseYamlOrdered out of
            Left err -> assertFailure ("re-render failed: " <> T.unpack err <> " for " <> show out)
            Right v' -> v' @?= v

cases :: [(String, Text, Text)]
cases =
    [ ("TAB and U+0001", "a\tb\SOH", "\"a\\tb\\x01\"")
    , ("ESC", "\ESC[0m", "\"\\e[0m\"")
    , ("BEL", "x\ay", "\"x\\ay\"")
    , ("NUL", "a\NULb", "\"a\\0b\"")
    , ("BS", "a\bb", "\"a\\bb\"")
    , ("VT", "a\vb", "\"a\\vb\"")
    , ("FF", "a\fb", "\"a\\fb\"")
    , ("CR", "a\rb", "\"a\\rb\"")
    , ("other C0 (US)", "a\US", "\"a\\x1F\"")
    , ("DEL", "a\DELb", "\"a\\x7Fb\"")
    , ("C1 (U+009F)", "a\x9f\&b", "\"a\\x9Fb\"")
    , ("NEL U+0085", "a\x85\&b", "\"a\\Nb\"")
    , ("U+2028", "a\x2028\&b", "\"a\\Lb\"")
    , ("U+2029", "a\x2029\&b", "\"a\\Pb\"")
    , ("BOM U+FEFF", "a\xfeff\&b", "\"a\\uFEFFb\"")
    , ("with double quote and backslash", "q\"\\\ESC", "\"q\\\"\\\\\\e\"")
    ]
