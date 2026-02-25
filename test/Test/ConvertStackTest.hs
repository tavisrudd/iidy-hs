module Test.ConvertStackTest (convertStackTests) where

import qualified Data.Text as T
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Cfn.Operations.ConvertStack
  ( parameterizeEnv
  , parameterizeStackName
  , templateBodyToYaml
  , buildStackArgsYaml
  )

convertStackTests :: [TestTree]
convertStackTests =
  [ testCase "parameterizeEnv replaces known environments" $ do
      parameterizeEnv "my-app-production-cluster" @?= "my-app-{{environment}}-cluster"
      parameterizeEnv "my-app-staging" @?= "my-app-{{environment}}"
      parameterizeEnv "my-app-development" @?= "my-app-{{environment}}"
      parameterizeEnv "my-app-integration" @?= "my-app-{{environment}}"
      parameterizeEnv "my-app-testing" @?= "my-app-{{environment}}"

  , testCase "parameterizeEnv leaves unknown strings" $ do
      parameterizeEnv "my-app-custom" @?= "my-app-custom"

  , testCase "parameterizeStackName replaces trailing digits" $ do
      parameterizeStackName "myproject-production-api-42" "myproject"
        @?= "{{project}}-{{environment}}-api-{{build_number}}"

  , testCase "parameterizeStackName no trailing digits" $ do
      parameterizeStackName "myproject-production-api" "myproject"
        @?= "{{project}}-{{environment}}-api"

  , testCase "parameterizeStackName only project" $ do
      parameterizeStackName "myproject-custom-stack" "myproject"
        @?= "{{project}}-custom-stack"

  , testCase "templateBodyToYaml JSON to YAML" $ do
      let json = "{\"AWSTemplateFormatVersion\": \"2010-09-09\", \"Resources\": {}}"
      case templateBodyToYaml json False of
        Left err -> assertFailure $ T.unpack err
        Right yaml -> do
          assertBool "Contains AWSTemplateFormatVersion" (T.isInfixOf "AWSTemplateFormatVersion" yaml)
          assertBool "Contains Resources" (T.isInfixOf "Resources" yaml)
          assertBool "Not JSON" (not (T.isPrefixOf "{" (T.stripStart yaml)))

  , testCase "templateBodyToYaml YAML passthrough" $ do
      let input = "AWSTemplateFormatVersion: '2010-09-09'\nResources: {}\n"
      case templateBodyToYaml input False of
        Left err -> assertFailure $ T.unpack err
        Right yaml -> assertBool "Contains AWSTemplateFormatVersion" (T.isInfixOf "AWSTemplateFormatVersion" yaml)

  , testCase "sortCfnKeys reorders top level" $ do
      let input = "Resources: {}\nDescription: hello\nAWSTemplateFormatVersion: '2010-09-09'\nOutputs: {}\nParameters: {}\n"
      case templateBodyToYaml input True of
        Left err -> assertFailure $ T.unpack err
        Right yaml -> do
          let versionPos = findPos "AWSTemplateFormatVersion" yaml
              descPos = findPos "Description" yaml
              paramsPos = findPos "Parameters" yaml
              resourcesPos = findPos "Resources" yaml
              outputsPos = findPos "Outputs" yaml
          assertBool "version < desc" (versionPos < descPos)
          assertBool "desc < params" (descPos < paramsPos)
          assertBool "params < resources" (paramsPos < resourcesPos)
          assertBool "resources < outputs" (resourcesPos < outputsPos)

  , testCase "sortCfnKeys disabled does not sort" $ do
      let input = "Resources: {}\nAWSTemplateFormatVersion: '2010-09-09'\n"
      case templateBodyToYaml input False of
        Left err -> assertFailure $ T.unpack err
        Right yaml -> do
          assertBool "contains Resources" (T.isInfixOf "Resources" yaml)
          assertBool "contains Version" (T.isInfixOf "AWSTemplateFormatVersion" yaml)

  , testCase "buildStackArgsYaml basic" $ do
      let result = buildStackArgsYaml
            "myproject-production-api-42" "myproject"
            [("Environment", "production"), ("InstanceType", "t3.medium")]
            [("project", "myproject"), ("environment", "production"), ("team", "platform")]
            ["CAPABILITY_IAM"] Nothing True [] Nothing False []
      assertBool "Contains project def" (T.isInfixOf "$defs:" result)
      assertBool "Contains Template" (T.isInfixOf "Template: ./cfn-template.yaml" result)
      assertBool "Contains StackPolicy" (T.isInfixOf "StackPolicy: ./stack-policy.json" result)
      assertBool "Contains EnableTerminationProtection" (T.isInfixOf "EnableTerminationProtection: true" result)
      assertBool "Environment parameterized" (T.isInfixOf "Environment: '{{environment}}'" result)
      assertBool "InstanceType kept" (T.isInfixOf "InstanceType: t3.medium" result)
      assertBool "project tag parameterized" (T.isInfixOf "project: '{{project}}'" result)
      assertBool "CAPABILITY_IAM" (T.isInfixOf "CAPABILITY_IAM" result)

  , testCase "buildStackArgsYaml with SSM params" $ do
      let result = buildStackArgsYaml
            "myproject-production-api-42" "myproject"
            [("Environment", "production"), ("DatabasePassword", "secret123"), ("InstanceType", "t3.medium")]
            [("project", "myproject")]
            [] Nothing False [] Nothing False
            ["DatabasePassword"]
      assertBool "SSM ref for DatabasePassword" (T.isInfixOf "DatabasePassword: !$ ssmParams.DatabasePassword" result)
      assertBool "InstanceType kept" (T.isInfixOf "InstanceType: t3.medium" result)
      assertBool "ssmParams import" (T.isInfixOf "ssmParams: 'ssm-path:/{{environment}}/{{project}}/'" result)
  ]

findPos :: T.Text -> T.Text -> Int
findPos needle haystack = case T.breakOn needle haystack of
  (before, _) -> T.length before
