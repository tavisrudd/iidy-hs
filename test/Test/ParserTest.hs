module Test.ParserTest (parserTests) where

import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Yaml.Ast (SrcMeta (..), YamlAst (..), astMeta)
import Iidy.Yaml.Location (Position (..))
import Iidy.Yaml.Parser (parseYaml)

-- | Helper to parse YAML and extract SrcMeta from the result
parseGetMeta :: Text -> IO SrcMeta
parseGetMeta input = astMeta <$> parseAst input

-- | Helper to parse YAML and return the AST node
parseAst :: Text -> IO YamlAst
parseAst input = case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
    Left e -> assertFailure ("parse failed: " <> show e)
    Right n -> pure n

parserTests :: [TestTree]
parserTests = basicTests ++ [testGroup "source span info" spanTests]

basicTests :: [TestTree]
basicTests =
    [ testCase "parse null" $ do
        let input = "null\n"
        case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
            Left e -> assertFailure ("parse failed: " <> show e)
            Right _ -> pure ()
    , testCase "parse simple mapping" $ do
        let input = "key: value\n"
        case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
            Left e -> assertFailure ("parse failed: " <> show e)
            Right _ -> pure ()
    , testCase "parse sequence" $ do
        let input = "- a\n- b\n- c\n"
        case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
            Left e -> assertFailure ("parse failed: " <> show e)
            Right _ -> pure ()
    , testCase "parse boolean true" $ do
        let input = "true\n"
        case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
            Left e -> assertFailure ("parse failed: " <> show e)
            Right _ -> pure ()
    , testCase "parse integer" $ do
        let input = "42\n"
        case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
            Left e -> assertFailure ("parse failed: " <> show e)
            Right _ -> pure ()
    , testCase "parse float" $ do
        let input = "3.14\n"
        case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
            Left e -> assertFailure ("parse failed: " <> show e)
            Right _ -> pure ()
    , testCase "parse nested mapping" $ do
        let input = "outer:\n  inner: value\n"
        case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
            Left e -> assertFailure ("parse failed: " <> show e)
            Right _ -> pure ()
    , testCase "detect templated string" $ do
        let input = "key: '{{foo}}'\n"
        case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
            Left e -> assertFailure ("parse failed: " <> show e)
            Right _ -> pure ()
    , testCase "detect preprocessing tag" $ do
        let input = "key: !$ myvar\n"
        case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
            Left e -> assertFailure ("parse failed: " <> show e)
            Right _ -> pure ()
    , testCase "detect CloudFormation Ref tag" $ do
        let input = "key: !Ref Bucket\n"
        case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
            Left e -> assertFailure ("parse failed: " <> show e)
            Right _ -> pure ()
    , testCase "detect CloudFormation Sub tag" $ do
        let input = "key: !Sub '${AWS::Region}-bucket'\n"
        case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
            Left e -> assertFailure ("parse failed: " <> show e)
            Right _ -> pure ()
    , testCase "parse empty document" $ do
        let input = "~\n"
        case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
            Left e -> assertFailure ("parse failed: " <> show e)
            Right _ -> pure ()
    ]

------------------------------------------------------------------------
-- Source span tests
------------------------------------------------------------------------

spanTests :: [TestTree]
spanTests =
    [ testCase "scalar: plain string span width matches text length" $ do
        meta <- parseGetMeta "hello\n"
        let s = smStart meta
            e = smEnd meta
        -- End should be past start by length of "hello" (5 chars)
        let spanWidth = posColumn e - posColumn s
        spanWidth @?= T.length "hello"
        -- Offset span should match
        (posOffset e - posOffset s) @?= T.length "hello"
        -- Same line for single-line scalar
        posLine e @?= posLine s
    , testCase "scalar: integer span width matches text" $ do
        meta <- parseGetMeta "42\n"
        (posColumn (smEnd meta) - posColumn (smStart meta)) @?= T.length "42"
    , testCase "scalar: boolean span width matches text" $ do
        meta <- parseGetMeta "true\n"
        (posColumn (smEnd meta) - posColumn (smStart meta)) @?= T.length "true"
    , testCase "scalar: null span width matches text" $ do
        meta <- parseGetMeta "null\n"
        (posColumn (smEnd meta) - posColumn (smStart meta)) @?= T.length "null"
    , testCase "scalar: quoted string span width matches content" $ do
        -- HsYAML delivers the content without quotes as "hello world"
        meta <- parseGetMeta "'hello world'\n"
        (posColumn (smEnd meta) - posColumn (smStart meta)) @?= T.length "hello world"
    , testCase "mapping: end position extends past last value" $ do
        ast <- parseAst "key: value\n"
        case ast of
            AstMapping _ m -> do
                -- End should be at or past the end of "value"
                assertBool
                    "mapping smEnd offset should be past smStart"
                    (posOffset (smEnd m) > posOffset (smStart m))
            other -> assertFailure ("expected AstMapping, got: " <> show other)
    , testCase "mapping: multi-line end position on last value line" $ do
        ast <- parseAst "a: 1\nb: 2\n"
        case ast of
            AstMapping _ m -> do
                -- End should be on a later line than start
                assertBool
                    "mapping smEnd line should be past smStart line"
                    (posLine (smEnd m) > posLine (smStart m))
            other -> assertFailure ("expected AstMapping, got: " <> show other)
    , testCase "sequence: end position extends past last element" $ do
        ast <- parseAst "- a\n- b\n- c\n"
        case ast of
            AstSequence _ m -> do
                -- End should be past start
                assertBool
                    "sequence smEnd line should be past smStart line"
                    (posLine (smEnd m) > posLine (smStart m))
            other -> assertFailure ("expected AstSequence, got: " <> show other)
    , testCase "sequence: empty sequence has zero-width span" $ do
        ast <- parseAst "[]\n"
        case ast of
            AstSequence [] m ->
                -- Empty sequence: end == start (no children to derive from)
                smStart m @?= smEnd m
            other -> assertFailure ("expected empty AstSequence, got: " <> show other)
    , testCase "mapping: empty mapping has zero-width span" $ do
        ast <- parseAst "{}\n"
        case ast of
            AstMapping [] m ->
                -- Empty mapping: end == start (no children to derive from)
                smStart m @?= smEnd m
            other -> assertFailure ("expected empty AstMapping, got: " <> show other)
    , testCase "scalar: value in mapping has span width matching text" $ do
        ast <- parseAst "key: value\n"
        case ast of
            AstMapping [(_, v)] _ -> do
                let m = astMeta v
                (posColumn (smEnd m) - posColumn (smStart m)) @?= T.length "value"
            other -> assertFailure ("expected AstMapping with one pair, got: " <> show other)
    , testCase "tagged scalar: span includes tag and value" $ do
        -- "key: !Ref Bucket\n" -> tag "!Ref" + space + "Bucket"
        ast <- parseAst "key: !Ref Bucket\n"
        case ast of
            AstMapping [(_, taggedNode)] _ -> do
                let m = astMeta taggedNode
                    spanWidth = posColumn (smEnd m) - posColumn (smStart m)
                -- Span should include "!Ref " (5) + "Bucket" (6) = 11
                spanWidth @?= T.length "!Ref" + 1 + T.length "Bucket"
            other -> assertFailure ("expected AstMapping, got: " <> show other)
    , testCase "nested mapping: outer span extends to inner content" $ do
        ast <- parseAst "outer:\n  inner: value\n"
        case ast of
            AstMapping _ m -> do
                assertBool
                    "nested mapping smEnd should be past smStart"
                    (posOffset (smEnd m) > posOffset (smStart m))
            other -> assertFailure ("expected AstMapping, got: " <> show other)
    , testCase "mapping key also has non-zero span" $ do
        ast <- parseAst "key: value\n"
        case ast of
            AstMapping [(k, _)] _ -> do
                let m = astMeta k
                (posColumn (smEnd m) - posColumn (smStart m)) @?= T.length "key"
            other -> assertFailure ("expected AstMapping, got: " <> show other)
    ]
