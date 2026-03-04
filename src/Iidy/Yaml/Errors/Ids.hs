module Iidy.Yaml.Errors.Ids (
    ErrorId (..),
    errorIdCode,
    errorIdFromCode,
    showErrorId,
) where

import Data.Text (Text)
import Data.Text qualified as T

data ErrorId
    = -- 1xxx: YAML Syntax & Parsing
      InvalidYamlSyntax
    | YamlVersionMismatch
    | UnsupportedYamlFeature
    | MalformedYamlStructure
    | YamlMergeKeyUsage
    | -- 2xxx: Variable & Scope
      VariableNotFound
    | VariableNameCollision
    | InvalidVariableName
    | CircularVariableReference
    | VariableOutOfScope
    | LookupQueryFailed
    | -- 3xxx: Import & Loading
      ImportFileNotFound
    | ImportUrlUnreachable
    | ImportAuthenticationFailure
    | ImportCircularDependency
    | ImportFormatNotSupported
    | EnvironmentVariableNotFound
    | GitCommandFailure
    | S3AccessDenied
    | SsmParameterNotFound
    | CloudFormationStackNotFound
    | -- 4xxx: Tag Syntax & Structure
      UnknownPreprocessingTag
    | MissingRequiredTagField
    | InvalidTagFieldValue
    | IncompatibleTagCombination
    | TagSyntaxError
    | -- 5xxx: Type & Validation
      TypeMismatchInOperation
    | InvalidArrayOperation
    | InvalidObjectOperation
    | DivisionByZero
    | InvalidComparison
    | StringOperationOnNonString
    | -- 6xxx: Template & Handlebars
      HandlebarsSyntaxError
    | UnknownHandlebarsHelper
    | HandlebarsHelperArgumentError
    | TemplateCompilationFailure
    | TemplateExecutionError
    | -- 7xxx: CloudFormation Specific
      InvalidCloudFormationIntrinsic
    | CloudFormationReferenceError
    | CloudFormationDependencyIssue
    | CloudFormationTemplateSizeLimit
    | -- 8xxx: Configuration & Setup
      InvalidCommandLineArgument
    | MissingRequiredConfiguration
    | ConfigurationFileNotFound
    | AwsCredentialsNotConfigured
    | UnsupportedFileFormat
    | -- 9xxx: Internal & System
      InternalProcessingError
    | MemoryAllocationFailure
    | FileSystemPermissionDenied
    | NetworkConnectivityIssue
    | UnexpectedSystemError
    deriving stock (Show, Eq, Ord)

errorIdCode :: ErrorId -> Int
errorIdCode = \case
    InvalidYamlSyntax -> 1001
    YamlVersionMismatch -> 1002
    UnsupportedYamlFeature -> 1003
    MalformedYamlStructure -> 1004
    YamlMergeKeyUsage -> 1005
    VariableNotFound -> 2001
    VariableNameCollision -> 2002
    InvalidVariableName -> 2003
    CircularVariableReference -> 2004
    VariableOutOfScope -> 2005
    LookupQueryFailed -> 2006
    ImportFileNotFound -> 3001
    ImportUrlUnreachable -> 3002
    ImportAuthenticationFailure -> 3003
    ImportCircularDependency -> 3004
    ImportFormatNotSupported -> 3005
    EnvironmentVariableNotFound -> 3006
    GitCommandFailure -> 3007
    S3AccessDenied -> 3008
    SsmParameterNotFound -> 3009
    CloudFormationStackNotFound -> 3010
    UnknownPreprocessingTag -> 4001
    MissingRequiredTagField -> 4002
    InvalidTagFieldValue -> 4003
    IncompatibleTagCombination -> 4004
    TagSyntaxError -> 4005
    TypeMismatchInOperation -> 5001
    InvalidArrayOperation -> 5002
    InvalidObjectOperation -> 5003
    DivisionByZero -> 5004
    InvalidComparison -> 5005
    StringOperationOnNonString -> 5006
    HandlebarsSyntaxError -> 6001
    UnknownHandlebarsHelper -> 6002
    HandlebarsHelperArgumentError -> 6003
    TemplateCompilationFailure -> 6004
    TemplateExecutionError -> 6005
    InvalidCloudFormationIntrinsic -> 7001
    CloudFormationReferenceError -> 7002
    CloudFormationDependencyIssue -> 7003
    CloudFormationTemplateSizeLimit -> 7004
    InvalidCommandLineArgument -> 8001
    MissingRequiredConfiguration -> 8002
    ConfigurationFileNotFound -> 8003
    AwsCredentialsNotConfigured -> 8004
    UnsupportedFileFormat -> 8005
    InternalProcessingError -> 9001
    MemoryAllocationFailure -> 9002
    FileSystemPermissionDenied -> 9003
    NetworkConnectivityIssue -> 9004
    UnexpectedSystemError -> 9005

errorIdFromCode :: Int -> Maybe ErrorId
errorIdFromCode = \case
    1001 -> Just InvalidYamlSyntax
    1002 -> Just YamlVersionMismatch
    1003 -> Just UnsupportedYamlFeature
    1004 -> Just MalformedYamlStructure
    1005 -> Just YamlMergeKeyUsage
    2001 -> Just VariableNotFound
    2002 -> Just VariableNameCollision
    2003 -> Just InvalidVariableName
    2004 -> Just CircularVariableReference
    2005 -> Just VariableOutOfScope
    2006 -> Just LookupQueryFailed
    3001 -> Just ImportFileNotFound
    3002 -> Just ImportUrlUnreachable
    3003 -> Just ImportAuthenticationFailure
    3004 -> Just ImportCircularDependency
    3005 -> Just ImportFormatNotSupported
    3006 -> Just EnvironmentVariableNotFound
    3007 -> Just GitCommandFailure
    3008 -> Just S3AccessDenied
    3009 -> Just SsmParameterNotFound
    3010 -> Just CloudFormationStackNotFound
    4001 -> Just UnknownPreprocessingTag
    4002 -> Just MissingRequiredTagField
    4003 -> Just InvalidTagFieldValue
    4004 -> Just IncompatibleTagCombination
    4005 -> Just TagSyntaxError
    5001 -> Just TypeMismatchInOperation
    5002 -> Just InvalidArrayOperation
    5003 -> Just InvalidObjectOperation
    5004 -> Just DivisionByZero
    5005 -> Just InvalidComparison
    5006 -> Just StringOperationOnNonString
    6001 -> Just HandlebarsSyntaxError
    6002 -> Just UnknownHandlebarsHelper
    6003 -> Just HandlebarsHelperArgumentError
    6004 -> Just TemplateCompilationFailure
    6005 -> Just TemplateExecutionError
    7001 -> Just InvalidCloudFormationIntrinsic
    7002 -> Just CloudFormationReferenceError
    7003 -> Just CloudFormationDependencyIssue
    7004 -> Just CloudFormationTemplateSizeLimit
    8001 -> Just InvalidCommandLineArgument
    8002 -> Just MissingRequiredConfiguration
    8003 -> Just ConfigurationFileNotFound
    8004 -> Just AwsCredentialsNotConfigured
    8005 -> Just UnsupportedFileFormat
    9001 -> Just InternalProcessingError
    9002 -> Just MemoryAllocationFailure
    9003 -> Just FileSystemPermissionDenied
    9004 -> Just NetworkConnectivityIssue
    9005 -> Just UnexpectedSystemError
    _ -> Nothing

showErrorId :: ErrorId -> Text
showErrorId eid = "ERR_" <> T.pack (show (errorIdCode eid))
