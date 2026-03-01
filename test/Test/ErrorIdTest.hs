module Test.ErrorIdTest (errorIdTests) where

import Data.Maybe (isJust)
import qualified Data.Text as T
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Yaml.Errors.Ids

-- | All ErrorId values (manually maintained — must match Ids.hs).
allErrorIds :: [ErrorId]
allErrorIds =
  [ InvalidYamlSyntax, YamlVersionMismatch, UnsupportedYamlFeature
  , MalformedYamlStructure, YamlMergeKeyUsage
  , VariableNotFound, VariableNameCollision, InvalidVariableName
  , CircularVariableReference, VariableOutOfScope, LookupQueryFailed
  , ImportFileNotFound, ImportUrlUnreachable, ImportAuthenticationFailure
  , ImportCircularDependency, ImportFormatNotSupported
  , EnvironmentVariableNotFound, GitCommandFailure, S3AccessDenied
  , SsmParameterNotFound, CloudFormationStackNotFound
  , UnknownPreprocessingTag, MissingRequiredTagField, InvalidTagFieldValue
  , IncompatibleTagCombination, TagSyntaxError
  , TypeMismatchInOperation, InvalidArrayOperation, InvalidObjectOperation
  , DivisionByZero, InvalidComparison, StringOperationOnNonString
  , HandlebarsSyntaxError, UnknownHandlebarsHelper
  , HandlebarsHelperArgumentError, TemplateCompilationFailure
  , TemplateExecutionError
  , InvalidCloudFormationIntrinsic, CloudFormationReferenceError
  , CloudFormationDependencyIssue, CloudFormationTemplateSizeLimit
  , InvalidCommandLineArgument, MissingRequiredConfiguration
  , ConfigurationFileNotFound, AwsCredentialsNotConfigured
  , UnsupportedFileFormat
  , InternalProcessingError, MemoryAllocationFailure
  , FileSystemPermissionDenied, NetworkConnectivityIssue
  , UnexpectedSystemError
  ]

errorIdTests :: [TestTree]
errorIdTests =
  [ testCase "round-trip: errorIdFromCode . errorIdCode == Just for all IDs" $
      mapM_ (\eid ->
        errorIdFromCode (errorIdCode eid) @?=
          Just eid
      ) allErrorIds

  , testCase "all codes are unique" $
      let codes = map errorIdCode allErrorIds
          uniqueCodes = length (foldr (\x acc -> if x `elem` acc then acc else x : acc) [] codes)
      in uniqueCodes @?= length codes

  , testCase "all codes are positive" $
      mapM_ (\eid ->
        assertBool ("code for " <> show eid <> " should be positive")
          (errorIdCode eid > 0)
      ) allErrorIds

  , testCase "errorIdFromCode returns Nothing for unknown codes" $ do
      errorIdFromCode 0 @?= Nothing
      errorIdFromCode 9999 @?= Nothing
      errorIdFromCode (-1) @?= Nothing

  , testCase "showErrorId format is ERR_NNNN" $
      mapM_ (\eid ->
        assertBool ("showErrorId " <> show eid <> " should start with ERR_")
          (T.isPrefixOf "ERR_" (showErrorId eid))
      ) allErrorIds

  , testCase "allErrorIds list is exhaustive (count matches)" $
      -- If a new ErrorId is added to Ids.hs but not here, codes in range
      -- 1001-9005 that round-trip successfully will exceed our count.
      let validCodes = filter (isJust . errorIdFromCode) [1..9999]
      in length validCodes @?= length allErrorIds
  ]
