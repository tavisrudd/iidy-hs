{- | YAML 1.1 compatibility booleans (C62): under 'Yaml11Bools' only a plain,
untagged yes\/no\/on\/off (or true\/false) value is a boolean. Quoted values
stay strings, mapping keys keep their text, and the same schema applies to
imported documents and @!$parseYaml@ strings.
-}
module Test.Yaml11BoolsTest (yaml11BoolsTests) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Yaml.Ast (YamlAst (..))
import Iidy.Yaml.Engine (LoadImportFn, PreprocessResult (..), preprocessYaml11)
import Iidy.Yaml.Imports.Types (ImportData (..), ImportError (..), ImportType (..))
import Iidy.Yaml.OValue (OValue (..), toValue)
import Iidy.Yaml.Parser (BoolSchema (..), parseYamlStrictAs)

yaml11BoolsTests :: [TestTree]
yaml11BoolsTests =
    [ testGroup "parser" parserTests
    , testGroup "preprocess" preprocessTests
    ]

parserTests :: [TestTree]
parserTests =
    [ testCase "plain yes/on and No/OFF are booleans under YAML 1.1" $ do
        mapM_ (\(t, b) -> scalarAs Yaml11Bools t >>= assertBoolNode t b) [("yes", True), ("On", True), ("No", False), ("OFF", False)]
    , testCase "quoted \"false\", \"yes\" and 'off' stay strings under YAML 1.1" $
        mapM_
            (\(src, t) -> scalarAs Yaml11Bools src >>= assertStringNode src t)
            [("\"false\"", "false"), ("\"yes\"", "yes"), ("'off'", "off")]
    , testCase "an explicit !!str yes stays a string under YAML 1.1" $
        scalarAs Yaml11Bools "!!str yes" >>= assertStringNode "!!str yes" "yes"
    , testCase "single-letter y/n are not booleans" $
        mapM_ (\t -> scalarAs Yaml11Bools t >>= assertStringNode t t) ["y", "n", "Y", "N"]
    , testCase "plain yes is a string under YAML 1.2" $
        scalarAs Yaml12Bools "yes" >>= assertStringNode "yes" "yes"
    , testCase "a mapping key keeps its text (on: stays the key on)" $
        case parse Yaml11Bools "on: off\n" of
            Right (AstMapping [(AstPlainString "on" _, AstBool False _)] _) -> pure ()
            other -> assertFailure ("unexpected: " <> show other)
    , testCase "an alias of a plain yes value is a boolean" $
        case parse Yaml11Bools "a: &x yes\nb: *x\n" of
            Right (AstMapping [_, (_, AstBool True _)] _) -> pure ()
            other -> assertFailure ("unexpected: " <> show other)
    ]
  where
    assertBoolNode src expected = \case
        AstBool b _ -> b @?= expected
        other -> assertFailure (show src <> ": expected a boolean, got " <> show other)

preprocessTests :: [TestTree]
preprocessTests =
    [ testCase "stack-args style Parameters keep quoted \"false\" and \"300\"" $ do
        v <- preprocess noImports "Parameters:\n  PublicFavicon: \"false\"\n  SessionTimeout: \"300\"\n  Enabled: yes\n"
        lookupPath ["Parameters", "PublicFavicon"] v @?= Just (String "false")
        lookupPath ["Parameters", "SessionTimeout"] v @?= Just (String "300")
        lookupPath ["Parameters", "Enabled"] v @?= Just (Bool True)
    , testCase "an imported document's plain yes is a boolean, its quoted \"no\" a string" $ do
        v <- preprocess (importLoader True) "$imports:\n  imp: vars.yaml\nplain: !$ imp.plain\nquoted: !$ imp.quoted\n"
        lookupPath ["plain"] v @?= Just (Bool True)
        lookupPath ["quoted"] v @?= Just (String "no")
    , testCase "an import not parsed from text (e.g. ssm-path) keeps its strings" $ do
        v <- preprocess (importLoader False) "$imports:\n  imp: vars.yaml\nplain: !$ imp.plain\n"
        lookupPath ["plain"] v @?= Just (String "yes")
    , testCase "!$parseYaml reads its string with the YAML 1.1 schema" $ do
        v <- preprocess noImports "parsed: !$parseYaml \"a: on\\nb: 'off'\\n\"\n"
        lookupPath ["parsed", "a"] v @?= Just (Bool True)
        lookupPath ["parsed", "b"] v @?= Just (String "off")
    ]
  where
    importRaw = "plain: yes\nquoted: \"no\"\n"
    -- The document as a loader's YAML 1.2 parse gives it; the flag says
    -- whether the loader parsed it from text (it then sets idOrdered).
    importLoader :: Bool -> LoadImportFn
    importLoader parsedFromText loc _base = case loc of
        "vars.yaml" ->
            pure . Right $
                ImportData
                    { idType = ImportFile
                    , idLocation = "vars.yaml"
                    , idRawData = importRaw
                    , idOrdered = if parsedFromText then Just (OObject []) else Nothing
                    , idDoc = Object (KM.fromList [("plain", String "yes"), ("quoted", String "no")])
                    }
        other -> pure (Left (ImportError ("unexpected import: " <> other)))

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

parse :: BoolSchema -> Text -> Either String YamlAst
parse schema src = either (Left . show) Right (parseYamlStrictAs schema (BL.fromStrict (TE.encodeUtf8 src)) "<test>")

scalarAs :: BoolSchema -> Text -> IO YamlAst
scalarAs schema src = either (assertFailure . ("parse failed: " <>)) pure (parse schema (src <> "\n"))

assertStringNode :: Text -> Text -> YamlAst -> Assertion
assertStringNode src expected = \case
    AstPlainString t _ -> t @?= expected
    other -> assertFailure (show src <> ": expected a string, got " <> show other)

noImports :: LoadImportFn
noImports loc _base = pure (Left (ImportError ("unexpected import: " <> loc)))

-- | Parse with the YAML 1.1 schema and preprocess in YAML 1.1 mode, as a caller does.
preprocess :: LoadImportFn -> Text -> IO Value
preprocess loader src = do
    ast <- either (assertFailure . ("parse failed: " <>)) pure (parse Yaml11Bools src)
    result <- preprocessYaml11 loader ast "test.yaml"
    case result of
        Left err -> assertFailure ("preprocess failed: " <> show err)
        Right pr -> pure (toValue (prValue pr))

lookupPath :: [Text] -> Value -> Maybe Value
lookupPath [] v = Just v
lookupPath (k : ks) (Object o) = KM.lookup (Key.fromText k) o >>= lookupPath ks
lookupPath _ _ = Nothing
