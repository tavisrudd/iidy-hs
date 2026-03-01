module Test.CfnYamlEmitterTest (cfnYamlEmitterTests) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Vector as V
import Data.Aeson (Value(..))
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Cfn.Operations.ConvertStack
  ( emitCfnYaml, templateBodyToYaml, inlineValue, quoteYamlString )

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

obj :: [(String, Value)] -> Value
obj pairs = Object $ KM.fromList [ (Key.fromString k, v) | (k, v) <- pairs ]

arr :: [Value] -> Value
arr = Array . V.fromList

int :: Integer -> Value
int = Number . fromInteger

-- Decode a JSON number literal to get a Value with a Scientific number inside.
-- E.g. numFrom "0.1" gives Number 0.1
numFrom :: String -> Value
numFrom s = case Aeson.decode (BLC.pack ("[" <> s <> "]")) of
  Just (Array v) | not (V.null v) -> V.head v
  _ -> error $ "numFrom: invalid number literal: " <> s

------------------------------------------------------------------------
-- Tests
------------------------------------------------------------------------

cfnYamlEmitterTests :: [TestTree]
cfnYamlEmitterTests =
  [ testGroup "inlineValue"
    [ testGroup "numbers"
      [ testCase "integer emits without decimal" $
          inlineValue (int 100) @?= "100"

      , testCase "large integer no scientific notation" $
          inlineValue (int 1000000) @?= "1000000"

      , testCase "zero emits as integer" $
          inlineValue (int 0) @?= "0"

      , testCase "negative integer" $
          inlineValue (int (-42)) @?= "-42"

      , testCase "float emits with decimal" $
          inlineValue (numFrom "0.1") @?= "0.1"

      , testCase "float not in scientific notation" $ do
          let result = inlineValue (numFrom "0.1")
          assertBool "no 'e' in float output" (not ('e' `elem` T.unpack result))

      , testCase "1.0e2 emits as integer 100" $
          inlineValue (numFrom "1.0e2") @?= "100"
      ]

    , testGroup "booleans"
      [ testCase "true emits lowercase" $
          inlineValue (Bool True) @?= "true"

      , testCase "false emits lowercase" $
          inlineValue (Bool False) @?= "false"
      ]

    , testGroup "null"
      [ testCase "null emits as null" $
          inlineValue Null @?= "null"
      ]

    , testGroup "empty collections"
      [ testCase "empty object emits {}" $
          inlineValue (obj []) @?= "{}"

      , testCase "empty array emits []" $
          inlineValue (arr []) @?= "[]"
      ]

    , testGroup "strings"
      [ testCase "plain string passes through" $
          inlineValue (String "hello") @?= "hello"

      , testCase "empty string quotes as ''" $
          inlineValue (String "") @?= "''"

      , testCase "string 'true' is quoted" $
          inlineValue (String "true") @?= "'true'"

      , testCase "string 'null' is quoted" $
          inlineValue (String "null") @?= "'null'"
      ]
    ]

  , testGroup "quoteYamlString"
    [ testCase "plain string unchanged" $
        quoteYamlString "hello" @?= "hello"

    , testCase "empty string becomes ''" $
        quoteYamlString "" @?= "''"

    , testCase "true is quoted" $
        quoteYamlString "true" @?= "'true'"

    , testCase "false is quoted" $
        quoteYamlString "false" @?= "'false'"

    , testCase "null is quoted" $
        quoteYamlString "null" @?= "'null'"

    , testCase "yes is quoted" $
        quoteYamlString "yes" @?= "'yes'"

    , testCase "no is quoted" $
        quoteYamlString "no" @?= "'no'"

    , testCase "colon triggers quoting" $
        quoteYamlString "key:value" @?= "'key:value'"

    , testCase "leading space triggers quoting" $
        quoteYamlString " leading" @?= "' leading'"

    , testCase "trailing space triggers quoting" $
        quoteYamlString "trailing " @?= "'trailing '"

    , testCase "plain single quote does not trigger quoting" $
        quoteYamlString "it's" @?= "it's"

    , testCase "single quote in string needing quoting is escaped" $
        -- colon triggers quoting; the single quote inside is then escaped
        quoteYamlString "key:it's" @?= "'key:it''s'"

    , testCase "hash triggers quoting" $
        quoteYamlString "a#b" @?= "'a#b'"

    , testCase "square bracket triggers quoting" $
        quoteYamlString "[item]" @?= "'[item]'"

    , testCase "ampersand triggers quoting" $
        quoteYamlString "&anchor" @?= "'&anchor'"

    , testGroup "YAML number-like strings"
      [ testCase "integer string is quoted" $
          quoteYamlString "123" @?= "'123'"

      , testCase "zero string is quoted" $
          quoteYamlString "0" @?= "'0'"

      , testCase "negative integer string is quoted" $
          quoteYamlString "-7" @?= "'-7'"

      , testCase "positive integer string is quoted" $
          quoteYamlString "+42" @?= "'+42'"

      , testCase "float string is quoted" $
          quoteYamlString "0.5" @?= "'0.5'"

      , testCase "scientific notation string is quoted" $
          quoteYamlString "1e3" @?= "'1e3'"

      , testCase "negative float string is quoted" $
          quoteYamlString "-3.14" @?= "'-3.14'"

      , testCase "positive float string is quoted" $
          quoteYamlString "+1.0" @?= "'+1.0'"

      , testCase "string starting with digit then alpha is quoted" $
          quoteYamlString "3abc" @?= "'3abc'"

      , testCase "bare minus not followed by digit is not number-quoted" $
          quoteYamlString "-abc" @?= "-abc"
      ]

    , testGroup "YAML dash-sequence strings"
      [ testCase "bare dash is quoted" $
          quoteYamlString "-" @?= "'-'"

      , testCase "dash-space prefix is quoted" $
          quoteYamlString "- item" @?= "'- item'"

      , testCase "dash without space (not sequence) is not quoted" $
          quoteYamlString "-abc" @?= "-abc"
      ]

    , testGroup "YAML tilde (null alias)"
      [ testCase "tilde is quoted" $
          quoteYamlString "~" @?= "'~'"

      , testCase "tilde in longer string is not quoted" $
          quoteYamlString "a~b" @?= "a~b"
      ]

    , testGroup "YAML dot-prefix strings"
      [ testCase "dot-prefixed string is quoted" $
          quoteYamlString ".inf" @?= "'.inf'"

      , testCase "dot-nan is quoted" $
          quoteYamlString ".nan" @?= "'.nan'"

      , testCase "bare dot is quoted" $
          quoteYamlString "." @?= "'.'"

      , testCase "dotfile-like path is quoted" $
          quoteYamlString ".hidden" @?= "'.hidden'"
      ]

    , testGroup "YAML single-quote prefix strings"
      [ testCase "string starting with single quote is quoted" $
          quoteYamlString "'hello" @?= "'''hello'"

      , testCase "bare single quote is quoted" $
          quoteYamlString "'" @?= "''''"
      ]

    , testGroup "control characters (double-quoted)"
      [ testCase "string with newline is double-quoted with \\n escape" $
          quoteYamlString "line1\nline2" @?= "\"line1\\nline2\""

      , testCase "string with tab is double-quoted with \\t escape" $
          quoteYamlString "col1\tcol2" @?= "\"col1\\tcol2\""

      , testCase "string with \\r\\n is double-quoted with \\r\\n escapes" $
          quoteYamlString "line1\r\nline2" @?= "\"line1\\r\\nline2\""

      , testCase "string with newline and single quote uses double-quoting" $
          quoteYamlString "it's\na test" @?= "\"it's\\na test\""

      , testCase "string with backslash and newline escapes both" $
          quoteYamlString "path\\to\nfile" @?= "\"path\\\\to\\nfile\""

      , testCase "string with embedded double quote escapes it" $
          quoteYamlString "say \"hello\"\n" @?= "\"say \\\"hello\\\"\\n\""

      , testCase "plain string with no special chars is unquoted" $
          quoteYamlString "hello world" @?= "hello world"
      ]
    ]

  , testGroup "emitCfnYaml"
    [ testGroup "scalar values"
      [ testCase "string value" $ do
          let result = emitCfnYaml False (obj [("Key", String "value")])
          result @?= "Key: value\n"

      , testCase "integer value" $ do
          let result = emitCfnYaml False (obj [("Count", int 42)])
          result @?= "Count: 42\n"

      , testCase "boolean value" $ do
          let result = emitCfnYaml False (obj [("Enabled", Bool True)])
          result @?= "Enabled: true\n"

      , testCase "null value" $ do
          let result = emitCfnYaml False (obj [("Value", Null)])
          result @?= "Value: null\n"
      ]

    , testGroup "nested objects"
      [ testCase "nested object indents two spaces" $ do
          let nested = obj [("Inner", String "val")]
              result = emitCfnYaml False (obj [("Outer", nested)])
          result @?= "Outer:\n  Inner: val\n"

      , testCase "deeply nested object" $ do
          let deep = obj [("Deep", String "x")]
              mid  = obj [("Mid", deep)]
              result = emitCfnYaml False (obj [("Top", mid)])
          result @?= "Top:\n  Mid:\n    Deep: x\n"
      ]

    , testGroup "arrays"
      [ testCase "simple string array" $ do
          let result = emitCfnYaml False (obj [("Items", arr [String "a", String "b"])])
          result @?= "Items:\n  - a\n  - b\n"

      , testCase "integer array" $ do
          let result = emitCfnYaml False (obj [("Ports", arr [int 80, int 443])])
          result @?= "Ports:\n  - 80\n  - 443\n"

      , testCase "empty array emits []" $ do
          let result = emitCfnYaml False (obj [("Items", arr [])])
          result @?= "Items: []\n"
      ]

    , testGroup "empty collections"
      [ testCase "empty top-level object emits {}" $ do
          let result = emitCfnYaml False (obj [])
          result @?= "{}\n"

      , testCase "nested empty object emits {}" $ do
          let result = emitCfnYaml False (obj [("Empty", obj [])])
          result @?= "Empty: {}\n"
      ]

    , testGroup "objects within arrays"
      [ testCase "array of objects — first key inline" $ do
          let item = obj [("Name", String "foo"), ("Value", String "bar")]
              result = emitCfnYaml False (obj [("Tags", arr [item])])
          assertBool "contains '- Name: foo'" (T.isInfixOf "- Name: foo" result)
          assertBool "contains 'Value: bar'" (T.isInfixOf "Value: bar" result)

      , testCase "array of objects with nested object in first key" $ do
          let inner = obj [("Ref", String "Param")]
              item  = obj [("Value", inner)]
              result = emitCfnYaml False (obj [("List", arr [item])])
          assertBool "contains '- Value:'" (T.isInfixOf "- Value:" result)
          assertBool "contains 'Ref: Param'" (T.isInfixOf "Ref: Param" result)
      ]

    , testGroup "templateBodyToYaml round-trip"
      [ testCase "JSON integer stays integer not float" $ do
          let json = "{\"Count\": 100}"
          case templateBodyToYaml json False of
            Left err -> assertFailure (T.unpack err)
            Right yaml -> assertBool "no scientific notation" (T.isInfixOf "Count: 100" yaml)

      , testCase "JSON boolean stays lowercase" $ do
          let json = "{\"Flag\": true}"
          case templateBodyToYaml json False of
            Left err -> assertFailure (T.unpack err)
            Right yaml -> assertBool "lowercase true" (T.isInfixOf "Flag: true" yaml)

      , testCase "JSON null emits null" $ do
          let json = "{\"Val\": null}"
          case templateBodyToYaml json False of
            Left err -> assertFailure (T.unpack err)
            Right yaml -> assertBool "null keyword" (T.isInfixOf "Val: null" yaml)

      , testCase "invalid JSON returns Left" $ do
          let bad = "{not valid json}"
          case templateBodyToYaml bad False of
            Left _  -> pure ()  -- expected
            Right _ -> assertFailure "expected parse error"
      ]
    ]
  ]
