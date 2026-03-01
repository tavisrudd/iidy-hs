module Test.ErrorClassificationTest (errorClassificationTests) where

import Data.Text (Text)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Yaml.Errors.Conversion (classifyMessage)
import Iidy.Yaml.Errors.Enhanced
import Iidy.Yaml.Errors.Ids (ErrorId(..))
import Iidy.Yaml.Location (SourceLocation(..))

-- | Default source and location used by most tests.
-- classifyMessage uses source only for findTagOnSourceLine (must-be branches),
-- so empty source is fine for most classification branches.
defaultSource :: Text
defaultSource = ""

defaultLoc :: SourceLocation
defaultLoc = SourceLocation "test.yaml" 1 1 ""

-- | Helper: classify with default source/loc
classify :: Text -> EnhancedPreprocessingError
classify = classifyMessage defaultSource defaultLoc

-- | Assert the error is a TagParsingError with the given ErrorId
assertTagParsing :: ErrorId -> EnhancedPreprocessingError -> Assertion
assertTagParsing eid result = case result of
  TagParsingError info -> assertEqual "errorId" eid (tpiErrorId info)
  other -> assertFailure $ "expected TagParsingError, got: " <> show other

-- | Assert the error is a VariableNotFoundError
assertVarNotFound :: EnhancedPreprocessingError -> Assertion
assertVarNotFound result = case result of
  VariableNotFoundError{} -> pure ()
  other -> assertFailure $ "expected VariableNotFoundError, got: " <> show other

-- | Assert the error is a LookupQueryError
assertLookupQuery :: EnhancedPreprocessingError -> Assertion
assertLookupQuery result = case result of
  LookupQueryError{} -> pure ()
  other -> assertFailure $ "expected LookupQueryError, got: " <> show other

-- | Assert the error is a TypeMismatchError
assertTypeMismatch :: EnhancedPreprocessingError -> Assertion
assertTypeMismatch result = case result of
  TypeMismatchError{} -> pure ()
  other -> assertFailure $ "expected TypeMismatchError, got: " <> show other

-- | Assert the error is a CfnValidationError
assertCfnValidation :: EnhancedPreprocessingError -> Assertion
assertCfnValidation result = case result of
  CfnValidationError{} -> pure ()
  other -> assertFailure $ "expected CfnValidationError, got: " <> show other

-- | Assert the error is a YamlSyntaxError with the given ErrorId
assertYamlSyntax :: ErrorId -> EnhancedPreprocessingError -> Assertion
assertYamlSyntax eid result = case result of
  YamlSyntaxError info -> assertEqual "errorId" eid (ysiErrorId info)
  other -> assertFailure $ "expected YamlSyntaxError, got: " <> show other

errorClassificationTests :: [TestTree]
errorClassificationTests =
  -- Unknown preprocessing tag (ERR_4001)
  [ testCase "unknown tag: !$mapp" $ do
      let result = classify "'!$mapp' is not a valid iidy tag"
      assertTagParsing UnknownPreprocessingTag result
      case result of
        TagParsingError info -> do
          assertEqual "tag name extracted" "!$mapp" (tpiTagName info)
          assertEqual "span length" 6 (tpiSpanLen info)
        _ -> pure ()

  , testCase "unknown tag: !$foobarbaz" $ do
      let result = classify "'!$foobarbaz' is not a valid iidy tag"
      assertTagParsing UnknownPreprocessingTag result
      case result of
        TagParsingError info ->
          assertEqual "tag name extracted" "!$foobarbaz" (tpiTagName info)
        _ -> pure ()

  -- Unexpected field (ERR_4005)
  , testCase "unexpected field" $ do
      let result = classify "unexpected field 'foo'\n\nValid fields are: bar, baz"
      assertTagParsing TagSyntaxError result
      case result of
        TagParsingError info ->
          assertEqual "guidance present" (Just "check field spelling and tag documentation") (tpiGuidance info)
        _ -> pure ()

  -- Query/jmespath mutual exclusivity (ERR_4005)
  , testCase "query and jmespath mutually exclusive" $ do
      let result = classify "'query' and 'jmespath' are mutually exclusive"
      assertTagParsing TagSyntaxError result
      case result of
        TagParsingError info -> do
          assertEqual "tag name" "!$" (tpiTagName info)
          assertEqual "suggestion" (Just "!$ variable_name") (tpiSuggestion info)
        _ -> pure ()

  -- Variable not found (ERR_2001)
  , testCase "variable not found with available vars" $ do
      let result = classify "Variable not found: myVar. Available: x, y, z"
      assertVarNotFound result
      case result of
        VariableNotFoundError info -> do
          assertEqual "errorId" VariableNotFound (vnfErrorId info)
          assertEqual "variable name" "myVar" (vnfVariable info)
          assertEqual "available vars" ["x", "y", "z"] (vnfAvailableVars info)
        _ -> pure ()

  , testCase "variable not found without available vars" $ do
      let result = classify "Variable not found: lonely"
      assertVarNotFound result
      case result of
        VariableNotFoundError info -> do
          assertEqual "variable name" "lonely" (vnfVariable info)
          assertEqual "no available vars" [] (vnfAvailableVars info)
        _ -> pure ()

  -- Property not found in mapping (ERR_2006)
  , testCase "property not found in mapping" $ do
      let result = classify "property 'key' not found in mapping. Variable: config. Keys: a, b"
      assertLookupQuery result
      case result of
        LookupQueryError info -> do
          assertEqual "errorId" LookupQueryFailed (lqiErrorId info)
          assertEqual "variable path" "config" (lqiVariablePath info)
          assertEqual "message" "property 'key' not found in mapping" (lqiMessage info)
          assertEqual "available keys" ["a", "b"] (lqiAvailableKeys info)
        _ -> pure ()

  -- Type mismatch: expected X, found Y (ERR_5001)
  , testCase "type mismatch: expected sequence, found string" $ do
      let result = classify "expected sequence, found string"
      assertTypeMismatch result
      case result of
        TypeMismatchError info -> do
          assertEqual "errorId" TypeMismatchInOperation (tmiErrorId info)
          assertEqual "expected" "sequence" (tmiExpected info)
          assertEqual "found" "string" (tmiFound info)
        _ -> pure ()

  , testCase "type mismatch: expected object, found string with help" $ do
      let result = classify "expected object, found string"
      assertTypeMismatch result
      case result of
        TypeMismatchError info -> do
          assertEqual "expected" "object" (tmiExpected info)
          assertEqual "found" "string" (tmiFound info)
          assertEqual "help" (Just "try using !$parseJson or !$parseYaml to parse the string") (tmiHelp info)
        _ -> pure ()

  , testCase "type mismatch: expected string, found object with help" $ do
      let result = classify "expected string, found object"
      assertTypeMismatch result
      case result of
        TypeMismatchError info -> do
          assertEqual "help" (Just "try using !$toJsonString or !$toYamlString to serialize the object") (tmiHelp info)
        _ -> pure ()

  , testCase "type mismatch: strips context tags from found" $ do
      let result = classify "expected string, found sequence [delimiter]"
      assertTypeMismatch result
      case result of
        TypeMismatchError info -> do
          assertEqual "found stripped" "sequence" (tmiFound info)
          assertEqual "clean context" "expected string, found sequence" (tmiContext info)
        _ -> pure ()

  -- CFN validation (ERR_7001)
  , testCase "cfn validation: !Ref cannot have null value" $ do
      let result = classify "!Ref cannot have null value"
      assertCfnValidation result
      case result of
        CfnValidationError info -> do
          assertEqual "errorId" InvalidCloudFormationIntrinsic (cviErrorId info)
          assertEqual "tag name" "!Ref" (cviTagName info)
        _ -> pure ()

  , testCase "cfn validation: !Join requires array" $ do
      let result = classify "!Join requires [delimiter, array] with exactly 2 elements"
      assertCfnValidation result
      case result of
        CfnValidationError info ->
          assertEqual "tag name" "!Join" (cviTagName info)
        _ -> pure ()

  -- Missing required field (ERR_4002)
  , testCase "missing field: 'items' missing in !$map tag" $ do
      let result = classify "'items' missing in !$map tag"
      assertTagParsing MissingRequiredTagField result
      case result of
        TagParsingError info -> do
          assertEqual "tag name" "!$map" (tpiTagName info)
          assertEqual "guidance" (Just "add 'items' field to !$map tag") (tpiGuidance info)
        _ -> pure ()

  , testCase "missing field: 'template' missing in !$expand tag" $ do
      let result = classify "'template' missing in !$expand tag"
      assertTagParsing MissingRequiredTagField result
      case result of
        TagParsingError info ->
          assertEqual "tag name" "!$expand" (tpiTagName info)
        _ -> pure ()

  -- Missing required 'in' field for !$let (ERR_4002)
  , testCase "missing required 'in' field" $ do
      let result = classify "missing required 'in' field"
      assertTagParsing MissingRequiredTagField result
      case result of
        TagParsingError info -> do
          assertEqual "tag name" "!$let" (tpiTagName info)
          assertEqual "guidance" (Just "add 'in' field containing the expression to evaluate") (tpiGuidance info)
        _ -> pure ()

  -- Handlebars error (ERR_6001)
  , testCase "handlebars error" $ do
      let result = classify "Handlebars error: unterminated"
      assertYamlSyntax HandlebarsSyntaxError result
      case result of
        YamlSyntaxError info ->
          assertEqual "short message" "unterminated" (ysiShortMessage info)
        _ -> pure ()

  -- JMESPath error (ERR_2006)
  , testCase "jmespath error with variable" $ do
      let result = classify "Invalid JMESPath expression 'bad': parse error. Variable: data"
      assertLookupQuery result
      case result of
        LookupQueryError info -> do
          assertEqual "errorId" LookupQueryFailed (lqiErrorId info)
          assertEqual "variable path" "data" (lqiVariablePath info)
          assertEqual "display message strips variable suffix"
            "Invalid JMESPath expression 'bad': parse error" (lqiMessage info)
        _ -> pure ()

  , testCase "jmespath error without variable" $ do
      let result = classify "Invalid JMESPath expression 'x.y': unexpected token"
      assertLookupQuery result
      case result of
        LookupQueryError info -> do
          assertEqual "variable path empty" "" (lqiVariablePath info)
        _ -> pure ()

  -- invalid YAML structure (ERR_1001)
  , testCase "invalid YAML structure" $ do
      let result = classify "invalid YAML structure"
      assertYamlSyntax InvalidYamlSyntax result
      case result of
        YamlSyntaxError info -> do
          assertEqual "guidance" "tags cannot be chained - use list syntax" (ysiGuidance info)
          assertEqual "fix hint present" (Just "put the inner tag in a list to separate it from the outer tag") (ysiFixHint info)
        _ -> pure ()

  -- unexpected end of file (ERR_1001)
  , testCase "unexpected end of file" $ do
      let result = classify "unexpected end of file"
      assertYamlSyntax InvalidYamlSyntax result
      case result of
        YamlSyntaxError info ->
          assertEqual "guidance" "missing closing quote or bracket" (ysiGuidance info)
        _ -> pure ()

  -- Parse tag errors: !$parseYaml, !$parseJson, !$expand (ERR_1001)
  , testCase "parseYaml error" $ do
      assertYamlSyntax InvalidYamlSyntax (classify "!$parseYaml: invalid input")

  , testCase "parseJson error" $ do
      assertYamlSyntax InvalidYamlSyntax (classify "!$parseJson: bad json")

  , testCase "expand parse error" $ do
      assertYamlSyntax InvalidYamlSyntax (classify "!$expand parse error: something")

  -- must be a mapping (ERR_4003)
  , testCase "must be a mapping" $ do
      assertTagParsing InvalidTagFieldValue (classify "must be a mapping with required 'test' and 'then' fields")

  -- must be a sequence (ERR_4003)
  , testCase "must be a sequence" $ do
      assertTagParsing InvalidTagFieldValue (classify "must be a sequence with format [delimiter, array]")

  -- must have exactly (ERR_4003 for !$eq)
  , testCase "must have exactly 2 elements" $ do
      let result = classify "must have exactly 2 elements to compare"
      assertTagParsing InvalidTagFieldValue result
      case result of
        TagParsingError info ->
          assertEqual "tag name" "!$eq" (tpiTagName info)
        _ -> pure ()

  -- invalid format (ERR_4005)
  , testCase "invalid format" $ do
      let result = classify "invalid format - must be string variable name"
      assertTagParsing TagSyntaxError result
      case result of
        TagParsingError info -> do
          assertEqual "tag name" "!$" (tpiTagName info)
          assertEqual "suggestion" (Just "!$ variable_name") (tpiSuggestion info)
        _ -> pure ()

  -- Legacy type mismatch messages (ERR_5001)
  , testCase "legacy: !$map items must be" $ do
      assertTypeMismatch (classify "!$map items must be a sequence, found a string")

  , testCase "legacy: !$merge all sources" $ do
      assertTypeMismatch (classify "!$merge: all sources must be mappings")

  , testCase "legacy: !$split requires string" $ do
      assertTypeMismatch (classify "!$split requires string input")

  , testCase "legacy: !$join requires" $ do
      assertTypeMismatch (classify "!$join requires [string, sequence]")

  , testCase "legacy: !$fromPairs requires a sequence" $ do
      assertTypeMismatch (classify "!$fromPairs requires a sequence of pairs")

  -- Fallback / unknown messages
  , testCase "fallback: random message becomes TagSyntaxError" $ do
      let result = classify "some random error message"
      assertTagParsing TagSyntaxError result
      case result of
        TagParsingError info -> do
          assertEqual "tag name empty" "" (tpiTagName info)
          assertEqual "message preserved" "some random error message" (tpiMessage info)
          assertEqual "no guidance" Nothing (tpiGuidance info)
        _ -> pure ()

  -- Location is preserved
  , testCase "location is preserved in classified error" $ do
      let loc = SourceLocation "my-file.yaml" 42 7 "root.items"
          result = classifyMessage "" loc "some fallback error"
      case result of
        TagParsingError info ->
          assertEqual "location preserved" loc (tpiLocation info)
        _ -> assertFailure "expected TagParsingError"
  ]
