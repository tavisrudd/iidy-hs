-- | Init stack args: scaffolds stack-args.yaml and cfn-template.yaml.
module Iidy.InitStackArgs
  ( runInitStackArgs
  ) where

import System.Directory (doesFileExist)
import System.IO (hPutStrLn, stderr)

import Iidy.Cli (InitStackArgs(..))

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- | Initialize stack-args.yaml and cfn-template.yaml files.
-- Respects force flags for selective overwriting.
runInitStackArgs :: InitStackArgs -> IO Int
runInitStackArgs args = do
  let forceStackArgs   = isaForce args || isaForceStackArgs args
      forceCfnTemplate = isaForce args || isaForceCfnTemplate args
  writeIfAbsent "stack-args.yaml" stackArgsTemplate forceStackArgs
  writeIfAbsent "cfn-template.yaml" cfnTemplate forceCfnTemplate
  pure 0

------------------------------------------------------------------------
-- Templates
------------------------------------------------------------------------

stackArgsTemplate :: String
stackArgsTemplate = unlines
  [ "# INITIALIZED STACK ARGS"
  , "# $imports:"
  , "#   environment: env:ENVIRONMENT"
  , ""
  , "# REQUIRED SETTINGS:"
  , "StackName: <string>"
  , "Template: ./cfn-template.yaml"
  , "# optionally you can use the yaml pre-processor by prepending 'render:' to the filename"
  , "# Template: render:<local file path or s3 path>"
  , "# ApprovedTemplateLocation: s3://your-bucket/"
  , ""
  , "# OPTIONAL SETTINGS:"
  , "# Region: <aws region name>"
  , "# Profile: <aws profile name>"
  , ""
  , "# aws tags to apply to the stack"
  , "Tags:"
  , "#   owner: <your name>"
  , "#   environment: development"
  , "#   project: <your project>"
  , "#   lifetime: short"
  , ""
  , "# stack parameters"
  , "Parameters:"
  , "#   key1: value"
  , "#   key2: value"
  , ""
  , "# optional list. *Preferably empty*"
  , "Capabilities:"
  , "#   - CAPABILITY_IAM"
  , "#   - CAPABILITY_NAMED_IAM"
  , ""
  , "NotificationARNs:"
  , "#   - <sns arn>"
  , ""
  , "# CloudFormation ServiceRole"
  , "# RoleARN: arn:aws:iam::<acount>:role/<rolename>"
  , ""
  , "# TimeoutInMinutes: <number>"
  , ""
  , "# OnFailure defaults to ROLLBACK"
  , "# OnFailure: 'ROLLBACK' | 'DELETE' | 'DO_NOTHING'"
  , ""
  , "# StackPolicy: <local file path or s3 path>"
  , ""
  , "# see http://docs.aws.amazon.com/cli/latest/reference/cloudformation/create-stack.html#options"
  , "# ResourceTypes: <list of aws resource types allowed in the template>"
  , ""
  , "# shell commands to run prior the cfn stack operation"
  , "# CommandsBefore:"
  , "#   - make build # for example"
  ]

cfnTemplate :: String
cfnTemplate = unlines
  [ "Dummy:"
  , "    Type: \"AWS::CloudFormation::WaitConditionHandle\""
  , "    Properties: {}"
  ]

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

writeIfAbsent :: FilePath -> String -> Bool -> IO ()
writeIfAbsent filename content force = do
  exists <- doesFileExist filename
  if exists && not force
    then hPutStrLn stderr $ filename <> " already exists! See help [-h] for overwrite options"
    else do
      writeFile filename content
      hPutStrLn stderr $ filename <> " has been created!"
