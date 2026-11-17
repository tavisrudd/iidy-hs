{- | Tests for the explain command: code normalisation, stdout/stderr split,
exact entry layout, and consistency with the 'ErrorId' type.
-}
module Test.ExplainTest (explainTests) where

import Data.List qualified as List
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Read (readMaybe)

import Iidy.Explain (ErrorEntry (..), allErrors, explainOutput)
import Iidy.Yaml.Errors.Ids (errorIdCode, errorIdFromCode)

explainTests :: [TestTree]
explainTests =
    [ testGroup "code spellings" spellingTests
    , testGroup "streams" streamTests
    , testGroup "ErrorId consistency" consistencyTests
    ]

-- | The stdout lines for one code.
stdoutFor :: Text -> [Text]
stdoutFor code = fst (explainOutput [code])

------------------------------------------------------------------------
-- Spellings and exact layout
------------------------------------------------------------------------

spellingTests :: [TestTree]
spellingTests =
    [ testCase "canonical ERR_2001 prints header, category, description, blank, details" $
        stdoutFor "ERR_2001"
            @?= [ "Error ERR_2001"
                , "Category: Variable & Scope"
                , "Description: Variable not found"
                , ""
                , "A !$ or {{...}} reference names a variable that is not defined in $defs or\n\
                  \$imports. Check spelling and that the variable is defined before it is used."
                ]
    , testCase "canonical ERR_2001 has nothing on stderr" $
        snd (explainOutput ["ERR_2001"]) @?= []
    , testCase "lower-case err_2001 resolves to the same entry" $
        stdoutFor "err_2001" @?= stdoutFor "ERR_2001"
    , testCase "bare 2001 resolves to the same entry" $
        stdoutFor "2001" @?= stdoutFor "ERR_2001"
    , testCase "1 pads to ERR_0001, which is unknown" $
        explainOutput ["1"] @?= ([], ["Unknown error code: 1"])
    ]

------------------------------------------------------------------------
-- Streams
------------------------------------------------------------------------

streamTests :: [TestTree]
streamTests =
    [ testCase "unknown code: stderr text echoes the input, stdout empty" $
        explainOutput ["ERR_9999"] @?= ([], ["Unknown error code: ERR_9999"])
    , testCase "several codes keep stdout and stderr separate, in order" $ do
        let (out, err) = explainOutput ["ERR_1001", "nope", "3006"]
        out @?= stdoutFor "ERR_1001" <> stdoutFor "ERR_3006"
        err @?= ["Unknown error code: nope"]
    , testCase "no codes: usage line on stderr, nothing on stdout" $
        explainOutput [] @?= ([], ["Usage: iidy explain <CODE>..."])
    ]

------------------------------------------------------------------------
-- Consistency with Iidy.Yaml.Errors.Ids
------------------------------------------------------------------------

-- | The code text ("ERR_NNNN") of every 'ErrorId' the type defines.
idCodes :: [Text]
idCodes =
    [ "ERR_" <> T.pack (show (errorIdCode eid))
    | n <- [1000 .. 9999 :: Int]
    , Just eid <- [errorIdFromCode n]
    ]

consistencyTests :: [TestTree]
consistencyTests =
    [ testCase "the ErrorId range is non-empty" $
        assertBool "no ErrorId codes found" (not (null idCodes))
    , testCase "every ErrorId has an entry with category and description" $
        mapM_ checkEntry idCodes
    , testCase "every entry code maps back to an ErrorId" $
        mapM_ (checkMapsBack . ecCode) allErrors
    , testCase "entry codes are unique" $
        List.sort (map ecCode allErrors) @?= List.nub (List.sort (map ecCode allErrors))
    , testCase "entries and ErrorIds cover the same codes" $
        List.sort (map ecCode allErrors) @?= List.sort idCodes
    ]
  where
    checkEntry code =
        case [e | e <- allErrors, ecCode e == code] of
            [e] -> do
                assertBool (T.unpack code <> ": empty category") (not (T.null (ecCategory e)))
                assertBool (T.unpack code <> ": empty description") (not (T.null (ecDescription e)))
            es -> assertFailure (T.unpack code <> ": expected one entry, found " <> show (length es))
    checkMapsBack code =
        case T.stripPrefix "ERR_" code >>= readMaybe . T.unpack >>= errorIdFromCode of
            Just eid -> "ERR_" <> T.pack (show (errorIdCode eid)) @?= code
            Nothing -> assertFailure (T.unpack code <> ": does not map to an ErrorId")
