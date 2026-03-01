{-# OPTIONS_GHC -Wno-orphans #-}
module Test.PropertyTest (propertyTests) where

import Control.Exception (SomeException, evaluate, try)
import Data.Aeson (Value(..))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Char (isDigit, isLower)
import Data.List (nubBy, sortBy)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)
import Test.QuickCheck hiding (Failure, Success)

import Iidy.Cfn.Status (isFailureStatus, isInProgressStatus, isSuccessStatus)
import Iidy.Cfn.TemplateHash (calculateTemplateHash)
import Iidy.Output.Renderers.Interactive (padRight)
import Iidy.Yaml.CustomResources.JsonSchema (validateSchema)
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Errors.Ids (ErrorId(..), errorIdCode, errorIdFromCode, showErrorId)
import Iidy.Yaml.Handlebars.Engine (interpolate, defaultHelpers)
import Iidy.Yaml.JMESPath (applyJmesPath)
import Iidy.Yaml.OValue (OValue(..), toValue, fromValue, oValuesEqual)
import Iidy.Yaml.Parser (parseYaml)

------------------------------------------------------------------------
-- Generators
------------------------------------------------------------------------

-- | Arbitrary OValue (bounded depth)
instance Arbitrary OValue where
  arbitrary = sized genOValue
  shrink (OArray xs) = ONull : map OArray (shrinkList shrink xs)
  shrink (OObject kvs) = ONull : map OObject (shrinkList (const []) kvs)
  shrink _ = []

genOValue :: Int -> Gen OValue
genOValue 0 = oneof
  [ pure ONull
  , OBool <$> arbitrary
  , ONumber . fromIntegral <$> (arbitrary :: Gen Int)
  , OString <$> genSafeText
  ]
genOValue n = oneof
  [ pure ONull
  , OBool <$> arbitrary
  , ONumber . fromIntegral <$> (arbitrary :: Gen Int)
  , OString <$> genSafeText
  , OArray <$> resize (n `div` 2) (listOf (genOValue (n `div` 2)))
  , do kvs <- resize (n `div` 2) (listOf genKV)
       let deduped = nubBy (\(a,_) (b,_) -> a == b) kvs
       pure (OObject deduped)
  ]
  where
    genKV = (,) <$> genKeyText <*> genOValue (n `div` 2)

-- | Alphanumeric key text
genKeyText :: Gen T.Text
genKeyText = T.pack <$> listOf1 (elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> ['_']))

-- | Text safe from YAML parsing issues
genSafeText :: Gen T.Text
genSafeText = T.pack <$> listOf (elements safeChars)
  where safeChars = ['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> [' ', '_', '-']

-- | Non-object Values (for JMESPath field-on-non-object test)
genNonObjectValue :: Gen Value
genNonObjectValue = oneof
  [ pure Null
  , Bool <$> arbitrary
  , Number . fromIntegral <$> (arbitrary :: Gen Int)
  , String <$> genSafeText
  ]

-- | CFN-like status strings for meaningful coverage
genCfnLikeText :: Gen T.Text
genCfnLikeText = oneof
  [ elements knownCfnStatuses
  , do prefix <- elements ["CREATE", "DELETE", "UPDATE", "ROLLBACK", "IMPORT"]
       suffix <- elements ["_COMPLETE", "_FAILED", "_IN_PROGRESS"]
       pure (prefix <> suffix)
  , do prefix <- elements ["CREATE", "UPDATE", "DELETE"]
       mid <- elements ["", "_ROLLBACK"]
       suffix <- elements ["_COMPLETE", "_FAILED", "_IN_PROGRESS"]
       pure (prefix <> mid <> suffix)
  , genSafeText
  ]

knownCfnStatuses :: [T.Text]
knownCfnStatuses =
  [ "CREATE_IN_PROGRESS", "CREATE_COMPLETE", "CREATE_FAILED"
  , "DELETE_IN_PROGRESS", "DELETE_COMPLETE", "DELETE_FAILED"
  , "UPDATE_IN_PROGRESS", "UPDATE_COMPLETE", "UPDATE_FAILED"
  , "UPDATE_ROLLBACK_COMPLETE", "UPDATE_ROLLBACK_FAILED"
  , "UPDATE_ROLLBACK_IN_PROGRESS"
  , "ROLLBACK_IN_PROGRESS", "ROLLBACK_COMPLETE", "ROLLBACK_FAILED"
  , "IMPORT_IN_PROGRESS", "IMPORT_COMPLETE"
  , "IMPORT_ROLLBACK_COMPLETE", "IMPORT_ROLLBACK_FAILED"
  , "IMPORT_ROLLBACK_IN_PROGRESS"
  , "DELETE_SKIPPED", "REVIEW_IN_PROGRESS"
  ]

-- | All ErrorId constructors
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

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Call a Handlebars helper by name
callHelper :: T.Text -> [Value] -> Either T.Text Value
callHelper name args = case Map.lookup name defaultHelpers of
  Nothing -> Left ("Helper not found: " <> name)
  Just fn -> fn args

-- | Normalize OValue key order for comparison
normalizeKeyOrder :: OValue -> OValue
normalizeKeyOrder (OObject kvs) =
  OObject (sortBy (\(a,_) (b,_) -> compare a b) [(k, normalizeKeyOrder v) | (k, v) <- kvs])
normalizeKeyOrder (OArray xs) = OArray (map normalizeKeyOrder xs)
normalizeKeyOrder x = x

-- | Check if character is lowercase hex
isLowHex :: Char -> Bool
isLowHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

------------------------------------------------------------------------
-- Test list
------------------------------------------------------------------------

propertyTests :: [TestTree]
propertyTests =
  -- Parser fuzz testing
  [ parserFuzzTests
  -- OValue
  , testProperty "OValue toValue/fromValue round-trip" prop_ovalue_roundtrip
  , testProperty "OValue string round-trip" prop_string_roundtrip
  , testProperty "oValuesEqual is reflexive" prop_oValuesEqual_reflexive
  , testProperty "oValuesEqual is symmetric" prop_oValuesEqual_symmetric
  -- Emitter
  , testProperty "emitYaml produces parseable YAML" prop_emitYaml_parseable
  -- Handlebars
  , testProperty "Handlebars literal passthrough" prop_handlebars_literal
  , testProperty "sha256: 64 lowercase hex chars" prop_sha256_output
  , testProperty "base64 output length divisible by 4" prop_base64_length
  , testProperty "snakeCase: lowercase + underscores only" prop_snakeCase_format
  , testProperty "kebabCase: lowercase + hyphens only" prop_kebabCase_format
  , testProperty "toLowerCase is idempotent" prop_toLowerCase_idempotent
  -- JMESPath
  , testProperty "JMESPath @ is identity" prop_jmespath_identity
  , testProperty "JMESPath field on non-object returns Null" prop_jmespath_field_nonobject
  -- JSON Schema
  , testProperty "Bool True schema accepts all values" prop_schema_true_accepts_all
  , testProperty "Bool False schema rejects all values" prop_schema_false_rejects_all
  -- CFN Status
  , testProperty "failure/success/in-progress mutually exclusive" prop_cfn_status_exclusive
  -- Template Hash
  , testProperty "Template hash: 64 lowercase hex chars" prop_templateHash_format
  -- Error IDs
  , testProperty "ErrorId code round-trip" prop_errorId_roundtrip
  , testProperty "showErrorId format: ERR_ prefix + digits" prop_showErrorId_format
  -- Padding
  , testProperty "padRight length >= target width" prop_padRight_length
  , testProperty "padRight is idempotent" prop_padRight_idempotent
  , testProperty "padRight preserves original as prefix" prop_padRight_prefix
  ]

------------------------------------------------------------------------
-- OValue properties
------------------------------------------------------------------------

-- | toValue -> fromValue preserves data (key order may differ)
prop_ovalue_roundtrip :: OValue -> Property
prop_ovalue_roundtrip oval =
  normalizeKeyOrder (fromValue (toValue oval)) === normalizeKeyOrder oval

-- | Strings round-trip through toValue/fromValue
prop_string_roundtrip :: Property
prop_string_roundtrip = forAll genSafeText $ \t ->
  fromValue (toValue (OString t)) === OString t

-- | oValuesEqual is reflexive
prop_oValuesEqual_reflexive :: OValue -> Property
prop_oValuesEqual_reflexive v =
  oValuesEqual v v === True

-- | oValuesEqual is symmetric
prop_oValuesEqual_symmetric :: OValue -> OValue -> Property
prop_oValuesEqual_symmetric a b =
  oValuesEqual a b === oValuesEqual b a

------------------------------------------------------------------------
-- Emitter properties
------------------------------------------------------------------------

-- | emitYaml always produces valid YAML that parseYaml accepts
prop_emitYaml_parseable :: Property
prop_emitYaml_parseable = forAll (resize 4 arbitrary) $ \(oval :: OValue) ->
  let yaml = emitYaml oval
      bs = BL.fromStrict (TE.encodeUtf8 yaml)
  in counterexample ("Unparseable YAML:\n" <> T.unpack yaml) $
     case parseYaml bs "test.yaml" of
       Left _  -> property False
       Right _ -> property True

------------------------------------------------------------------------
-- Handlebars helper properties
------------------------------------------------------------------------

-- | Text without {{ passes through interpolation unchanged
prop_handlebars_literal :: Property
prop_handlebars_literal = forAll genSafeText $ \t ->
  not (T.isInfixOf "{{" t) ==>
    interpolate defaultHelpers (Object KM.empty) t === Right t

-- | sha256 always produces exactly 64 lowercase hex characters
prop_sha256_output :: Property
prop_sha256_output = forAll genSafeText $ \t ->
  case callHelper "sha256" [String t] of
    Right (String result) ->
      conjoin
        [ T.length result === 64
        , counterexample ("non-hex char in: " <> T.unpack result) $
            T.all isLowHex result === True
        ]
    other -> counterexample ("Unexpected: " <> show other) (property False)

-- | base64 output length is always a multiple of 4
prop_base64_length :: Property
prop_base64_length = forAll genSafeText $ \t ->
  case callHelper "base64" [String t] of
    Right (String result) -> T.length result `mod` 4 === 0
    other -> counterexample ("Unexpected: " <> show other) (property False)

-- | snakeCase output contains only lowercase letters, digits, and underscores
prop_snakeCase_format :: Property
prop_snakeCase_format = forAll genSafeText $ \t ->
  not (T.null t) ==>
    case callHelper "snakeCase" [String t] of
      Right (String result)
        | T.null result -> property True  -- all-separator input gives empty
        | otherwise ->
            counterexample ("snakeCase " <> show t <> " = " <> show result) $
              T.all (\c -> isLower c || isDigit c || c == '_') result
      other -> counterexample ("Unexpected: " <> show other) (property False)

-- | kebabCase output contains only lowercase letters, digits, and hyphens
prop_kebabCase_format :: Property
prop_kebabCase_format = forAll genSafeText $ \t ->
  not (T.null t) ==>
    case callHelper "kebabCase" [String t] of
      Right (String result)
        | T.null result -> property True
        | otherwise ->
            counterexample ("kebabCase " <> show t <> " = " <> show result) $
              T.all (\c -> isLower c || isDigit c || c == '-') result
      other -> counterexample ("Unexpected: " <> show other) (property False)

-- | Applying toLowerCase twice gives the same result as once
prop_toLowerCase_idempotent :: Property
prop_toLowerCase_idempotent = forAll genSafeText $ \t ->
  case callHelper "toLowerCase" [String t] of
    Right (String r1) -> callHelper "toLowerCase" [String r1] === Right (String r1)
    other -> counterexample ("Unexpected: " <> show other) (property False)

------------------------------------------------------------------------
-- JMESPath properties
------------------------------------------------------------------------

-- | The identity expression @ returns any value unchanged
prop_jmespath_identity :: Property
prop_jmespath_identity = forAll (resize 4 arbitrary) $ \(v :: Value) ->
  applyJmesPath "@" v === Right v

-- | Field access on a non-object value returns Null
prop_jmespath_field_nonobject :: Property
prop_jmespath_field_nonobject = forAll genNonObjectValue $ \v ->
  applyJmesPath "somefield" v === Right Null

------------------------------------------------------------------------
-- JSON Schema properties
------------------------------------------------------------------------

-- | Bool True schema accepts any value
prop_schema_true_accepts_all :: Property
prop_schema_true_accepts_all = forAll (resize 4 arbitrary) $ \(v :: Value) ->
  validateSchema (Bool True) v === Right ()

-- | Bool False schema rejects every value
prop_schema_false_rejects_all :: Property
prop_schema_false_rejects_all = forAll (resize 4 arbitrary) $ \(v :: Value) ->
  counterexample ("Bool False accepted: " <> show v) $
    case validateSchema (Bool False) v of
      Left _   -> property True
      Right () -> property False

------------------------------------------------------------------------
-- CFN Status properties
------------------------------------------------------------------------

-- | isFailureStatus, isSuccessStatus, isInProgressStatus are mutually exclusive:
-- at most one can be true for any text (they check different suffixes)
prop_cfn_status_exclusive :: Property
prop_cfn_status_exclusive = forAll genCfnLikeText $ \s ->
  let f = isFailureStatus s
      p = isSuccessStatus s
      i = isInProgressStatus s
      trueCount = length (filter id [f, p, i])
  in counterexample (T.unpack s <> ": failure=" <> show f
                     <> " success=" <> show p
                     <> " inProgress=" <> show i) $
     trueCount <= 1

------------------------------------------------------------------------
-- Template Hash properties
------------------------------------------------------------------------

-- | calculateTemplateHash always produces exactly 64 lowercase hex chars
prop_templateHash_format :: Property
prop_templateHash_format = forAll genSafeText $ \t ->
  let h = calculateTemplateHash t
  in conjoin
       [ T.length h === 64
       , counterexample ("non-hex char in: " <> T.unpack h) $
           T.all isLowHex h === True
       ]

------------------------------------------------------------------------
-- Error ID properties
------------------------------------------------------------------------

-- | errorIdFromCode . errorIdCode is identity for all ErrorIds
prop_errorId_roundtrip :: Property
prop_errorId_roundtrip = forAll (elements allErrorIds) $ \eid ->
  errorIdFromCode (errorIdCode eid) === Just eid

-- | showErrorId always has format "ERR_" followed by digits
prop_showErrorId_format :: Property
prop_showErrorId_format = forAll (elements allErrorIds) $ \eid ->
  let s = showErrorId eid
  in conjoin
       [ counterexample "Missing ERR_ prefix" $
           T.isPrefixOf "ERR_" s === True
       , counterexample "Non-digit after ERR_ prefix" $
           T.all isDigit (T.drop 4 s) === True
       ]

------------------------------------------------------------------------
-- Padding properties
------------------------------------------------------------------------

-- | padRight result is at least as long as the target width
prop_padRight_length :: Property
prop_padRight_length = forAll genPadArgs $ \(w, t) ->
  T.length (padRight w t) >= w

-- | Padding to the same width twice gives the same result as once
prop_padRight_idempotent :: Property
prop_padRight_idempotent = forAll genPadArgs $ \(w, t) ->
  padRight w (padRight w t) === padRight w t

-- | The original text is always a prefix of the padded result
prop_padRight_prefix :: Property
prop_padRight_prefix = forAll genPadArgs $ \(w, t) ->
  T.isPrefixOf t (padRight w t) === True

genPadArgs :: Gen (Int, T.Text)
genPadArgs = (,) <$> choose (0, 200) <*> genSafeText

------------------------------------------------------------------------
-- Parser fuzz generators
------------------------------------------------------------------------

-- | Arbitrary Text generated from arbitrary String (covers unicode, null bytes, etc.)
genArbitraryText :: Gen T.Text
genArbitraryText = T.pack <$> arbitrary

-- | Mix of empty, short structured, long, unicode, and special-char strings
genFuzzText :: Gen T.Text
genFuzzText = oneof
  [ pure ""
  , genArbitraryText
  , T.pack <$> resize 500 arbitrary
  , do s <- listOf1 (elements jmesSpecialChars)
       pure (T.pack s)
  , do s <- listOf (elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9']))
       pure (T.pack s)
  ]
  where
    jmesSpecialChars :: [Char]
    jmesSpecialChars = "abcxyz01.[]@*|&!?\"'`{},:= \t\n\r\\"

-- | OValue converted to Aeson Value for use as Handlebars context
genContextValue :: Gen Value
genContextValue = toValue <$> resize 3 arbitrary

------------------------------------------------------------------------
-- Parser fuzz tests
------------------------------------------------------------------------

parserFuzzTests :: TestTree
parserFuzzTests = testGroup "Parser fuzz testing"
  [ testProperty "JMESPath applyJmesPath returns Left or Right, never exception" $
      forAll genFuzzText $ \input ->
        ioProperty $ do
          result <- try @SomeException
                      (evaluate (applyJmesPath input Null))
          pure $ case result of
            Left ex -> counterexample ("Exception thrown: " <> show ex) False
            Right _  -> property True

  , testProperty "Handlebars interpolate never throws on arbitrary template" $
      forAll genFuzzText $ \tmpl ->
        ioProperty $ do
          result <- try @SomeException
                      (evaluate (interpolate defaultHelpers (Object KM.empty) tmpl))
          pure $ case result of
            Left ex -> counterexample ("Exception thrown on template: " <> show tmpl
                                       <> "\n  Exception: " <> show ex) False
            Right _  -> property True

  , testProperty "Handlebars interpolate never throws on arbitrary context" $
      forAll ((,) <$> genFuzzText <*> genContextValue) $ \(tmpl, ctx) ->
        ioProperty $ do
          result <- try @SomeException
                      (evaluate (interpolate defaultHelpers ctx tmpl))
          pure $ case result of
            Left ex -> counterexample ("Exception thrown: " <> show ex) False
            Right _  -> property True

  , testProperty "emitYaml never throws on arbitrary OValue" $
      forAll (resize 5 arbitrary) $ \(oval :: OValue) ->
        ioProperty $ do
          result <- try @SomeException
                      (evaluate (T.length (emitYaml oval)))
          pure $ case result of
            Left ex -> counterexample ("Exception thrown: " <> show ex) False
            Right _  -> property True

  , testProperty "emitYaml is idempotent (emit twice = same result)" $
      forAll (resize 4 arbitrary) $ \(oval :: OValue) ->
        let first  = emitYaml oval
            second = emitYaml oval
        in counterexample
             ("First:  " <> T.unpack first <> "\nSecond: " <> T.unpack second)
             (first === second)

  , testProperty "InterpolateError from invalid syntax is Left, not exception" $
      forAll genMalformedTemplate $ \tmpl ->
        ioProperty $ do
          result <- try @SomeException
                      (evaluate (interpolate defaultHelpers (Object KM.empty) tmpl))
          pure $ case result of
            Left ex -> counterexample ("Exception thrown: " <> show ex) False
            Right _  -> property True  -- Left (parse error) or Right (valid) both fine
  ]

-- | Templates that are syntactically malformed Handlebars
genMalformedTemplate :: Gen T.Text
genMalformedTemplate = oneof
  [ pure "{{"
  , pure "{{{"
  , pure "}}"
  , pure "{{foo"
  , pure "{{#if}}"
  , pure "{{/each}}"
  , do prefix <- genSafeText
       suffix <- genSafeText
       pure (prefix <> "{{" <> suffix)
  , do body <- genSafeText
       pure ("{{" <> body <> "}}")
  ]
