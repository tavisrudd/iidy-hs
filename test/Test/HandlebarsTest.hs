module Test.HandlebarsTest (handlebarsTests) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Yaml.Handlebars.Engine (
    HelperCall (..),
    InterpolateError (..),
    OutputSite (..),
    defaultHelpers,
    helperCallArgs,
    interpolate,
    interpolateChecked,
 )
import Iidy.Yaml.Handlebars.Helpers (fileHashHelpers)

handlebarsTests :: [TestTree]
handlebarsTests = basicTests <> outputCheckTests <> fileHashHelperTests

basicTests :: [TestTree]
basicTests =
    [ testCase "simple variable interpolation" $ do
        let ctx = Object (KM.fromList [("name", String "world")])
        interpolate defaultHelpers ctx "Hello, {{name}}!" @?= Right "Hello, world!"
    , testCase "no-op when no mustache" $ do
        let ctx = Object KM.empty
        interpolate defaultHelpers ctx "plain text" @?= Right "plain text"
    , testCase "nested path" $ do
        let inner = Object (KM.fromList [("b", String "nested")])
            ctx = Object (KM.fromList [("a", inner)])
        interpolate defaultHelpers ctx "{{a.b}}" @?= Right "nested"
    , testCase "if block true branch" $ do
        let ctx = Object (KM.fromList [("show", Bool True)])
        interpolate defaultHelpers ctx "{{#if show}}yes{{/if}}" @?= Right "yes"
    , testCase "if block false branch" $ do
        let ctx = Object (KM.fromList [("show", Bool False)])
        interpolate defaultHelpers ctx "{{#if show}}yes{{else}}no{{/if}}" @?= Right "no"
    , testCase "each block over array" $ do
        let ctx = Object (KM.fromList [("items", Array (V.fromList [Number 1, Number 2]))])
        interpolate defaultHelpers ctx "{{#each items}}{{@index}},{{/each}}" @?= Right "0,1,"
    , testCase "unless block" $ do
        let ctx = Object (KM.fromList [("flag", Bool False)])
        interpolate defaultHelpers ctx "{{#unless flag}}shown{{/unless}}" @?= Right "shown"
    , testCase "comment stripped" $ do
        let ctx = Object KM.empty
        interpolate defaultHelpers ctx "before{{! comment }}after" @?= Right "beforeafter"
    , testCase "number output" $ do
        let ctx = Object (KM.fromList [("n", Number 42)])
        interpolate defaultHelpers ctx "{{n}}" @?= Right "42"
    , testCase "toLowerCase helper" $ do
        let ctx = Object (KM.fromList [("s", String "HELLO")])
        interpolate defaultHelpers ctx "{{toLowerCase s}}" @?= Right "hello"
    , testCase "toUpperCase helper" $ do
        let ctx = Object (KM.fromList [("s", String "hello")])
        interpolate defaultHelpers ctx "{{toUpperCase s}}" @?= Right "HELLO"
    , testCase "string literal in helper" $ do
        let ctx = Object KM.empty
        interpolate defaultHelpers ctx "{{toLowerCase 'WORLD'}}" @?= Right "world"
    , testCase "missing variable renders empty" $ do
        let ctx = Object KM.empty
        interpolate defaultHelpers ctx "{{missing}}" @?= Right ""
    ]

{- | The output check sees every rendered @{{ ... }}@ value, with the
expression text and the context names it reads, inside block helpers too.
-}
outputCheckTests :: [TestTree]
outputCheckTests =
    [ testCase "the check sees each output with its site" $ do
        siteOf "a {{x}} b" @?= Left (InterpolateError "x [x] = X")
        siteOf "{{ toLowerCase p.q }}" @?= Left (InterpolateError "toLowerCase p.q [p] = deep")
        siteOf "{{concat 'k' (toUpperCase y.z) x}}" @?= Left (InterpolateError "concat \"k\" (toUpperCase y.z) x [y,x] = kZEDX")
        siteOf "{{concat 'k' 2 true}}" @?= Left (InterpolateError "concat \"k\" 2 true [] = k2true")
    , testCase "the check's refusal is the error" $
        interpolateChecked refuseBad defaultHelpers ctx "ok {{bad}}" @?= Left (InterpolateError "refused bad: bad")
    , testCase "literal text is not checked" $
        interpolateChecked refuseBad defaultHelpers ctx "bad {{x}} bad" @?= Right "bad X bad"
    , testCase "outputs inside if, unless, each and with are checked" $ do
        let refused t = interpolateChecked refuseBad defaultHelpers ctx t @?= Left (InterpolateError "refused bad: bad")
        refused "{{#if x}}{{bad}}{{/if}}"
        refused "{{#unless missing}}{{bad}}{{/unless}}"
        refused "{{#if missing}}no{{else}}{{bad}}{{/if}}"
        refused "{{#each items}}{{bad}}{{/each}}"
        refused "{{#with p}}{{bad}}{{/with}}"
    , testCase "interpolate does not check" $
        interpolate defaultHelpers ctx "{{bad}}" @?= Right "BAD"
    , testCase "helperCallArgs finds calls in outputs, sub-expressions and blocks" $
        helperCallArgs "filehash" "{{filehash 'a.zip'}} {{concat (filehash \"b\") x}} {{#if x}}{{filehash p.q}}{{/if}} {{filehash}}"
            @?= Right [HelperCall [Just "a.zip"] True, HelperCall [Just "b"] False, HelperCall [Nothing] True]
    , testCase "helperCallArgs marks a call in a block condition as not a whole output" $
        helperCallArgs "filehash" "{{#unless (eq (filehash 'f') '0')}}x{{/unless}}"
            @?= Right [HelperCall [Just "f"] False]
    , testCase "helperCallArgs passes on a parse error" $
        case helperCallArgs "filehash" "{{filehash 'a" of
            Left _ -> pure ()
            Right calls -> assertFailure ("expected a parse error, got " <> show calls)
    ]
  where
    ctx :: Value
    ctx =
        Object $
            KM.fromList
                [ ("x", String "X")
                , ("bad", String "BAD")
                , ("p", Object (KM.fromList [("q", String "DEEP"), ("bad", String "BAD")]))
                , ("y", Object (KM.fromList [("z", String "zed")]))
                , ("items", Array (V.fromList [String "fine", String "BAD"]))
                ]
    refuseBad :: OutputSite -> Text -> Either Text ()
    refuseBad _site t
        | t == "BAD" = Left "refused bad: bad"
        | otherwise = Right ()
    -- A check that refuses every output, showing what it was given.
    siteOf :: Text -> Either InterpolateError Text
    siteOf = interpolateChecked showSite defaultHelpers ctx
    showSite :: OutputSite -> Text -> Either Text ()
    showSite site v =
        Left (osExpression site <> " [" <> T.intercalate "," (osRoots site) <> "] = " <> v)

-- | The @filehash@ helpers answer from the precomputed table only.
fileHashHelperTests :: [TestTree]
fileHashHelperTests =
    [ testCase "filehash and filehashBase64 read the table" $ do
        let helpers = Map.union (fileHashHelpers table) defaultHelpers
        interpolate helpers (Object KM.empty) "{{filehash 'a.zip'}}/{{filehashBase64 'a.zip'}}" @?= Right "abc123/q83=="
    , testCase "a path missing from the table fails" $ do
        let helpers = Map.union (fileHashHelpers table) defaultHelpers
        case interpolate helpers (Object KM.empty) "{{filehash 'b.zip'}}" of
            Left (InterpolateError e) -> assertBool (T.unpack e) ("b.zip" `T.isInfixOf` e)
            Right t -> assertFailure ("expected a failure, got " <> T.unpack t)
    ]
  where
    table :: Text -> Text -> Maybe Text
    table helper path = case (helper, path) of
        ("filehash", "a.zip") -> Just "abc123"
        ("filehashBase64", "a.zip") -> Just "q83=="
        _other -> Nothing
