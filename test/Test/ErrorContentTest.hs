-- | Content-based assertions for error fixture messages.
-- Unlike snapshot tests, these check key content (error code, key phrase)
-- rather than exact formatting, making them robust to formatting changes.
module Test.ErrorContentTest (errorContentTests) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Types (ColorChoice(..))
import Iidy.Yaml.Engine (preprocessYaml)
import Iidy.Yaml.Errors.Conversion
  ( formatPreprocessErrorEnhanced
  , formatParseErrorEnhanced
  )
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.Parser (parseYaml, ParseError(..))

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

fixtureDir :: FilePath
fixtureDir = "test-fixtures/example-templates/errors"

-- | Run the preprocessing pipeline on a fixture and return the error text,
-- or fail the test if no error is produced.
getErrorOutput :: FilePath -> IO T.Text
getErrorOutput fname = do
  let inPath = fixtureDir <> "/" <> fname
  rawInput <- BL.readFile inPath
  let source = TE.decodeUtf8 (BL.toStrict rawInput)
      filePath = T.pack inPath
  case parseYaml rawInput filePath of
    Left pe ->
      formatParseErrorEnhanced ColorNever filePath source (pePosition pe) (peMessage pe)
    Right ast -> do
      result <- preprocessYaml loadFileImport ast filePath
      case result of
        Left err ->
          formatPreprocessErrorEnhanced ColorNever filePath source err
        Right _ ->
          assertFailure ("Expected error for " <> inPath <> " but got success")
            >> pure ""

-- | Assert that a text contains all listed substrings.
assertContainsAll :: String -> T.Text -> [T.Text] -> Assertion
assertContainsAll label output expected =
  mapM_ (\s ->
    assertBool (label <> ": expected '" <> T.unpack s <> "' in output:\n" <> T.unpack output)
      (s `T.isInfixOf` output)
  ) expected

-- | Build one content test: processes fixture, checks error code + key phrases.
errorContentCase :: String -> FilePath -> T.Text -> [T.Text] -> TestTree
errorContentCase name fname errCode phrases =
  testCase name $ do
    output <- getErrorOutput fname
    assertContainsAll name output (errCode : phrases)

------------------------------------------------------------------------
-- Test groups by error category
------------------------------------------------------------------------

errorContentTests :: [TestTree]
errorContentTests =
  [ testGroup "Variable errors (ERR_2xxx)" variableTests
  , testGroup "Lookup/query errors (ERR_2006)" lookupTests
  , testGroup "Tag parsing errors (ERR_4xxx)" tagParsingTests
  , testGroup "Type mismatch errors (ERR_5001)" typeMismatchTests
  , testGroup "CloudFormation errors (ERR_7001)" cfnTests
  , testGroup "Syntax errors (ERR_1001)" syntaxTests
  , testGroup "Import/expand errors" importTests
  ]

variableTests :: [TestTree]
variableTests =
  [ errorContentCase
      "variable-not-found: ERR_2001 + variable name"
      "variable-not-found.yaml"
      "ERR_2001"
      ["not found", "app_name"]

  , errorContentCase
      "variable-include-not-found: ERR_2001 + variable path"
      "variable-include-not-found.yaml"
      "ERR_2001"
      ["not found", "config.storage"]
  ]

lookupTests :: [TestTree]
lookupTests =
  [ errorContentCase
      "query-missing-key: ERR_2006 + missing key"
      "query-missing-key.yaml"
      "ERR_2006"
      ["not found", "missing_key"]

  , errorContentCase
      "jmespath-invalid-syntax: ERR_2006 + JMESPath"
      "jmespath-invalid-syntax.yaml"
      "ERR_2006"
      ["JMESPath", "config"]
  ]

tagParsingTests :: [TestTree]
tagParsingTests =
  [ errorContentCase
      "unknown-tag-typo: ERR_4001 + tag name"
      "unknown-tag-typo.yaml"
      "ERR_4001"
      ["mapp", "not a valid iidy tag"]

  , errorContentCase
      "unknown-tag-typo-flow: ERR_4001 + tag name"
      "unknown-tag-typo-flow.yaml"
      "ERR_4001"
      ["joinn", "not a valid iidy tag"]

  , errorContentCase
      "tag-missing-required-field: ERR_4002 + field name"
      "tag-missing-required-field.yaml"
      "ERR_4002"
      ["template", "missing"]

  , errorContentCase
      "parsing-let-missing-in-field: ERR_4002 + in field"
      "parsing-let-missing-in-field.yaml"
      "ERR_4002"
      ["in"]

  , errorContentCase
      "maplisttohash-missing-field: ERR_4002"
      "maplisttohash-missing-field.yaml"
      "ERR_4002"
      ["missing"]

  , errorContentCase
      "tag-if-unknown-field: ERR_4005 + unexpected field"
      "tag-if-unknown-field.yaml"
      "ERR_4005"
      ["unexpected field", "default"]

  , errorContentCase
      "jmespath-query-and-jmespath-exclusive: ERR_4005 + mutually exclusive"
      "jmespath-query-and-jmespath-exclusive.yaml"
      "ERR_4005"
      ["mutually exclusive"]

  , errorContentCase
      "parsing-include-invalid-format: ERR_4005 + invalid format"
      "parsing-include-invalid-format.yaml"
      "ERR_4005"
      ["invalid format"]

  , errorContentCase
      "parsing-merge-not-sequence: ERR_4003 + must be"
      "parsing-merge-not-sequence.yaml"
      "ERR_4003"
      ["must be a sequence"]

  , errorContentCase
      "tag-map-uses-source: ERR_4002 + missing items"
      "tag-map-uses-source.yaml"
      "ERR_4002"
      ["items", "missing"]
  ]

typeMismatchTests :: [TestTree]
typeMismatchTests =
  [ errorContentCase
      "join-wrong-array-type: ERR_5001 + expected/found"
      "join-wrong-array-type.yaml"
      "ERR_5001"
      ["expected", "found"]

  , errorContentCase
      "split-wrong-string-type: ERR_5001 + type info"
      "split-wrong-string-type.yaml"
      "ERR_5001"
      ["expected", "found"]

  , errorContentCase
      "map-wrong-items-type: ERR_5001 + type mismatch"
      "map-wrong-items-type.yaml"
      "ERR_5001"
      ["expected", "found"]

  , errorContentCase
      "merge-source-wrong-type: ERR_5001 + type"
      "merge-source-wrong-type.yaml"
      "ERR_5001"
      ["expected", "found"]

  , errorContentCase
      "frompairs-wrong-source-type: ERR_5001 + expected/found"
      "frompairs-wrong-source-type.yaml"
      "ERR_5001"
      ["expected", "found"]

  , errorContentCase
      "join-wrong-delimiter-type: ERR_5001 + delimiter"
      "join-wrong-delimiter-type.yaml"
      "ERR_5001"
      ["expected", "found"]
  ]

cfnTests :: [TestTree]
cfnTests =
  [ errorContentCase
      "cloudformation-empty-arrays: ERR_7001 + CFN tag"
      "cloudformation-empty-arrays.yaml"
      "ERR_7001"
      ["CloudFormation"]

  , errorContentCase
      "cloudformation-null-value: ERR_7001 + null"
      "cloudformation-null-value.yaml"
      "ERR_7001"
      ["CloudFormation", "null"]

  , errorContentCase
      "cloudformation-wrong-element-count: ERR_7001 + element count"
      "cloudformation-wrong-element-count.yaml"
      "ERR_7001"
      ["CloudFormation"]
  ]

syntaxTests :: [TestTree]
syntaxTests =
  [ errorContentCase
      "yaml-syntax-malformed-mapping: ERR_1001 + syntax"
      "yaml-syntax-malformed-mapping.yaml"
      "ERR_1001"
      ["Syntax error"]

  , errorContentCase
      "yaml-syntax-unexpected-end: ERR_1001 + unexpected end"
      "yaml-syntax-unexpected-end.yaml"
      "ERR_1001"
      ["unexpected end"]
  ]

importTests :: [TestTree]
importTests =
  [ errorContentCase
      "expand-missing-template: ERR_1001 + template name"
      "expand-missing-template.yaml"
      "ERR_1001"
      ["NonExistentTemplate"]

  , errorContentCase
      "expand-parse-error: ERR_6001 + handlebars syntax"
      "expand-parse-error.yaml"
      "ERR_6001"
      ["Unclosed expression"]
  ]
