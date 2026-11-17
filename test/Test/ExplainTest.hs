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

import Iidy.Explain (ErrorEntry (..), allErrors, explainErrors, explainOutput)
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
    , testCase "no codes: Rust's prompt on stderr, nothing on stdout" $
        explainOutput [] @?= ([], ["Please provide one or more error codes to explain (e.g., ERR_2001)"])
    , testCase "no codes: explainErrors returns normally, so the command exits 0" $
        -- app/Main.hs dispatches CmdExplain codes -> explainErrors codes and
        -- then falls off the end of main without calling exitWith.
        explainErrors []
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
    , testCase "every description equals Rust's description() (ids.rs:110-170)" $
        [(ecCode e, ecDescription e) | e <- allErrors] @?= rustDescriptions
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

{- | Rust's @ErrorId::description()@ per code (~/src/iidy/src/yaml/errors/ids.rs:110-170),
kept as data so no Rust file is read at run time.
-}
rustDescriptions :: [(Text, Text)]
rustDescriptions =
    [ ("ERR_1001", "Invalid YAML syntax")
    , ("ERR_1002", "YAML version mismatch")
    , ("ERR_1003", "Unsupported YAML feature")
    , ("ERR_1004", "Malformed YAML structure")
    , ("ERR_1005", "YAML merge key not supported in 1.2")
    , ("ERR_2001", "Variable not found")
    , ("ERR_2002", "Variable name collision")
    , ("ERR_2003", "Invalid variable name")
    , ("ERR_2004", "Circular variable reference")
    , ("ERR_2005", "Variable access out of scope")
    , ("ERR_2006", "Lookup query failed")
    , ("ERR_3001", "Import file not found")
    , ("ERR_3002", "Import URL unreachable")
    , ("ERR_3003", "Import authentication failure")
    , ("ERR_3004", "Import circular dependency")
    , ("ERR_3005", "Import format not supported")
    , ("ERR_3006", "Environment variable not found")
    , ("ERR_3007", "Git command failure")
    , ("ERR_3008", "S3 access denied")
    , ("ERR_3009", "SSM parameter not found")
    , ("ERR_3010", "CloudFormation stack not found")
    , ("ERR_4001", "Unknown preprocessing tag")
    , ("ERR_4002", "Missing required tag field")
    , ("ERR_4003", "Invalid tag field value")
    , ("ERR_4004", "Incompatible tag combination")
    , ("ERR_4005", "Tag syntax error")
    , ("ERR_5001", "Type mismatch in operation")
    , ("ERR_5002", "Invalid array operation")
    , ("ERR_5003", "Invalid object operation")
    , ("ERR_5004", "Division by zero")
    , ("ERR_5005", "Invalid comparison")
    , ("ERR_5006", "String operation on non-string")
    , ("ERR_6001", "Handlebars syntax error")
    , ("ERR_6002", "Unknown handlebars helper")
    , ("ERR_6003", "Handlebars helper argument error")
    , ("ERR_6004", "Template compilation failure")
    , ("ERR_6005", "Template execution error")
    , ("ERR_7001", "Invalid CloudFormation intrinsic function")
    , ("ERR_7002", "CloudFormation reference error")
    , ("ERR_7003", "CloudFormation dependency issue")
    , ("ERR_7004", "CloudFormation template size limit")
    , ("ERR_8001", "Invalid command line argument")
    , ("ERR_8002", "Missing required configuration")
    , ("ERR_8003", "Configuration file not found")
    , ("ERR_8004", "AWS credentials not configured")
    , ("ERR_8005", "Unsupported file format")
    , ("ERR_9001", "Internal processing error")
    , ("ERR_9002", "Memory allocation failure")
    , ("ERR_9003", "File system permission denied")
    , ("ERR_9004", "Network connectivity issue")
    , ("ERR_9005", "Unexpected system error")
    ]
