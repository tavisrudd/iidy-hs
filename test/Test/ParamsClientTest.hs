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

import Iidy.Cli (ParamType(..))
import Iidy.Params.Client (formatHistoryEntry, formatParam, paramTypeToSsm)

paramsClientTests :: [TestTree]
paramsClientTests =
  [ testGroup "paramTypeToSsm"     paramTypeToSsmTests
  , testGroup "formatHistoryEntry" formatHistoryEntryTests
  , testGroup "formatParam"        formatParamTests
  ]

------------------------------------------------------------------------
-- paramTypeToSsm
------------------------------------------------------------------------

paramTypeToSsmTests :: [TestTree]
paramTypeToSsmTests =
  [ testCase "ParamString -> ParameterType_String" $
      paramTypeToSsm ParamString
        @?= SSMPT.ParameterType_String

  , testCase "ParamSecureString -> ParameterType_SecureString" $
      paramTypeToSsm ParamSecureString
        @?= SSMPT.ParameterType_SecureString

  , testCase "ParamStringList -> ParameterType_StringList" $
      paramTypeToSsm ParamStringList
        @?= SSMPT.ParameterType_StringList
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
