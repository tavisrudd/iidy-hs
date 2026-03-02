-- | Unit tests for pure helper functions in Iidy.Params.Client.
module Test.ParamsClientTest (paramsClientTests) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding
import Lens.Micro ((&), (.~))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool)

import qualified Amazonka.SSM as SSM
import qualified Amazonka.SSM.Types.Parameter as SSMP
import qualified Amazonka.SSM.Types.ParameterHistory as SSMPH
import qualified Amazonka.SSM.Types.ParameterType as SSMPT

import Iidy.Cli (ParamType(..))
import Iidy.Params.Client
  ( ParamOutput(..), ParamHistoryOutput(..)
  , SimpleHistory(..), SimpleHistoryCurrent(..), SimpleHistoryPrevious(..)
  , FullHistory(..)
  , formatHistoryEntry, formatParam, paramTypeToSsm
  , paramOutputFromParameter, paramHistoryOutputFromHistory
  , formatAsJson, formatAsYaml
  , messageTag
  )

paramsClientTests :: [TestTree]
paramsClientTests =
  [ testGroup "paramTypeToSsm"              paramTypeToSsmTests
  , testGroup "formatHistoryEntry"          formatHistoryEntryTests
  , testGroup "formatParam"                 formatParamTests
  , testGroup "ParamOutput conversion"      paramOutputConversionTests
  , testGroup "ParamOutput ToJSON"          paramOutputJsonTests
  , testGroup "ParamHistoryOutput conversion" paramHistoryConversionTests
  , testGroup "ParamHistoryOutput ToJSON"   paramHistoryJsonTests
  , testGroup "SimpleHistory ToJSON"        simpleHistoryJsonTests
  , testGroup "FullHistory ToJSON"          fullHistoryJsonTests
  , testGroup "formatAsJson"                formatAsJsonTests
  , testGroup "formatAsYaml"                formatAsYamlTests
  , testGroup "messageTag"                  messageTagTests
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
-- formatHistoryEntry (legacy format)
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
-- formatParam (legacy format)
------------------------------------------------------------------------

-- | Build a Parameter with the given name and value.
mkParam :: Text -> Text -> SSM.Parameter
mkParam name val =
  SSMP.newParameter name SSMPT.ParameterType_String val 1

mkParamFull :: Text -> SSMPT.ParameterType -> Text -> Integer -> SSM.Parameter
mkParamFull name pType val ver =
  SSMP.newParameter name pType val ver

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

------------------------------------------------------------------------
-- paramOutputFromParameter
------------------------------------------------------------------------

paramOutputConversionTests :: [TestTree]
paramOutputConversionTests =
  [ testCase "extracts all fields from Parameter" $ do
      let p = mkParamFull "/myapp/db-pass" SSMPT.ParameterType_SecureString "secret" 3
              & SSMP.parameter_arn .~ Just "arn:aws:ssm:us-east-1:123:parameter/myapp/db-pass"
              & SSMP.parameter_dataType .~ Just "text"
          out = paramOutputFromParameter p
      poName out @?= Just "/myapp/db-pass"
      poType out @?= Just "SecureString"
      poValue out @?= Just "secret"
      poVersion out @?= Just 3
      poArn out @?= Just "arn:aws:ssm:us-east-1:123:parameter/myapp/db-pass"
      poDataType out @?= Just "text"
      poTags out @?= Nothing

  , testCase "handles String type" $ do
      let out = paramOutputFromParameter (mkParam "/test" "val")
      poType out @?= Just "String"

  , testCase "handles StringList type" $ do
      let p = mkParamFull "/test" SSMPT.ParameterType_StringList "a,b,c" 1
          out = paramOutputFromParameter p
      poType out @?= Just "StringList"

  , testCase "tags are Nothing by default" $ do
      let out = paramOutputFromParameter (mkParam "/test" "val")
      poTags out @?= Nothing
  ]

------------------------------------------------------------------------
-- ParamOutput ToJSON
------------------------------------------------------------------------

paramOutputJsonTests :: [TestTree]
paramOutputJsonTests =
  [ testCase "uses PascalCase field names" $ do
      let out = paramOutputFromParameter (mkParam "/test" "hello")
          json = formatAsJson out
      assertContains "\"Name\"" json
      assertContains "\"Type\"" json
      assertContains "\"Value\"" json
      assertContains "\"Version\"" json

  , testCase "ARN uses uppercase (not Arn)" $ do
      let p = mkParam "/test" "val"
              & SSMP.parameter_arn .~ Just "arn:aws:ssm:us-east-1:123:parameter/test"
          json = formatAsJson (paramOutputFromParameter p)
      assertContains "\"ARN\"" json
      assertNotContains "\"Arn\"" json

  , testCase "LastModifiedDate uses multi-word casing" $ do
      let out = ParamOutput
            { poName = Just "/test"
            , poType = Just "String"
            , poValue = Just "v"
            , poVersion = Just 1
            , poLastModifiedDate = Just "2024-01-15T00:00:00Z"
            , poArn = Nothing
            , poDataType = Nothing
            , poTags = Nothing
            }
          json = formatAsJson out
      assertContains "\"LastModifiedDate\"" json

  , testCase "Tags omitted when Nothing" $ do
      let out = paramOutputFromParameter (mkParam "/test" "val")
          json = formatAsJson out
      assertNotContains "\"Tags\"" json

  , testCase "Tags included when present" $ do
      let out = (paramOutputFromParameter (mkParam "/test" "val"))
                  { poTags = Just (Map.fromList [("env", "prod")]) }
          json = formatAsJson out
      assertContains "\"Tags\"" json
      assertContains "\"env\"" json
      assertContains "\"prod\"" json

  , testCase "JSON round-trips through Aeson parse" $ do
      let out = ParamOutput
            { poName = Just "/myapp/key"
            , poType = Just "SecureString"
            , poValue = Just "secret"
            , poVersion = Just 5
            , poLastModifiedDate = Just "2024-01-15T12:00:00Z"
            , poArn = Just "arn:aws:ssm:us-east-1:123:parameter/myapp/key"
            , poDataType = Just "text"
            , poTags = Just (Map.fromList [("iidy:message", "deployed")])
            }
          json = formatAsJson out
      case Aeson.decodeStrict (encodeUtf8 json) :: Maybe Aeson.Value of
        Nothing -> assertBool "JSON should parse" False
        Just val -> do
          assertJsonField "Name" (Aeson.String "/myapp/key") val
          assertJsonField "Version" (Aeson.Number 5) val
          assertJsonField "ARN" (Aeson.String "arn:aws:ssm:us-east-1:123:parameter/myapp/key") val
  ]

------------------------------------------------------------------------
-- paramHistoryOutputFromHistory
------------------------------------------------------------------------

mkHistoryFull :: SSM.ParameterHistory
mkHistoryFull =
  SSM.newParameterHistory
    & SSMPH.parameterHistory_name          .~ Just "/myapp/db-pass"
    & SSMPH.parameterHistory_type          .~ Just SSMPT.ParameterType_SecureString
    & SSMPH.parameterHistory_keyId         .~ Just "alias/ssm/myapp/"
    & SSMPH.parameterHistory_lastModifiedUser .~ Just "arn:aws:iam::123:user/admin"
    & SSMPH.parameterHistory_description   .~ Just "DB password"
    & SSMPH.parameterHistory_value         .~ Just "old-secret"
    & SSMPH.parameterHistory_version       .~ Just 2
    & SSMPH.parameterHistory_dataType      .~ Just "text"

paramHistoryConversionTests :: [TestTree]
paramHistoryConversionTests =
  [ testCase "extracts all fields from ParameterHistory" $ do
      let out = paramHistoryOutputFromHistory mkHistoryFull
      phoName out @?= Just "/myapp/db-pass"
      phoType out @?= Just "SecureString"
      phoKeyId out @?= Just "alias/ssm/myapp/"
      phoLastModifiedUser out @?= Just "arn:aws:iam::123:user/admin"
      phoDescription out @?= Just "DB password"
      phoValue out @?= Just "old-secret"
      phoVersion out @?= Just 2
      phoDataType out @?= Just "text"
      phoTags out @?= Nothing

  , testCase "handles minimal history entry" $ do
      let h = SSM.newParameterHistory
              & SSMPH.parameterHistory_name    .~ Just "/test"
              & SSMPH.parameterHistory_value   .~ Just "val"
              & SSMPH.parameterHistory_version .~ Just 1
          out = paramHistoryOutputFromHistory h
      phoName out @?= Just "/test"
      phoKeyId out @?= Nothing
      phoDescription out @?= Nothing
  ]

------------------------------------------------------------------------
-- ParamHistoryOutput ToJSON
------------------------------------------------------------------------

paramHistoryJsonTests :: [TestTree]
paramHistoryJsonTests =
  [ testCase "KeyId omitted when Nothing" $ do
      let h = SSM.newParameterHistory
              & SSMPH.parameterHistory_name    .~ Just "/test"
              & SSMPH.parameterHistory_value   .~ Just "val"
              & SSMPH.parameterHistory_version .~ Just 1
          json = formatAsJson (paramHistoryOutputFromHistory h)
      assertNotContains "\"KeyId\"" json

  , testCase "Description omitted when Nothing" $ do
      let h = SSM.newParameterHistory
              & SSMPH.parameterHistory_name    .~ Just "/test"
              & SSMPH.parameterHistory_value   .~ Just "val"
              & SSMPH.parameterHistory_version .~ Just 1
          json = formatAsJson (paramHistoryOutputFromHistory h)
      assertNotContains "\"Description\"" json

  , testCase "Tags omitted when Nothing" $ do
      let json = formatAsJson (paramHistoryOutputFromHistory mkHistoryFull)
      assertNotContains "\"Tags\"" json

  , testCase "KeyId present when set" $ do
      let json = formatAsJson (paramHistoryOutputFromHistory mkHistoryFull)
      assertContains "\"KeyId\"" json
      assertContains "alias/ssm/myapp/" json

  , testCase "Tags included when present" $ do
      let out = (paramHistoryOutputFromHistory mkHistoryFull)
                  { phoTags = Just (Map.fromList [("iidy:message", "update")]) }
          json = formatAsJson out
      assertContains "\"Tags\"" json
      assertContains "iidy:message" json

  , testCase "LastModifiedDate and LastModifiedUser use correct casing" $ do
      let out = (paramHistoryOutputFromHistory mkHistoryFull)
                  { phoLastModifiedDate = Just "2024-01-15T12:00:00Z" }
          json = formatAsJson out
      assertContains "\"LastModifiedDate\"" json
      assertContains "\"LastModifiedUser\"" json
  ]

------------------------------------------------------------------------
-- SimpleHistory ToJSON
------------------------------------------------------------------------

simpleHistoryJsonTests :: [TestTree]
simpleHistoryJsonTests =
  [ testCase "renders Current and Previous keys" $ do
      let sh = SimpleHistory
            { shCurrent = SimpleHistoryCurrent
                { shcValue = Just "current-val"
                , shcLastModifiedDate = Just "2024-01-15T12:00:00Z"
                , shcLastModifiedUser = Just "arn:aws:iam::123:user/admin"
                , shcMessage = "deployed v2"
                }
            , shPrevious =
                [ SimpleHistoryPrevious
                    { shpValue = Just "old-val"
                    , shpLastModifiedDate = Just "2024-01-14T12:00:00Z"
                    , shpLastModifiedUser = Just "arn:aws:iam::123:user/admin"
                    }
                ]
            }
          json = formatAsJson sh
      assertContains "\"Current\"" json
      assertContains "\"Previous\"" json
      assertContains "\"Message\"" json
      assertContains "deployed v2" json
      assertContains "current-val" json
      assertContains "old-val" json

  , testCase "Message is always present (even empty)" $ do
      let sh = SimpleHistory
            { shCurrent = SimpleHistoryCurrent
                { shcValue = Just "val"
                , shcLastModifiedDate = Nothing
                , shcLastModifiedUser = Nothing
                , shcMessage = ""
                }
            , shPrevious = []
            }
          json = formatAsJson sh
      assertContains "\"Message\"" json
  ]

------------------------------------------------------------------------
-- FullHistory ToJSON
------------------------------------------------------------------------

fullHistoryJsonTests :: [TestTree]
fullHistoryJsonTests =
  [ testCase "renders Current and Previous with full fields" $ do
      let fh = FullHistory
            { fhCurrent = (paramHistoryOutputFromHistory mkHistoryFull)
                { phoTags = Just (Map.fromList [("iidy:message", "latest")]) }
            , fhPrevious =
                [ paramHistoryOutputFromHistory
                    (SSM.newParameterHistory
                      & SSMPH.parameterHistory_name    .~ Just "/myapp/db-pass"
                      & SSMPH.parameterHistory_value   .~ Just "older-secret"
                      & SSMPH.parameterHistory_version .~ Just 1)
                ]
            }
          json = formatAsJson fh
      assertContains "\"Current\"" json
      assertContains "\"Previous\"" json
      assertContains "\"Tags\"" json
      assertContains "latest" json
      -- Previous should NOT have tags
      case Aeson.decodeStrict (encodeUtf8 json) :: Maybe Aeson.Value of
        Nothing -> assertBool "JSON should parse" False
        Just (Aeson.Object obj) -> do
          case KM.lookup "Previous" obj of
            Just (Aeson.Array arr) ->
              case foldr (:) [] arr of
                (Aeson.Object prevObj : _) ->
                  assertBool "Previous entry should not have Tags"
                    (not $ KM.member "Tags" prevObj)
                _ -> assertBool "Expected non-empty Previous array with object" False
            _ -> assertBool "Expected Previous key" False
        _ -> assertBool "Expected JSON object" False
  ]

------------------------------------------------------------------------
-- formatAsJson
------------------------------------------------------------------------

formatAsJsonTests :: [TestTree]
formatAsJsonTests =
  [ testCase "produces valid pretty JSON for simple map" $ do
      let m = Map.fromList [("a" :: Text, "1" :: Text), ("b", "2")]
          json = formatAsJson m
      case Aeson.decodeStrict (encodeUtf8 json) :: Maybe Aeson.Value of
        Nothing -> assertBool "should be valid JSON" False
        Just val -> do
          assertJsonField "a" (Aeson.String "1") val
          assertJsonField "b" (Aeson.String "2") val

  , testCase "sorted keys in Map produce sorted JSON" $ do
      let m = Map.fromList [("/z/param" :: Text, "z" :: Text), ("/a/param", "a"), ("/m/param", "m")]
          json = formatAsJson m
          aPos = T.breakOn "/a/param" json
          mPos = T.breakOn "/m/param" json
          zPos = T.breakOn "/z/param" json
      assertBool "/a before /m" (T.length (fst aPos) < T.length (fst mPos))
      assertBool "/m before /z" (T.length (fst mPos) < T.length (fst zPos))
  ]

------------------------------------------------------------------------
-- formatAsYaml
------------------------------------------------------------------------

formatAsYamlTests :: [TestTree]
formatAsYamlTests =
  [ testCase "simple map to YAML" $ do
      let m = Map.fromList [("key" :: Text, "value" :: Text)]
          yaml = formatAsYaml m
      assertContains "key: value" yaml

  , testCase "multi-entry map to YAML" $ do
      let m = Map.fromList [("a" :: Text, "1" :: Text), ("b", "2")]
          yaml = formatAsYaml m
      assertContains "a: " yaml
      assertContains "b: " yaml

  , testCase "nested object to YAML" $ do
      let sh = SimpleHistory
            { shCurrent = SimpleHistoryCurrent
                { shcValue = Just "val"
                , shcLastModifiedDate = Nothing
                , shcLastModifiedUser = Nothing
                , shcMessage = "test msg"
                }
            , shPrevious = []
            }
          yaml = formatAsYaml sh
      assertContains "Current:" yaml
      assertContains "Previous:" yaml
      assertContains "Message: test msg" yaml

  , testCase "YAML quotes special strings" $ do
      let m = Map.fromList [("k" :: Text, "true" :: Text)]
          yaml = formatAsYaml m
      -- "true" should be quoted to avoid being parsed as boolean
      assertContains "'true'" yaml

  , testCase "YAML handles empty string values" $ do
      let m = Map.fromList [("k" :: Text, "" :: Text)]
          yaml = formatAsYaml m
      assertContains "''" yaml

  , testCase "YAML handles colon in values" $ do
      let m = Map.fromList [("k" :: Text, "a:b" :: Text)]
          yaml = formatAsYaml m
      -- Values with colons should be quoted
      assertContains "'a:b'" yaml

  , testCase "ParamOutput to YAML has correct fields" $ do
      let out = ParamOutput
            { poName = Just "/test/param"
            , poType = Just "String"
            , poValue = Just "myval"
            , poVersion = Just 1
            , poLastModifiedDate = Nothing
            , poArn = Nothing
            , poDataType = Nothing
            , poTags = Nothing
            }
          yaml = formatAsYaml out
      assertContains "Name: /test/param" yaml
      assertContains "Value: myval" yaml
      assertContains "Version: 1" yaml
  ]

------------------------------------------------------------------------
-- messageTag
------------------------------------------------------------------------

messageTagTests :: [TestTree]
messageTagTests =
  [ testCase "messageTag is iidy:message" $
      messageTag @?= "iidy:message"
  ]

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

assertContains :: Text -> Text -> IO ()
assertContains needle haystack =
  assertBool ("Expected to find " <> show needle <> " in:\n" <> T.unpack haystack)
    (needle `T.isInfixOf` haystack)

assertNotContains :: Text -> Text -> IO ()
assertNotContains needle haystack =
  assertBool ("Expected NOT to find " <> show needle <> " in:\n" <> T.unpack haystack)
    (not $ needle `T.isInfixOf` haystack)

assertJsonField :: Text -> Aeson.Value -> Aeson.Value -> IO ()
assertJsonField key expected (Aeson.Object obj) =
  case KM.lookup (AesonKey.fromText key) obj of
    Nothing -> assertBool ("Expected key " <> show key <> " in JSON object") False
    Just actual -> actual @?= expected
assertJsonField key _ _ =
  assertBool ("Expected JSON object with key " <> show key) False

encodeUtf8 :: Text -> Data.ByteString.ByteString
encodeUtf8 = Data.Text.Encoding.encodeUtf8
