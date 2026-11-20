{- | Tests for the stack-args field conversion ('valueToStackArgs'): the full
text of every error it reports, which error wins when several fields are
wrong, and how absent, null and lenient fields convert.
-}
module Test.StackArgsFieldsTest (stackArgsFieldsTests) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector qualified as V
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Cfn.StackArgs.Fields (valueToStackArgs)
import Iidy.Cfn.Types (Capability (..), OnFailure (..), StackArgs (..))

stackArgsFieldsTests :: [TestTree]
stackArgsFieldsTests =
    [ testCase "a document that is not a mapping" $
        errorOf (String "x") @?= Just "Stack args must be a YAML mapping"
    , testCase "unknown keys come first" $
        errorOf (args [("Paramters", Null), ("StackName", Number 1)])
            @?= Just "Unknown keys in stack-args: Paramters (did you mean Parameters?)"
    , testCase "StackName missing, null or not a string" $ do
        errorOf (args []) @?= Just stackNameRequired
        errorOf (args [("StackName", Null)]) @?= Just stackNameRequired
        errorOf (args [("StackName", Bool True)]) @?= Just stackNameRequired
    , testCase "string maps" $ do
        errorOf (named [("Tags", String "x")]) @?= Just "invalid type for Tags: expected a mapping, got a string"
        errorOf (named [("Parameters", list [])]) @?= Just "invalid type for Parameters: expected a mapping, got a sequence"
        errorOf (named [("Parameters", args [("A", Number 3)])]) @?= Just "invalid type for Parameters.A: expected a string, got integer `3`"
        errorOf (named [("Tags", args [("A", Number 2.5)])]) @?= Just "invalid type for Tags.A: expected a string, got float `2.5`"
    , testCase "string map errors name the field and key (C61)" $ do
        errorOf (named [("Parameters", args [("PublicFavicon", Bool False)])])
            @?= Just "invalid type for Parameters.PublicFavicon: expected a string, got boolean `false`"
        errorOf (named [("Tags", args [("Owner", args [("team", String "x")])])])
            @?= Just "invalid type for Tags.Owner: expected a string, got a mapping"
        errorOf (named [("Parameters", args [("Subnets", list [String "a"])])])
            @?= Just "invalid type for Parameters.Subnets: expected a string, got a sequence"
    , testCase "capabilities" $ do
        errorOf (named [("Capabilities", String "CAPABILITY_IAM")])
            @?= Just "invalid type for Capabilities: expected a sequence, got a string"
        errorOf (named [("Capabilities", list [Number 1])])
            @?= Just "invalid Capabilities entry: expected a string, got an integer"
        errorOf (named [("Capabilities", list [String "NOPE"])])
            @?= Just "unrecognized Capability value: NOPE (expected CAPABILITY_IAM, CAPABILITY_NAMED_IAM, or CAPABILITY_AUTO_EXPAND)"
    , testCase "OnFailure" $ do
        errorOf (named [("OnFailure", Bool False)]) @?= Just "invalid type for OnFailure: expected a string, got a boolean"
        errorOf (named [("OnFailure", String "keep")])
            @?= Just "unrecognized OnFailure value: keep (expected DO_NOTHING, ROLLBACK, or DELETE)"
    , testCase "string lists" $ do
        errorOf (named [("NotificationARNs", args [])])
            @?= Just "invalid type for NotificationARNs: expected a sequence, got a mapping"
        errorOf (named [("ResourceTypes", list [String "a", Null])])
            @?= Just "invalid type in ResourceTypes[1]: expected a string, got null"
        errorOf (named [("UsePreviousParameterValues", list [Bool True])])
            @?= Just "invalid type in UsePreviousParameterValues[0]: expected a string, got boolean `true`"
        errorOf (named [("CommandsBefore", list [String "ok", String "ok", args []])])
            @?= Just "invalid type in CommandsBefore[2]: expected a string, got a mapping"
    , testCase "TimeoutInMinutes" $ do
        errorOf (named [("TimeoutInMinutes", Number 30.5)])
            @?= Just "invalid type for TimeoutInMinutes: expected an integer, got float `30.5`"
        errorOf (named [("TimeoutInMinutes", String "30")])
            @?= Just "invalid type for TimeoutInMinutes: expected an integer, got a string"
    , testCase "the first error wins, in field order" $ do
        let allWrong =
                [ ("Tags", String "t")
                , ("Parameters", String "p")
                , ("Capabilities", String "c")
                , ("OnFailure", Bool True)
                , ("NotificationARNs", String "n")
                , ("ResourceTypes", String "r")
                , ("UsePreviousParameterValues", String "u")
                , ("CommandsBefore", String "b")
                , ("TimeoutInMinutes", String "m")
                ]
            firstError = errorOf . named . flip drop allWrong
        errorOf (args allWrong) @?= Just stackNameRequired
        map firstError [0 .. 8]
            @?= map
                Just
                [ "invalid type for Tags: expected a mapping, got a string"
                , "invalid type for Parameters: expected a mapping, got a string"
                , "invalid type for Capabilities: expected a sequence, got a string"
                , "invalid type for OnFailure: expected a string, got a boolean"
                , "invalid type for NotificationARNs: expected a sequence, got a string"
                , "invalid type for ResourceTypes: expected a sequence, got a string"
                , "invalid type for UsePreviousParameterValues: expected a sequence, got a string"
                , "invalid type for CommandsBefore: expected a sequence, got a string"
                , "invalid type for TimeoutInMinutes: expected an integer, got a string"
                ]
    , testCase "absent and null fields convert to Nothing" $ do
        sa <- expectArgs (named [(k, Null) | k <- ["Tags", "Parameters", "Capabilities", "OnFailure", "NotificationARNs", "TimeoutInMinutes", "Template"]])
        sa @?= emptyArgs
        expectArgs (named []) >>= (@?= emptyArgs)
    , testCase "StackPolicy keeps any value, null included" $ do
        sa <- expectArgs (named [("StackPolicy", Null)])
        saStackPolicy sa @?= Just Null
    , testCase "lenient fields ignore values of the wrong type" $ do
        sa <- expectArgs (named [("Template", Number 1), ("DisableRollback", String "yes"), ("Region", Bool True)])
        sa @?= emptyArgs
    , testCase "every field converts" $ do
        sa <-
            expectArgs $
                args
                    [ ("StackName", String "s")
                    , ("Template", String "t.yaml")
                    , ("ApprovedTemplateLocation", String "s3://b/")
                    , ("Region", String "eu-west-1")
                    , ("Profile", String "p")
                    , ("Capabilities", list [String "capability_iam", String "CAPABILITY_AUTO_EXPAND"])
                    , ("Tags", args [("a", String "1")])
                    , ("Parameters", args [("B", String "2")])
                    , ("NotificationARNs", list [String "arn:n"])
                    , ("AssumeRoleARN", String "arn:a")
                    , ("ServiceRoleARN", String "arn:s")
                    , ("RoleARN", String "arn:r")
                    , ("TimeoutInMinutes", Number 30)
                    , ("OnFailure", String "delete")
                    , ("DisableRollback", Bool True)
                    , ("EnableTerminationProtection", Bool False)
                    , ("StackPolicy", args [("Statement", list [])])
                    , ("ResourceTypes", list [String "AWS::S3::Bucket"])
                    , ("UsePreviousTemplate", Bool True)
                    , ("UsePreviousParameterValues", list [String "B"])
                    , ("CommandsBefore", list [String "make"])
                    , ("$envValues", args [])
                    ]
        sa
            @?= StackArgs
                { saStackName = "s"
                , saTemplate = Just "t.yaml"
                , saApprovedTemplateLocation = Just "s3://b/"
                , saRegion = Just "eu-west-1"
                , saProfile = Just "p"
                , saCapabilities = Just [CapIAM, CapAutoExpand]
                , saTags = Just (Map.fromList [("a", "1")])
                , saParameters = Just (Map.fromList [("B", "2")])
                , saNotificationArns = Just ["arn:n"]
                , saAssumeRoleArn = Just "arn:a"
                , saServiceRoleArn = Just "arn:s"
                , saRoleArn = Just "arn:r"
                , saTimeoutInMinutes = Just 30
                , saOnFailure = Just Delete
                , saDisableRollback = Just True
                , saEnableTerminationProtection = Just False
                , saStackPolicy = Just (args [("Statement", list [])])
                , saResourceTypes = Just ["AWS::S3::Bucket"]
                , saUsePreviousTemplate = Just True
                , saUsePreviousParameterValues = Just ["B"]
                , saCommandsBefore = Just ["make"]
                }
    ]

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

stackNameRequired :: Text
stackNameRequired = "StackName is required in stack-args"

args :: [(Text, Value)] -> Value
args pairs = Object (KM.fromList [(Key.fromText k, v) | (k, v) <- pairs])

-- | A mapping with a valid StackName and the given fields.
named :: [(Text, Value)] -> Value
named pairs = args (("StackName", String "s") : pairs)

list :: [Value] -> Value
list = Array . V.fromList

errorOf :: Value -> Maybe Text
errorOf = either Just (const Nothing) . valueToStackArgs

expectArgs :: Value -> IO StackArgs
expectArgs v = either (assertFailure . ("expected stack args: " <>) . show) pure (valueToStackArgs v)

-- | The conversion of a mapping holding only @StackName: s@.
emptyArgs :: StackArgs
emptyArgs =
    StackArgs
        { saStackName = "s"
        , saTemplate = Nothing
        , saApprovedTemplateLocation = Nothing
        , saRegion = Nothing
        , saProfile = Nothing
        , saCapabilities = Nothing
        , saTags = Nothing
        , saParameters = Nothing
        , saNotificationArns = Nothing
        , saAssumeRoleArn = Nothing
        , saServiceRoleArn = Nothing
        , saRoleArn = Nothing
        , saTimeoutInMinutes = Nothing
        , saOnFailure = Nothing
        , saDisableRollback = Nothing
        , saEnableTerminationProtection = Nothing
        , saStackPolicy = Nothing
        , saResourceTypes = Nothing
        , saUsePreviousTemplate = Nothing
        , saUsePreviousParameterValues = Nothing
        , saCommandsBefore = Nothing
        }
