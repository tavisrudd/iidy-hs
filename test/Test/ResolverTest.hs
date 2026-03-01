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
  [ testGroup "VarLookup" varLookupTests
  , testGroup "If" ifTests
  , testGroup "Let" letTests
  , testGroup "Map" mapTests
  , testGroup "Join" joinTests
  , testGroup "Split" splitTests
  , testGroup "Merge" mergeTests
  , testGroup "GroupBy" groupByTests
  , testGroup "MapListToHash" mapListToHashTests
  , testGroup "FromPairs" fromPairsTests
  , testGroup "ExpandBrackets" expandBracketsTests
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
