-- | Unit tests for pure helper functions in Iidy.Params.Client.
module Test.ParamsClientTest (paramsClientTests) where

import Data.Text (Text)
import Lens.Micro ((&), (.~))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import qualified Amazonka.SSM as SSM
import qualified Amazonka.SSM.Types.Parameter as SSMP
import qualified Amazonka.SSM.Types.ParameterHistory as SSMPH
import qualified Amazonka.SSM.Types.ParameterType as SSMPT

import Iidy.Params.Client (formatHistoryEntry, formatParam, textToParameterType)

paramsClientTests :: [TestTree]
paramsClientTests =
  [ testGroup "textToParameterType" textToParameterTypeTests
  , testGroup "formatHistoryEntry"  formatHistoryEntryTests
  , testGroup "formatParam"         formatParamTests
  ]

------------------------------------------------------------------------
-- textToParameterType
------------------------------------------------------------------------

textToParameterTypeTests :: [TestTree]
textToParameterTypeTests =
  [ testCase "securestring (lower) -> SecureString" $
      textToParameterType "securestring"
        @?= Just SSMPT.ParameterType_SecureString

  , testCase "SecureString (mixed case) -> SecureString" $
      textToParameterType "SecureString"
        @?= Just SSMPT.ParameterType_SecureString

  , testCase "SECURESTRING (upper) -> SecureString" $
      textToParameterType "SECURESTRING"
        @?= Just SSMPT.ParameterType_SecureString

  , testCase "stringlist -> StringList" $
      textToParameterType "stringlist"
        @?= Just SSMPT.ParameterType_StringList

  , testCase "StringList (mixed case) -> StringList" $
      textToParameterType "StringList"
        @?= Just SSMPT.ParameterType_StringList

  , testCase "string -> String" $
      textToParameterType "string"
        @?= Just SSMPT.ParameterType_String

  , testCase "String (mixed case) -> String" $
      textToParameterType "String"
        @?= Just SSMPT.ParameterType_String

  , testCase "unknown value defaults to String" $
      textToParameterType "unknown"
        @?= Just SSMPT.ParameterType_String

  , testCase "empty string defaults to String" $
      textToParameterType ""
        @?= Just SSMPT.ParameterType_String
  ]

------------------------------------------------------------------------
-- formatHistoryEntry
------------------------------------------------------------------------

-- | Build a ParameterHistory with optional version and value.
mkHistory :: Maybe Integer -> Maybe Text -> SSM.ParameterHistory
mkHistory mVer mVal =
  SSM.newParameterHistory
    & SSMPH.parameterHistory_version .~ mVer
    & SSMPH.parameterHistory_value   .~ mVal

formatHistoryEntryTests :: [TestTree]
formatHistoryEntryTests =
  [ testCase "version and value present -> vN: value" $
      formatHistoryEntry (mkHistory (Just 3) (Just "hello"))
        @?= Just "v3: hello"

  , testCase "version 1 and value present -> v1: value" $
      formatHistoryEntry (mkHistory (Just 1) (Just "first"))
        @?= Just "v1: first"

  , testCase "only value present -> value only" $
      formatHistoryEntry (mkHistory Nothing (Just "hello"))
        @?= Just "hello"

  , testCase "only version present -> Nothing" $
      formatHistoryEntry (mkHistory (Just 2) Nothing)
        @?= Nothing

  , testCase "neither version nor value -> Nothing" $
      formatHistoryEntry (mkHistory Nothing Nothing)
        @?= Nothing
  ]

------------------------------------------------------------------------
-- formatParam
------------------------------------------------------------------------

-- | Build a Parameter with the given name and value.
-- Parameter requires name, type, value, and version arguments.
mkParam :: Text -> Text -> SSM.Parameter
mkParam name val =
  SSMP.newParameter name SSMPT.ParameterType_String val 1

formatParamTests :: [TestTree]
formatParamTests =
  [ testCase "name=value format" $
      formatParam (mkParam "myname" "myval")
        @?= "myname=myval"

  , testCase "path-style name with value" $
      formatParam (mkParam "/prod/db/password" "s3cr3t")
        @?= "/prod/db/password=s3cr3t"

  , testCase "empty value produces name=" $
      formatParam (mkParam "key" "")
        @?= "key="
  ]
