module Test.SanitizeTest (sanitizeTests) where

import Data.Char (chr)
import Data.Text (Text)
import Data.Text qualified as T
import Test.QuickCheck (Gen, choose, elements, forAll, frequency, listOf)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.QuickCheck (testProperty)

import Iidy.Output.Sanitize (escapeControl, needsEscape)

sanitizeTests :: TestTree
sanitizeTests =
    testGroup
        "Output.Sanitize"
        [ testCase "ESC becomes \\u001b" $
            escapeControl "a\ESC[2Kb" @?= "a\\u001b[2Kb"
        , testCase "bare CR is escaped" $
            escapeControl "one\rtwo" @?= "one\\u000dtwo"
        , testCase "CR at end of text is escaped" $
            escapeControl "one\r" @?= "one\\u000d"
        , testCase "CR directly before LF is kept" $
            escapeControl "one\r\ntwo" @?= "one\r\ntwo"
        , testCase "only the CR not followed by LF is escaped" $
            escapeControl "a\r\r\nb" @?= "a\\u000d\r\nb"
        , testCase "NUL becomes \\u0000" $
            escapeControl "a\NULb" @?= "a\\u0000b"
        , testCase "other C0 controls are escaped" $
            escapeControl "\BEL\BS\FF\VT\SUB" @?= "\\u0007\\u0008\\u000c\\u000b\\u001a"
        , testCase "DEL becomes \\u007f" $
            escapeControl "a\DELb" @?= "a\\u007fb"
        , testCase "C1 control CSI (U+009B) is escaped" $
            escapeControl "a\x9b\&2Kb" @?= "a\\u009b2Kb"
        , testCase "C1 range boundaries" $ do
            escapeControl "\x80\x9f" @?= "\\u0080\\u009f"
            escapeControl "\xa0" @?= "\xa0"
        , testCase "right-to-left override U+202E is escaped" $
            escapeControl "a\x202e\&b" @?= "a\\u202eb"
        , testCase "line and paragraph separators are escaped" $
            escapeControl "\x2028\x2029" @?= "\\u2028\\u2029"
        , testCase "bidi embedding and isolate ranges are escaped" $
            escapeControl "\x202a\x202b\x202c\x202d\x2066\x2067\x2068\x2069"
                @?= "\\u202a\\u202b\\u202c\\u202d\\u2066\\u2067\\u2068\\u2069"
        , testCase "characters next to the escaped ranges are kept" $
            escapeControl "\x2027\x202f\x2065\x206a" @?= "\x2027\x202f\x2065\x206a"
        , testCase "tab and newline are kept" $
            escapeControl "a\tb\nc" @?= "a\tb\nc"
        , testCase "ordinary, accented and emoji text is unchanged" $ do
            let txt = "plain text, caf\233 \28450 \128077 \9583" :: Text
            escapeControl txt @?= txt
        , testCase "empty text is unchanged" $
            escapeControl "" @?= ""
        , testProperty "output has no escaped-class character (except CR before LF)" $
            forAll genText $ \t ->
                let stripped = T.replace "\r\n" "" (escapeControl t)
                 in T.all (\c -> not (needsEscape c) && c /= '\r') stripped
        , testProperty "text without escaped-class characters is unchanged" $
            forAll genCleanText $
                \t -> escapeControl t == t
        ]

-- | Text mixing ordinary characters with every escaped class.
genText :: Gen Text
genText = T.pack <$> listOf (frequency [(6, genClean), (4, genNasty)])

genCleanText :: Gen Text
genCleanText = T.pack <$> listOf genClean

genClean :: Gen Char
genClean =
    frequency
        [ (6, choose ('a', 'z'))
        , (2, elements ['\n', '\t', ' ', '\xe9', '\x4e2d', '\x1f44d'])
        , (1, choose ('\xa0', '\x2000'))
        ]

genNasty :: Gen Char
genNasty =
    frequency
        [ (4, chr <$> choose (0, 0x1f))
        , (1, pure '\DEL')
        , (2, chr <$> choose (0x80, 0x9f))
        , (1, elements ['\x2028', '\x2029'])
        , (2, chr <$> choose (0x202a, 0x202e))
        , (2, chr <$> choose (0x2066, 0x2069))
        , (1, pure '\r')
        ]
