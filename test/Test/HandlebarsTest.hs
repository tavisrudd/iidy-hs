module Test.HandlebarsTest (handlebarsTests) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Vector qualified as V
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Yaml.Handlebars.Engine (defaultHelpers, interpolate)

handlebarsTests :: [TestTree]
handlebarsTests =
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
