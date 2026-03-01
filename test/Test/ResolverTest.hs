{-# LANGUAGE OverloadedStrings #-}

module Test.ResolverTest (resolverTests) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Yaml.Ast
import Iidy.Yaml.Location (zeroPosition)
import Iidy.Yaml.OValue
import Iidy.Yaml.Resolution.Context
import Iidy.Yaml.Resolution.Resolver (resolveAst, ResolveError(..))

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Shared zero-position source metadata for test ASTs.
m :: SrcMeta
m = SrcMeta "<test>" zeroPosition zeroPosition

-- | Build a context with the given variable bindings.
ctxWith :: [(Text, OValue)] -> TagContext
ctxWith vars = emptyContext { tcVariables = Map.fromList vars }

-- | Shorthand: plain string AST node.
str :: Text -> YamlAst
str s = AstPlainString s m

-- | Shorthand: number AST node (takes Integer, converts to Scientific).
num :: Integer -> YamlAst
num n = AstNumber (fromInteger n) m

-- | Shorthand: boolean AST node.
bool :: Bool -> YamlAst
bool b = AstBool b m

-- | Shorthand: null AST node.
astNull :: YamlAst
astNull = AstNull m

-- | Shorthand: sequence AST node.
seq_ :: [YamlAst] -> YamlAst
seq_ items = AstSequence items m

-- | Shorthand: mapping AST node.
map_ :: [(YamlAst, YamlAst)] -> YamlAst
map_ pairs = AstMapping pairs m

-- | Shorthand: preprocessing tag AST node.
ppTag :: PreprocessingTag -> YamlAst
ppTag tag = AstPreprocessingTag tag m

-- | Build a !$ variable lookup tag (no query, no jmespath).
varLookup :: Text -> YamlAst
varLookup path = ppTag (PpVarLookup (VarLookupTag path Nothing Nothing))

-- | Build a !$ variable lookup with dot query.
varLookupQ :: Text -> Text -> YamlAst
varLookupQ path q = ppTag (PpVarLookup (VarLookupTag path (Just q) Nothing))

-- | Build a !$ variable lookup with JMESPath expression.
varLookupJmes :: Text -> Text -> YamlAst
varLookupJmes path jmes = ppTag (PpVarLookup (VarLookupTag path Nothing (Just jmes)))

-- | Assert a resolve succeeds with the expected OValue.
assertResolves :: TagContext -> YamlAst -> OValue -> Assertion
assertResolves ctx ast expected =
  case resolveAst ctx ast of
    Right val -> val @?= expected
    Left (ResolveError _ msg _) -> assertFailure ("resolve failed: " <> T.unpack msg)

-- | Assert a resolve fails.
assertResolveFails :: TagContext -> YamlAst -> Assertion
assertResolveFails ctx ast =
  case resolveAst ctx ast of
    Left _  -> pure ()
    Right v -> assertFailure ("expected failure, got: " <> show v)

-- | Assert a resolve fails with the error message containing a substring.
assertResolveFailsWith :: TagContext -> YamlAst -> Text -> Assertion
assertResolveFailsWith ctx ast substr =
  case resolveAst ctx ast of
    Left (ResolveError _ msg _)
      | substr `T.isInfixOf` msg -> pure ()
      | otherwise -> assertFailure
          ("error message " <> show msg <> " does not contain " <> show substr)
    Right v -> assertFailure ("expected failure, got: " <> show v)

------------------------------------------------------------------------
-- Tests
------------------------------------------------------------------------

resolverTests :: [TestTree]
resolverTests =
  [ testGroup "VarLookup"       varLookupTests
  , testGroup "If"              ifTests
  , testGroup "Let"             letTests
  , testGroup "Map"             mapTests
  , testGroup "Join"            joinTests
  , testGroup "Split"           splitTests
  , testGroup "Merge"           mergeTests
  , testGroup "GroupBy"         groupByTests
  , testGroup "MapListToHash"   mapListToHashTests
  , testGroup "FromPairs"       fromPairsTests
  , testGroup "ExpandBrackets"  expandBracketsTests
  , testGroup "Concat"          concatTests
  , testGroup "ConcatMap"       concatMapTests
  , testGroup "MergeMap"        mergeMapTests
  , testGroup "Eq"              eqTests
  , testGroup "Not"             notTests
  , testGroup "Escape"          escapeTests
  , testGroup "ParseYaml"       parseYamlTests
  , testGroup "ParseJson"       parseJsonTests
  , testGroup "ToJsonString"    toJsonStringTests
  , testGroup "ToYamlString"    toYamlStringTests
  , testGroup "MapValues"       mapValuesTests
  , testGroup "TemplateString"  templateStringTests
  , testGroup "Expand"          expandTests
  , testGroup "CfnValidation"   cfnValidationTests
  ]

------------------------------------------------------------------------
-- 1. VarLookup tests
------------------------------------------------------------------------

varLookupTests :: [TestTree]
varLookupTests =
  [ testCase "simple variable lookup" $
      assertResolves
        (ctxWith [("env", OString "production")])
        (varLookup "env")
        (OString "production")

  , testCase "dot path lookup into nested object" $
      assertResolves
        (ctxWith [("config", OObject [("db", OObject [("host", OString "localhost")])])])
        (varLookup "config.db.host")
        (OString "localhost")

  , testCase "dot path lookup - missing key errors" $
      assertResolveFailsWith
        (ctxWith [("config", OObject [("db", OString "x")])])
        (varLookup "config.missing")
        "Variable not found"

  , testCase "missing root variable errors" $
      assertResolveFailsWith
        (ctxWith [])
        (varLookup "noSuchVar")
        "Variable not found"

  , testCase "array index in dot path" $
      assertResolves
        (ctxWith [("items", OArray [OString "a", OString "b", OString "c"])])
        (varLookup "items.1")
        (OString "b")

  , testCase "dot query - comma-separated key selection" $
      assertResolves
        (ctxWith [("obj", OObject [("a", ONumber 1), ("b", ONumber 2), ("c", ONumber 3)])])
        (varLookupQ "obj" "a, c")
        (OObject [("a", ONumber 1), ("c", ONumber 3)])

  , testCase "dot query - missing key in selection errors" $
      assertResolveFailsWith
        (ctxWith [("obj", OObject [("a", ONumber 1)])])
        (varLookupQ "obj" "a, missing")
        "property 'missing' not found"

  , testCase "jmespath query on array" $
      assertResolves
        (ctxWith [("items", OArray [ONumber 1, ONumber 2, ONumber 3])])
        (varLookupJmes "items" "[0]")
        (ONumber 1)
  ]

------------------------------------------------------------------------
-- 2. If tests
------------------------------------------------------------------------

ifTests :: [TestTree]
ifTests =
  [ testCase "truthy string selects then branch" $
      assertResolves
        emptyContext
        (ppTag (PpIf (IfTag (str "yes") (str "then") (Just (str "else")))))
        (OString "then")

  , testCase "empty string selects else branch" $
      assertResolves
        emptyContext
        (ppTag (PpIf (IfTag (str "") (str "then") (Just (str "else")))))
        (OString "else")

  , testCase "null selects else branch" $
      assertResolves
        emptyContext
        (ppTag (PpIf (IfTag astNull (str "then") (Just (str "else")))))
        (OString "else")

  , testCase "false selects else branch" $
      assertResolves
        emptyContext
        (ppTag (PpIf (IfTag (bool False) (str "then") (Just (str "else")))))
        (OString "else")

  , testCase "true selects then branch" $
      assertResolves
        emptyContext
        (ppTag (PpIf (IfTag (bool True) (str "then") (Just (str "else")))))
        (OString "then")

  , testCase "no else branch returns null when falsy" $
      assertResolves
        emptyContext
        (ppTag (PpIf (IfTag (bool False) (str "then") Nothing)))
        ONull

  , testCase "non-empty array is truthy" $
      assertResolves
        emptyContext
        (ppTag (PpIf (IfTag (seq_ [num 1]) (str "yes") (Just (str "no")))))
        (OString "yes")

  , testCase "empty array is falsy" $
      assertResolves
        emptyContext
        (ppTag (PpIf (IfTag (seq_ []) (str "yes") (Just (str "no")))))
        (OString "no")
  ]

------------------------------------------------------------------------
-- 3. Let tests
------------------------------------------------------------------------

letTests :: [TestTree]
letTests =
  [ testCase "simple binding" $
      assertResolves
        emptyContext
        (ppTag (PpLet (LetTag [("x", str "hello")] (varLookup "x"))))
        (OString "hello")

  , testCase "multiple bindings" $
      assertResolves
        emptyContext
        (ppTag (PpLet (LetTag
          [ ("a", num 1)
          , ("b", num 2)
          ]
          (seq_ [varLookup "a", varLookup "b"]))))
        (OArray [ONumber 1, ONumber 2])

  , testCase "later binding references earlier binding" $
      assertResolves
        emptyContext
        (ppTag (PpLet (LetTag
          [ ("x", str "hello")
          , ("y", varLookup "x")
          ]
          (varLookup "y"))))
        (OString "hello")

  , testCase "let binding shadows outer variable" $
      assertResolves
        (ctxWith [("x", OString "outer")])
        (ppTag (PpLet (LetTag [("x", str "inner")] (varLookup "x"))))
        (OString "inner")
  ]

------------------------------------------------------------------------
-- 4. Map tests
------------------------------------------------------------------------

mapTests :: [TestTree]
mapTests =
  [ testCase "map over sequence with default var" $
      assertResolves
        emptyContext
        (ppTag (PpMap (MapTag
          (seq_ [num 1, num 2, num 3])
          (varLookup "item")
          Nothing
          Nothing)))
        (OArray [ONumber 1, ONumber 2, ONumber 3])

  , testCase "map with custom var name" $
      assertResolves
        emptyContext
        (ppTag (PpMap (MapTag
          (seq_ [str "a", str "b"])
          (varLookup "x")
          (Just "x")
          Nothing)))
        (OArray [OString "a", OString "b"])

  , testCase "map with filter keeps matching items" $
      assertResolves
        emptyContext
        (ppTag (PpMap (MapTag
          (seq_ [str "keep", str "drop", str "keep"])
          (varLookup "item")
          Nothing
          (Just (ppTag (PpEq (EqTag (varLookup "item") (str "keep"))))))))
        (OArray [OString "keep", OString "keep"])

  , testCase "map over non-sequence errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpMap (MapTag (str "notArray") (varLookup "item") Nothing Nothing)))
        "expected sequence"
  ]

------------------------------------------------------------------------
-- 5. Join tests
------------------------------------------------------------------------

joinTests :: [TestTree]
joinTests =
  [ testCase "join strings with delimiter" $
      assertResolves
        emptyContext
        (ppTag (PpJoin (JoinTag (str ", ") (seq_ [str "a", str "b", str "c"]))))
        (OString "a, b, c")

  , testCase "join with empty delimiter" $
      assertResolves
        emptyContext
        (ppTag (PpJoin (JoinTag (str "") (seq_ [str "x", str "y"]))))
        (OString "xy")

  , testCase "join numbers coerces to text" $
      assertResolves
        emptyContext
        (ppTag (PpJoin (JoinTag (str "-") (seq_ [num 1, num 2, num 3]))))
        (OString "1-2-3")

  , testCase "join non-sequence errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpJoin (JoinTag (str ",") (str "notArray"))))
        "expected sequence"
  ]

------------------------------------------------------------------------
-- 6. Split tests
------------------------------------------------------------------------

splitTests :: [TestTree]
splitTests =
  [ testCase "split string by delimiter" $
      assertResolves
        emptyContext
        (ppTag (PpSplit (SplitTag (str ",") (str "a,b,c"))))
        (OArray [OString "a", OString "b", OString "c"])

  , testCase "split with no matches returns single-element array" $
      assertResolves
        emptyContext
        (ppTag (PpSplit (SplitTag (str "|") (str "no-pipe"))))
        (OArray [OString "no-pipe"])

  , testCase "split non-string value errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpSplit (SplitTag (str ",") (num 42))))
        "expected string"

  , testCase "split with non-string delimiter errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpSplit (SplitTag (num 1) (str "hello"))))
        "expected string"
  ]

------------------------------------------------------------------------
-- 7. Merge tests
------------------------------------------------------------------------

mergeTests :: [TestTree]
mergeTests =
  [ testCase "merge two disjoint objects" $
      assertResolves
        emptyContext
        (ppTag (PpMerge (MergeTag
          [ map_ [(str "a", num 1)]
          , map_ [(str "b", num 2)]
          ])))
        (OObject [("a", ONumber 1), ("b", ONumber 2)])

  , testCase "later object overrides earlier keys" $
      assertResolves
        emptyContext
        (ppTag (PpMerge (MergeTag
          [ map_ [(str "x", num 1), (str "y", num 2)]
          , map_ [(str "x", num 99)]
          ])))
        (OObject [("x", ONumber 99), ("y", ONumber 2)])

  , testCase "merge preserves key order from base" $
      assertResolves
        emptyContext
        (ppTag (PpMerge (MergeTag
          [ map_ [(str "b", num 1), (str "a", num 2)]
          , map_ [(str "c", num 3)]
          ])))
        (OObject [("b", ONumber 1), ("a", ONumber 2), ("c", ONumber 3)])

  , testCase "merge non-object errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpMerge (MergeTag [str "notObj"])))
        "expected object"
  ]

------------------------------------------------------------------------
-- 8. GroupBy tests
------------------------------------------------------------------------

groupByTests :: [TestTree]
groupByTests =
  [ testCase "group items by extracted key" $
      assertResolves
        emptyContext
        (ppTag (PpGroupBy (GroupByTag
          (seq_
            [ map_ [(str "type", str "fruit"), (str "name", str "apple")]
            , map_ [(str "type", str "veg"),   (str "name", str "carrot")]
            , map_ [(str "type", str "fruit"), (str "name", str "banana")]
            ])
          (varLookupQ "item" "type")
          Nothing
          Nothing
          )))
        (OObject
          [ ("fruit", OArray
              [ OObject [("type", OString "fruit"), ("name", OString "apple")]
              , OObject [("type", OString "fruit"), ("name", OString "banana")]
              ])
          , ("veg", OArray
              [ OObject [("type", OString "veg"), ("name", OString "carrot")]
              ])
          ])

  , testCase "groupBy non-sequence errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpGroupBy (GroupByTag (str "notArray") (str "k") Nothing Nothing)))
        "expected sequence"
  ]

------------------------------------------------------------------------
-- 9. MapListToHash tests
------------------------------------------------------------------------

mapListToHashTests :: [TestTree]
mapListToHashTests =
  [ testCase "from [key, value] pairs" $
      assertResolves
        emptyContext
        (ppTag (PpMapListToHash (MapListToHashTag
          (seq_
            [ seq_ [str "a", num 1]
            , seq_ [str "b", num 2]
            ])
          (varLookup "item")
          Nothing
          Nothing)))
        (OObject [("a", ONumber 1), ("b", ONumber 2)])

  , testCase "from {key, value} objects" $
      assertResolves
        emptyContext
        (ppTag (PpMapListToHash (MapListToHashTag
          (seq_
            [ map_ [(str "key", str "x"), (str "value", num 10)]
            , map_ [(str "key", str "y"), (str "value", num 20)]
            ])
          (varLookup "item")
          Nothing
          Nothing)))
        (OObject [("x", ONumber 10), ("y", ONumber 20)])

  , testCase "from single-key objects" $
      assertResolves
        emptyContext
        (ppTag (PpMapListToHash (MapListToHashTag
          (seq_
            [ map_ [(str "foo", num 1)]
            , map_ [(str "bar", num 2)]
            ])
          (varLookup "item")
          Nothing
          Nothing)))
        (OObject [("foo", ONumber 1), ("bar", ONumber 2)])

  , testCase "multi-key object without key/value fields errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpMapListToHash (MapListToHashTag
          (seq_ [map_ [(str "a", num 1), (str "b", num 2)]])
          (varLookup "item")
          Nothing
          Nothing)))
        "exactly one key"
  ]

------------------------------------------------------------------------
-- 10. FromPairs tests
------------------------------------------------------------------------

fromPairsTests :: [TestTree]
fromPairsTests =
  [ testCase "convert [[k,v]] to object" $
      assertResolves
        emptyContext
        (ppTag (PpFromPairs (FromPairsTag
          (seq_
            [ seq_ [str "name", str "Alice"]
            , seq_ [str "age", num 30]
            ]))))
        (OObject [("name", OString "Alice"), ("age", ONumber 30)])

  , testCase "non-pair element errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpFromPairs (FromPairsTag
          (seq_ [str "notAPair"]))))
        "expected sequence"

  , testCase "non-sequence source errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpFromPairs (FromPairsTag (str "notArray"))))
        "expected sequence"
  ]

------------------------------------------------------------------------
-- 11. ExpandBrackets tests (via varLookup with bracket paths)
------------------------------------------------------------------------

expandBracketsTests :: [TestTree]
expandBracketsTests =
  [ testCase "bracket notation expands variable to dot path" $
      assertResolves
        (ctxWith
          [ ("env", OString "prod")
          , ("config", OObject [("prod", OString "production-db")])
          ])
        (varLookup "config[env]")
        (OString "production-db")

  , testCase "nested bracket expansion" $
      assertResolves
        (ctxWith
          [ ("b", OString "x")
          , ("c", OString "y")
          , ("a", OObject [("x", OObject [("y", OString "found")])])
          ])
        (varLookup "a[b][c]")
        (OString "found")

  , testCase "bracket with numeric variable" $
      assertResolves
        (ctxWith
          [ ("idx", ONumber 1)
          , ("items", OArray [OString "zero", OString "one", OString "two"])
          ])
        (varLookup "items[idx]")
        (OString "one")

  , testCase "bracket depth limit prevents infinite recursion" $
      assertResolveFails
        (ctxWith [("x", OString "[x]")])
        (varLookup "a[x]")
  ]

------------------------------------------------------------------------
-- 12. Concat tests
------------------------------------------------------------------------

concatTests :: [TestTree]
concatTests =
  [ testCase "!$concat merges two arrays" $
      assertResolves
        emptyContext
        (ppTag (PpConcat (ConcatTag
          [ seq_ [num 1, num 2]
          , seq_ [num 3, num 4]
          ])))
        (OArray [ONumber 1, ONumber 2, ONumber 3, ONumber 4])

  , testCase "!$concat merges three arrays" $
      assertResolves
        emptyContext
        (ppTag (PpConcat (ConcatTag
          [ seq_ [str "a"]
          , seq_ [str "b"]
          , seq_ [str "c"]
          ])))
        (OArray [OString "a", OString "b", OString "c"])

  , testCase "!$concat with empty array yields empty" $
      assertResolves
        emptyContext
        (ppTag (PpConcat (ConcatTag [])))
        (OArray [])

  , testCase "!$concat non-array is wrapped as single element" $
      -- resolveConcat wraps non-array items rather than erroring
      assertResolves
        emptyContext
        (ppTag (PpConcat (ConcatTag
          [ str "x"
          , seq_ [str "y"]
          ])))
        (OArray [OString "x", OString "y"])
  ]

------------------------------------------------------------------------
-- 13. ConcatMap tests
------------------------------------------------------------------------

concatMapTests :: [TestTree]
concatMapTests =
  [ testCase "!$concatMap maps and flattens results" $
      assertResolves
        emptyContext
        (ppTag (PpConcatMap (ConcatMapTag
          (seq_ [num 1, num 2, num 3])
          (seq_ [varLookup "item", varLookup "item"])
          Nothing
          Nothing)))
        (OArray [ONumber 1, ONumber 1, ONumber 2, ONumber 2, ONumber 3, ONumber 3])

  , testCase "!$concatMap returns flat array when template returns non-array" $
      -- non-array items are wrapped as single-element arrays
      assertResolves
        emptyContext
        (ppTag (PpConcatMap (ConcatMapTag
          (seq_ [str "a", str "b"])
          (varLookup "item")
          Nothing
          Nothing)))
        (OArray [OString "a", OString "b"])

  , testCase "!$concatMap with filter excludes non-matching items" $
      assertResolves
        emptyContext
        (ppTag (PpConcatMap (ConcatMapTag
          (seq_ [num 1, num 2, num 3])
          (seq_ [varLookup "item"])
          Nothing
          (Just (ppTag (PpEq (EqTag (varLookup "item") (num 2))))))))
        (OArray [ONumber 2])

  , testCase "!$concatMap over non-sequence errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpConcatMap (ConcatMapTag
          (str "notArray")
          (varLookup "item")
          Nothing
          Nothing)))
        "expected sequence"
  ]

------------------------------------------------------------------------
-- 14. MergeMap tests
------------------------------------------------------------------------

mergeMapTests :: [TestTree]
mergeMapTests =
  [ testCase "!$mergeMap maps and merges objects" $
      assertResolves
        emptyContext
        (ppTag (PpMergeMap (MergeMapTag
          (seq_
            [ map_ [(str "k", str "a")]
            , map_ [(str "k", str "b")]
            ])
          (varLookup "item")
          Nothing)))
        (OObject [("k", OString "b")])

  , testCase "!$mergeMap merges disjoint keys" $
      assertResolves
        emptyContext
        (ppTag (PpMergeMap (MergeMapTag
          (seq_
            [ map_ [(str "x", num 1)]
            , map_ [(str "y", num 2)]
            ])
          (varLookup "item")
          Nothing)))
        (OObject [("x", ONumber 1), ("y", ONumber 2)])

  , testCase "!$mergeMap over non-sequence errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpMergeMap (MergeMapTag
          (str "notArray")
          (varLookup "item")
          Nothing)))
        "expected sequence"

  , testCase "!$mergeMap template returning non-object errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpMergeMap (MergeMapTag
          (seq_ [num 1])
          (varLookup "item")
          Nothing)))
        "expected object"
  ]

------------------------------------------------------------------------
-- 15. Eq tests
------------------------------------------------------------------------

eqTests :: [TestTree]
eqTests =
  [ testCase "!$eq equal strings returns true" $
      assertResolves
        emptyContext
        (ppTag (PpEq (EqTag (str "hello") (str "hello"))))
        (OBool True)

  , testCase "!$eq unequal strings returns false" $
      assertResolves
        emptyContext
        (ppTag (PpEq (EqTag (str "hello") (str "world"))))
        (OBool False)

  , testCase "!$eq equal numbers returns true" $
      assertResolves
        emptyContext
        (ppTag (PpEq (EqTag (num 42) (num 42))))
        (OBool True)

  , testCase "!$eq string and number returns false" $
      assertResolves
        emptyContext
        (ppTag (PpEq (EqTag (str "1") (num 1))))
        (OBool False)

  , testCase "!$eq null equals null" $
      assertResolves
        emptyContext
        (ppTag (PpEq (EqTag astNull astNull)))
        (OBool True)

  , testCase "!$eq with variable lookup" $
      assertResolves
        (ctxWith [("x", OString "foo")])
        (ppTag (PpEq (EqTag (varLookup "x") (str "foo"))))
        (OBool True)
  ]

------------------------------------------------------------------------
-- 16. Not tests
------------------------------------------------------------------------

notTests :: [TestTree]
notTests =
  [ testCase "!$not negates true to false" $
      assertResolves
        emptyContext
        (ppTag (PpNot (NotTag (bool True))))
        (OBool False)

  , testCase "!$not negates false to true" $
      assertResolves
        emptyContext
        (ppTag (PpNot (NotTag (bool False))))
        (OBool True)

  , testCase "!$not negates truthy string to false" $
      assertResolves
        emptyContext
        (ppTag (PpNot (NotTag (str "non-empty"))))
        (OBool False)

  , testCase "!$not negates empty string to true" $
      assertResolves
        emptyContext
        (ppTag (PpNot (NotTag (str ""))))
        (OBool True)

  , testCase "!$not negates null to true" $
      assertResolves
        emptyContext
        (ppTag (PpNot (NotTag astNull)))
        (OBool True)

  , testCase "!$not negates non-empty array to false" $
      assertResolves
        emptyContext
        (ppTag (PpNot (NotTag (seq_ [num 1]))))
        (OBool False)
  ]

------------------------------------------------------------------------
-- 17. Escape tests
------------------------------------------------------------------------

escapeTests :: [TestTree]
escapeTests =
  [ testCase "!$escape passes string through as-is" $
      assertResolves
        emptyContext
        (ppTag (PpEscape (EscapeTag (str "hello"))))
        (OString "hello")

  , testCase "!$escape passes number through as-is" $
      assertResolves
        emptyContext
        (ppTag (PpEscape (EscapeTag (num 42))))
        (ONumber 42)

  , testCase "!$escape passes null through as-is" $
      assertResolves
        emptyContext
        (ppTag (PpEscape (EscapeTag astNull)))
        ONull

  , testCase "!$escape does not resolve inner template string" $
      -- AstTemplatedString is passed raw, not interpolated
      assertResolves
        (ctxWith [("x", OString "world")])
        (ppTag (PpEscape (EscapeTag (AstTemplatedString "{{x}}" m))))
        (OString "{{x}}")

  , testCase "!$escape does not resolve inner var lookup" $
      -- preprocessing tags inside escape are serialised as the literal "!$escaped" string
      assertResolves
        (ctxWith [("env", OString "prod")])
        (ppTag (PpEscape (EscapeTag (varLookup "env"))))
        (OString "!$escaped")
  ]

------------------------------------------------------------------------
-- 18. ParseYaml tests
------------------------------------------------------------------------

parseYamlTests :: [TestTree]
parseYamlTests =
  [ testCase "!$parseYaml parses a scalar string" $
      assertResolves
        emptyContext
        (ppTag (PpParseYaml (ParseYamlTag (str "hello"))))
        (OString "hello")

  , testCase "!$parseYaml parses a mapping" $
      assertResolves
        emptyContext
        (ppTag (PpParseYaml (ParseYamlTag (str "key: value"))))
        (OObject [("key", OString "value")])

  , testCase "!$parseYaml parses a sequence" $
      assertResolves
        emptyContext
        (ppTag (PpParseYaml (ParseYamlTag (str "- a\n- b\n"))))
        (OArray [OString "a", OString "b"])

  , testCase "!$parseYaml parses a number" $
      assertResolves
        emptyContext
        (ppTag (PpParseYaml (ParseYamlTag (str "42"))))
        (ONumber 42)

  , testCase "!$parseYaml non-string input errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpParseYaml (ParseYamlTag (num 99))))
        "expected string"

  , testCase "!$parseYaml invalid YAML errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpParseYaml (ParseYamlTag (str "key: [unclosed"))))
        "!$parseYaml"
  ]

------------------------------------------------------------------------
-- 19. ParseJson tests
------------------------------------------------------------------------

parseJsonTests :: [TestTree]
parseJsonTests =
  [ testCase "!$parseJson parses a JSON object" $
      assertResolves
        emptyContext
        (ppTag (PpParseJson (ParseJsonTag (str "{\"a\":1}"))))
        (OObject [("a", ONumber 1)])

  , testCase "!$parseJson parses a JSON array" $
      assertResolves
        emptyContext
        (ppTag (PpParseJson (ParseJsonTag (str "[1,2,3]"))))
        (OArray [ONumber 1, ONumber 2, ONumber 3])

  , testCase "!$parseJson parses a JSON string" $
      assertResolves
        emptyContext
        (ppTag (PpParseJson (ParseJsonTag (str "\"hello\""))))
        (OString "hello")

  , testCase "!$parseJson parses null" $
      assertResolves
        emptyContext
        (ppTag (PpParseJson (ParseJsonTag (str "null"))))
        ONull

  , testCase "!$parseJson non-string input errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpParseJson (ParseJsonTag (num 42))))
        "expected string"

  , testCase "!$parseJson invalid JSON errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpParseJson (ParseJsonTag (str "{bad json"))))
        "!$parseJson"
  ]

------------------------------------------------------------------------
-- 20. ToJsonString tests
------------------------------------------------------------------------

toJsonStringTests :: [TestTree]
toJsonStringTests =
  [ testCase "!$toJsonString serialises object to JSON" $
      assertResolves
        emptyContext
        (ppTag (PpToJsonString (ToJsonStringTag
          (map_ [(str "x", num 1)]))))
        (OString "{\"x\":1}")

  , testCase "!$toJsonString serialises array to JSON" $
      assertResolves
        emptyContext
        (ppTag (PpToJsonString (ToJsonStringTag
          (seq_ [num 1, num 2]))))
        (OString "[1,2]")

  , testCase "!$toJsonString serialises string" $
      assertResolves
        emptyContext
        (ppTag (PpToJsonString (ToJsonStringTag (str "hello"))))
        (OString "\"hello\"")

  , testCase "!$toJsonString serialises null" $
      assertResolves
        emptyContext
        (ppTag (PpToJsonString (ToJsonStringTag astNull)))
        (OString "null")

  , testCase "!$toJsonString serialises boolean" $
      assertResolves
        emptyContext
        (ppTag (PpToJsonString (ToJsonStringTag (bool True))))
        (OString "true")
  ]

------------------------------------------------------------------------
-- 21. ToYamlString tests
------------------------------------------------------------------------

toYamlStringTests :: [TestTree]
toYamlStringTests =
  [ testCase "!$toYamlString serialises string" $
      assertResolves
        emptyContext
        (ppTag (PpToYamlString (ToYamlStringTag (str "hello"))))
        (OString "hello")

  , testCase "!$toYamlString serialises number" $
      assertResolves
        emptyContext
        (ppTag (PpToYamlString (ToYamlStringTag (num 42))))
        (OString "42")

  , testCase "!$toYamlString serialises boolean" $
      assertResolves
        emptyContext
        (ppTag (PpToYamlString (ToYamlStringTag (bool True))))
        (OString "true")

  , testCase "!$toYamlString produces non-empty output for object" $ do
      let result = resolveAst emptyContext
            (ppTag (PpToYamlString (ToYamlStringTag
              (map_ [(str "key", str "val")]))))
      case result of
        Left (ResolveError _ msg _) -> assertFailure ("resolve failed: " <> T.unpack msg)
        Right (OString s)           -> assertBool "YAML output should be non-empty" (not (T.null s))
        Right v                     -> assertFailure ("expected OString, got: " <> show v)

  , testCase "!$toYamlString produces non-empty output for sequence" $ do
      let result = resolveAst emptyContext
            (ppTag (PpToYamlString (ToYamlStringTag
              (seq_ [str "a", str "b"]))))
      case result of
        Left (ResolveError _ msg _) -> assertFailure ("resolve failed: " <> T.unpack msg)
        Right (OString s)           -> assertBool "YAML output should be non-empty" (not (T.null s))
        Right v                     -> assertFailure ("expected OString, got: " <> show v)
  ]

------------------------------------------------------------------------
-- 22. MapValues tests
------------------------------------------------------------------------

mapValuesTests :: [TestTree]
mapValuesTests =
  [ testCase "!$mapValues doubles all values" $
      assertResolves
        emptyContext
        (ppTag (PpMapValues (MapValuesTag
          (map_ [(str "a", num 1), (str "b", num 2)])
          (ppTag (PpEq (EqTag (varLookupQ "item" "value") (num 1))))
          Nothing)))
        (OObject [("a", OBool True), ("b", OBool False)])

  , testCase "!$mapValues with custom var name" $
      assertResolves
        emptyContext
        (ppTag (PpMapValues (MapValuesTag
          (map_ [(str "x", str "hello")])
          (varLookupQ "entry" "value")
          (Just "entry"))))
        (OObject [("x", OString "hello")])

  , testCase "!$mapValues preserves key order" $
      assertResolves
        emptyContext
        (ppTag (PpMapValues (MapValuesTag
          (map_ [(str "c", num 3), (str "a", num 1), (str "b", num 2)])
          (varLookupQ "item" "key")
          Nothing)))
        (OObject [("c", OString "c"), ("a", OString "a"), ("b", OString "b")])

  , testCase "!$mapValues over non-object errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpMapValues (MapValuesTag
          (str "notObject")
          (varLookup "item")
          Nothing)))
        "expected object"
  ]

------------------------------------------------------------------------
-- 23. TemplateString tests
------------------------------------------------------------------------

templateStringTests :: [TestTree]
templateStringTests =
  [ testCase "simple {{var}} interpolation" $
      assertResolves
        (ctxWith [("name", OString "World")])
        (AstTemplatedString "Hello, {{name}}!" m)
        (OString "Hello, World!")

  , testCase "multiple variables interpolated" $
      assertResolves
        (ctxWith [("first", OString "John"), ("last", OString "Doe")])
        (AstTemplatedString "{{first}} {{last}}" m)
        (OString "John Doe")

  , testCase "numeric variable interpolated as text" $
      assertResolves
        (ctxWith [("count", ONumber 42)])
        (AstTemplatedString "Count: {{count}}" m)
        (OString "Count: 42")

  , testCase "undefined variable in template fails" $
      assertResolveFailsWith
        emptyContext
        (AstTemplatedString "Hello, {{missing}}!" m)
        "Variable not found"

  , testCase "template with no variables passes through" $
      assertResolves
        emptyContext
        (AstTemplatedString "no variables here" m)
        (OString "no variables here")

  , testCase "nested object property in template" $
      assertResolves
        (ctxWith [("cfg", OObject [("env", OString "prod")])])
        (AstTemplatedString "env={{cfg.env}}" m)
        (OString "env=prod")
  ]

------------------------------------------------------------------------
-- 24. Expand tests
------------------------------------------------------------------------

-- | A minimal TemplateInfo for testing !$expand.
mkTemplateInfo :: Text -> [ParamDef] -> TemplateInfo
mkTemplateInfo body params = TemplateInfo
  { tiParams   = params
  , tiRawBody  = body
  , tiLocation = "<test-template>"
  }

-- | A ParamDef with a default value and no constraints.
simpleParamDef :: Text -> OValue -> ParamDef
simpleParamDef name def = ParamDef
  { pdName           = name
  , pdDefault        = Just def
  , pdType           = Nothing
  , pdAllowedValues  = Nothing
  , pdAllowedPattern = Nothing
  , pdSchema         = Nothing
  , pdIsGlobal       = False
  }

-- | Context that includes a named template definition.
ctxWithTemplate :: Text -> TemplateInfo -> TagContext
ctxWithTemplate name tmpl = emptyContext
  { tcCustomTemplateDefs = Map.singleton name tmpl }

expandTests :: [TestTree]
expandTests =
  [ testCase "!$expand resolves template with provided params" $
      -- Template body is plain YAML scalar; params become context variables
      let tmpl = mkTemplateInfo "hello" []
          ctx  = ctxWithTemplate "myTmpl" tmpl
      in assertResolves
           ctx
           (ppTag (PpExpand (ExpandTag
             (str "myTmpl")
             (map_ []))))
           (OString "hello")

  , testCase "!$expand uses default param when not provided" $
      -- Template body references nothing; defaults are set in context
      let tmpl = mkTemplateInfo "default_output"
                   [simpleParamDef "color" (OString "blue")]
          ctx  = ctxWithTemplate "colorTmpl" tmpl
      in assertResolves
           ctx
           (ppTag (PpExpand (ExpandTag
             (str "colorTmpl")
             (map_ []))))
           (OString "default_output")

  , testCase "!$expand provided param overrides default" $
      -- Params are merged; template body is plain YAML
      let tmpl = mkTemplateInfo "result"
                   [simpleParamDef "color" (OString "blue")]
          ctx  = ctxWithTemplate "colorTmpl" tmpl
      in assertResolves
           ctx
           (ppTag (PpExpand (ExpandTag
             (str "colorTmpl")
             (map_ [(str "color", str "red")]))))
           (OString "result")

  , testCase "!$expand missing template name errors" $
      assertResolveFailsWith
        emptyContext
        (ppTag (PpExpand (ExpandTag
          (str "noSuchTemplate")
          (map_ []))))
        "not found"
  ]

------------------------------------------------------------------------
-- 25. CfnValidation tests
------------------------------------------------------------------------

-- | Wrap a CFN tag AST node and resolve it, for testing CFN validation.
cfnTag :: CloudFormationTag -> YamlAst
cfnTag tag = AstCloudFormationTag tag m

cfnValidationTests :: [TestTree]
cfnValidationTests =
  [ testGroup "Ref" refValidationTests
  , testGroup "Sub" subValidationTests
  , testGroup "GetAtt" getAttValidationTests
  , testGroup "Join" cfnJoinValidationTests
  , testGroup "Select" selectValidationTests
  , testGroup "Split" cfnSplitValidationTests
  , testGroup "FindInMap" findInMapValidationTests
  , testGroup "If" cfnIfValidationTests
  , testGroup "Equals" equalsValidationTests
  , testGroup "Not" cfnNotValidationTests
  ]

refValidationTests :: [TestTree]
refValidationTests =
  [ testCase "!Ref rejects null value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnRef astNull))
        "!Ref cannot have null value"

  , testCase "!Ref rejects empty string" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnRef (str "")))
        "!Ref cannot reference empty string"

  , testCase "!Ref rejects non-string (number)" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnRef (num 42)))
        "!Ref expects a string"

  , testCase "!Ref accepts valid logical resource name" $
      assertResolves
        emptyContext
        (cfnTag (CfnRef (str "MyBucket")))
        (OObject [("!Ref", OString "MyBucket")])
  ]

subValidationTests :: [TestTree]
subValidationTests =
  [ testCase "!Sub rejects null value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnSub astNull))
        "!Sub cannot have null value"

  , testCase "!Sub accepts plain string" $
      assertResolves
        emptyContext
        (cfnTag (CfnSub (str "arn:aws:s3:::${Bucket}")))
        (OObject [("!Sub", OString "arn:aws:s3:::${Bucket}")])

  , testCase "!Sub accepts [string, object] array form" $
      assertResolves
        emptyContext
        (cfnTag (CfnSub (seq_
          [ str "Hello ${Name}"
          , map_ [(str "Name", str "World")]
          ])))
        (OObject [("!Sub", OArray [OString "Hello ${Name}", OObject [("Name", OString "World")]])])

  , testCase "!Sub rejects wrong array length (4 elements)" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnSub (seq_ [str "a", str "b", str "c", str "d"])))
        "exactly 2 elements"

  , testCase "!Sub rejects [string, non-object] array" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnSub (seq_ [str "template", num 42])))
        "[string, object]"

  , testCase "!Sub rejects non-string-or-array value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnSub (num 1)))
        "!Sub expects a string or 2-element array"
  ]

getAttValidationTests :: [TestTree]
getAttValidationTests =
  [ testCase "!GetAtt rejects null value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnGetAtt astNull))
        "!GetAtt cannot have null value"

  , testCase "!GetAtt accepts dotted string" $
      assertResolves
        emptyContext
        (cfnTag (CfnGetAtt (str "MyBucket.Arn")))
        (OObject [("!GetAtt", OString "MyBucket.Arn")])

  , testCase "!GetAtt rejects non-dotted string" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnGetAtt (str "MyBucketArn")))
        "dot notation"

  , testCase "!GetAtt accepts [resource, attribute] array" $
      assertResolves
        emptyContext
        (cfnTag (CfnGetAtt (seq_ [str "MyBucket", str "Arn"])))
        (OObject [("!GetAtt", OArray [OString "MyBucket", OString "Arn"])])

  , testCase "!GetAtt rejects array with wrong element types" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnGetAtt (seq_ [str "MyBucket", num 1])))
        "[string, string]"

  , testCase "!GetAtt rejects non-string-or-array" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnGetAtt (bool True)))
        "!GetAtt expects a string or 2-element array"
  ]

cfnJoinValidationTests :: [TestTree]
cfnJoinValidationTests =
  [ testCase "!Join rejects null value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnJoin astNull))
        "!Join cannot have null value"

  , testCase "!Join accepts [delimiter, array]" $
      assertResolves
        emptyContext
        (cfnTag (CfnJoin (seq_ [str ",", seq_ [str "a", str "b"]])))
        (OObject [("!Join", OArray [OString ",", OArray [OString "a", OString "b"]])])

  , testCase "!Join rejects wrong element types" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnJoin (seq_ [num 1, seq_ [str "a"]])))
        "[string, array]"

  , testCase "!Join rejects non-array value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnJoin (str "notArray")))
        "!Join expects a 2-element array"
  ]

selectValidationTests :: [TestTree]
selectValidationTests =
  [ testCase "!Select rejects null value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnSelect astNull))
        "!Select cannot have null value"

  , testCase "!Select accepts [number, array]" $
      assertResolves
        emptyContext
        (cfnTag (CfnSelect (seq_ [num 0, seq_ [str "a", str "b"]])))
        (OObject [("!Select", OArray [ONumber 0, OArray [OString "a", OString "b"]])])

  , testCase "!Select rejects wrong index type" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnSelect (seq_ [str "notNum", seq_ [str "a"]])))
        "[number, array]"

  , testCase "!Select rejects non-array value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnSelect (str "notArray")))
        "!Select expects a 2-element array"
  ]

cfnSplitValidationTests :: [TestTree]
cfnSplitValidationTests =
  [ testCase "!Split rejects null value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnSplit astNull))
        "!Split cannot have null value"

  , testCase "!Split accepts [string, string]" $
      assertResolves
        emptyContext
        (cfnTag (CfnSplit (seq_ [str ",", str "a,b,c"])))
        (OObject [("!Split", OArray [OString ",", OString "a,b,c"])])

  , testCase "!Split rejects wrong element types" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnSplit (seq_ [num 1, str "a,b"])))
        "[string, string]"

  , testCase "!Split rejects non-array value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnSplit (num 42)))
        "!Split expects a 2-element array"
  ]

findInMapValidationTests :: [TestTree]
findInMapValidationTests =
  [ testCase "!FindInMap rejects null value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnFindInMap astNull))
        "!FindInMap cannot have null value"

  , testCase "!FindInMap accepts 3-element array" $
      assertResolves
        emptyContext
        (cfnTag (CfnFindInMap (seq_ [str "MapName", str "Key1", str "Key2"])))
        (OObject [("!FindInMap", OArray [OString "MapName", OString "Key1", OString "Key2"])])

  , testCase "!FindInMap rejects 2-element array" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnFindInMap (seq_ [str "MapName", str "Key1"])))
        "exactly 3 elements"

  , testCase "!FindInMap rejects non-array value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnFindInMap (str "notArray")))
        "!FindInMap expects a 3-element array"
  ]

cfnIfValidationTests :: [TestTree]
cfnIfValidationTests =
  [ testCase "!If rejects null value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnIf astNull))
        "!If cannot have null value"

  , testCase "!If accepts 3-element array" $
      assertResolves
        emptyContext
        (cfnTag (CfnIf (seq_ [str "CondName", str "trueVal", str "falseVal"])))
        (OObject [("!If", OArray [OString "CondName", OString "trueVal", OString "falseVal"])])

  , testCase "!If rejects 2-element array" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnIf (seq_ [str "Cond", str "val"])))
        "3-element array"

  , testCase "!If rejects non-array value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnIf (str "notArray")))
        "!If expects a 3-element array"
  ]

equalsValidationTests :: [TestTree]
equalsValidationTests =
  [ testCase "!Equals rejects null value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnEquals astNull))
        "!Equals cannot have null value"

  , testCase "!Equals accepts 2-element array" $
      assertResolves
        emptyContext
        (cfnTag (CfnEquals (seq_ [str "a", str "b"])))
        (OObject [("!Equals", OArray [OString "a", OString "b"])])

  , testCase "!Equals rejects 3-element array" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnEquals (seq_ [str "a", str "b", str "c"])))
        "2-element array"

  , testCase "!Equals rejects non-array value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnEquals (num 1)))
        "!Equals expects a 2-element array"
  ]

cfnNotValidationTests :: [TestTree]
cfnNotValidationTests =
  [ testCase "!Not rejects null value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnNot astNull))
        "!Not cannot have null value"

  , testCase "!Not accepts 1-element array" $
      -- Inner seq_ [x] gets unpacked to x by CFN single-element unpacking,
      -- so we need a 2-element wrapper: seq_ [seq_ [...]] resolves to
      -- OArray [OArray [...]], unpacked to OArray [...] which is 1-element
      assertResolves
        emptyContext
        (cfnTag (CfnNot (seq_ [seq_ [str "ConditionName"]])))
        (OObject [("!Not", OArray [OString "ConditionName"])])

  , testCase "!Not rejects 2-element array" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnNot (seq_ [str "Cond1", str "Cond2"])))
        "1-element array"

  , testCase "!Not rejects non-array value" $
      assertResolveFailsWith
        emptyContext
        (cfnTag (CfnNot (bool True)))
        "!Not expects a 1-element array"
  ]
