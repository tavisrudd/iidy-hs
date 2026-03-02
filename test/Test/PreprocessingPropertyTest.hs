{-# LANGUAGE OverloadedStrings #-}

module Test.PreprocessingPropertyTest (preprocessingPropertyTests) where

import qualified Data.List as List
import Data.Text (Text)
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)
import Test.QuickCheck hiding (Failure, Success)

import Iidy.Yaml.Ast
import Iidy.Yaml.Location (zeroPosition)
import Iidy.Yaml.OValue
import Iidy.Yaml.Resolution.Context
import Iidy.Yaml.Resolution.Resolver (resolveAst)

------------------------------------------------------------------------
-- AST construction helpers
------------------------------------------------------------------------

-- | Shared zero-position source metadata for test ASTs.
m :: SrcMeta
m = SrcMeta "<test>" zeroPosition zeroPosition

-- | Shorthand: plain string AST node.
str :: Text -> YamlAst
str s = AstPlainString s m

-- | Shorthand: boolean AST node.
bool :: Bool -> YamlAst
bool b = AstBool b m

-- | Shorthand: null AST node.
astNull :: YamlAst
astNull = AstNull m

-- | Shorthand: sequence AST node.
seq_ :: [YamlAst] -> YamlAst
seq_ items = AstSequence items m

-- | Shorthand: preprocessing tag AST node.
ppTag :: PreprocessingTag -> YamlAst
ppTag tag = AstPreprocessingTag tag m

-- | Shorthand: CloudFormation tag AST node.
cfnTag :: CloudFormationTag -> YamlAst
cfnTag tag = AstCloudFormationTag tag m

-- | Lift an OValue into a plain YamlAst (scalars and simple structures).
-- Used to construct AST nodes from generated OValues.
oValueToAst :: OValue -> YamlAst
oValueToAst = \case
  ONull      -> astNull
  OBool b    -> bool b
  ONumber n  -> AstNumber n m
  OString s  -> str s
  OArray xs  -> seq_ (map oValueToAst xs)
  OObject kvs -> AstMapping [(str k, oValueToAst v) | (k, v) <- kvs] m

------------------------------------------------------------------------
-- Generators
------------------------------------------------------------------------

-- | Alphanumeric key text (safe for use as mapping keys).
genKeyText :: Gen Text
genKeyText = T.pack <$> listOf1 (elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> ['_']))

-- | Text safe from YAML parsing issues.
genSafeText :: Gen Text
genSafeText = T.pack <$> listOf (elements safeChars)
  where safeChars = ['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> [' ', '_', '-']

-- | Generate an OValue object (mapping) with unique keys.
genOObject :: Gen OValue
genOObject = do
  kvs <- resize 5 (listOf genKV)
  let deduped = List.nubBy (\(a,_) (b,_) -> a == b) kvs
  pure (OObject deduped)
  where
    genKV :: Gen (Text, OValue)
    genKV = (,) <$> genKeyText <*> genScalarOValue

-- | Generate a scalar OValue (no nesting).
genScalarOValue :: Gen OValue
genScalarOValue = oneof
  [ pure ONull
  , OBool <$> arbitrary
  , ONumber . fromIntegral <$> (arbitrary :: Gen Int)
  , OString <$> genSafeText
  ]

-- | Generate an OValue array of scalars.
genOArray :: Gen OValue
genOArray = OArray <$> resize 8 (listOf genScalarOValue)

------------------------------------------------------------------------
-- Property tests
------------------------------------------------------------------------

preprocessingPropertyTests :: [TestTree]
preprocessingPropertyTests =
  [ testGroup "Preprocessing tag semantic laws"
    [ testProperty "merge right-bias: last object wins on key conflict" prop_merge_right_bias
    , testProperty "merge identity: merge([a, {}]) == a" prop_merge_identity_right
    , testProperty "merge identity: merge([{}, a]) == a" prop_merge_identity_left
    , testProperty "map preserves length" prop_map_preserves_length
    , testProperty "concat associativity" prop_concat_associativity
    , testProperty "let scoping: inner binding shadows outer" prop_let_scoping
    , testProperty "if selects then-branch on truthy" prop_if_then_branch
    , testProperty "if selects else-branch on falsy" prop_if_else_branch
    , testProperty "resolution idempotency on scalars" prop_resolution_idempotent
    , testProperty "CFN Ref tag passes through unchanged" prop_cfn_ref_passthrough
    , testProperty "CFN Sub tag passes through unchanged" prop_cfn_sub_passthrough
    , testProperty "CFN GetAtt tag passes through unchanged" prop_cfn_getatt_passthrough
    ]
  ]

------------------------------------------------------------------------
-- 1. !$merge right-bias
------------------------------------------------------------------------

-- | For two objects where both have a key "k", the merged result has
-- b's value for "k".
prop_merge_right_bias :: Property
prop_merge_right_bias =
  forAll ((,,) <$> genKeyText <*> genScalarOValue <*> genScalarOValue) $
    \(key, valA, valB) ->
      let objA = OObject [(key, valA), ("onlyA", OString "a")]
          objB = OObject [(key, valB), ("onlyB", OString "b")]
          ast = ppTag (PpMerge (MergeTag [oValueToAst objA, oValueToAst objB]))
          result = resolveAst emptyContext ast
      in counterexample ("key=" <> T.unpack key
                         <> " valA=" <> show valA
                         <> " valB=" <> show valB
                         <> " result=" <> show result) $
         case result of
           Right (OObject kvs) ->
             conjoin
               [ counterexample "key should have b's value" $
                   lookupO key kvs === Just valB
               , counterexample "onlyA should be present" $
                   lookupO "onlyA" kvs === Just (OString "a")
               , counterexample "onlyB should be present" $
                   lookupO "onlyB" kvs === Just (OString "b")
               ]
           Right other ->
             counterexample ("Expected OObject, got: " <> show other) (property False)
           Left err ->
             counterexample ("Resolve failed: " <> show err) (property False)

------------------------------------------------------------------------
-- 2. !$merge identity
------------------------------------------------------------------------

-- | merge([a, {}]) == a (empty object on the right is identity)
prop_merge_identity_right :: Property
prop_merge_identity_right =
  forAll genOObject $ \obj ->
    let emptyObj = OObject []
        ast = ppTag (PpMerge (MergeTag [oValueToAst obj, oValueToAst emptyObj]))
        result = resolveAst emptyContext ast
    in counterexample ("obj=" <> show obj <> " result=" <> show result) $
       case result of
         Right resolved -> resolved === obj
         Left err -> counterexample ("Resolve failed: " <> show err) (property False)

-- | merge([{}, a]) == a (empty object on the left is identity)
prop_merge_identity_left :: Property
prop_merge_identity_left =
  forAll genOObject $ \obj ->
    let emptyObj = OObject []
        ast = ppTag (PpMerge (MergeTag [oValueToAst emptyObj, oValueToAst obj]))
        result = resolveAst emptyContext ast
    in counterexample ("obj=" <> show obj <> " result=" <> show result) $
       case result of
         Right resolved -> resolved === obj
         Left err -> counterexample ("Resolve failed: " <> show err) (property False)

------------------------------------------------------------------------
-- 3. !$map preserves length
------------------------------------------------------------------------

-- | Mapping an identity template over a list preserves its length.
prop_map_preserves_length :: Property
prop_map_preserves_length =
  forAll (resize 10 (listOf genScalarOValue)) $ \items ->
    let itemsAst = seq_ (map oValueToAst items)
        -- Template is just the variable reference: !$ item
        templateAst = ppTag (PpVarLookup (VarLookupTag "item" Nothing Nothing))
        mapAst = ppTag (PpMap (MapTag itemsAst templateAst Nothing Nothing))
        result = resolveAst emptyContext mapAst
    in counterexample ("items=" <> show items <> " result=" <> show result) $
       case result of
         Right (OArray resultItems) ->
           length resultItems === length items
         Right other ->
           counterexample ("Expected OArray, got: " <> show other) (property False)
         Left err ->
           counterexample ("Resolve failed: " <> show err) (property False)

------------------------------------------------------------------------
-- 4. !$concat associativity
------------------------------------------------------------------------

-- | concat([concat([a,b]),c]) produces same elements as concat([a, concat([b,c])])
prop_concat_associativity :: Property
prop_concat_associativity =
  forAll ((,,) <$> genOArray <*> genOArray <*> genOArray) $ \(a, b, c) ->
    let -- Left-associated: concat([concat([a,b]), c])
        innerLeft = ppTag (PpConcat (ConcatTag [oValueToAst a, oValueToAst b]))
        leftAssoc = ppTag (PpConcat (ConcatTag [innerLeft, oValueToAst c]))
        -- Right-associated: concat([a, concat([b,c])])
        innerRight = ppTag (PpConcat (ConcatTag [oValueToAst b, oValueToAst c]))
        rightAssoc = ppTag (PpConcat (ConcatTag [oValueToAst a, innerRight]))
        resultLeft = resolveAst emptyContext leftAssoc
        resultRight = resolveAst emptyContext rightAssoc
    in counterexample ("a=" <> show a <> " b=" <> show b <> " c=" <> show c
                        <> "\nleft=" <> show resultLeft
                        <> "\nright=" <> show resultRight) $
       case (resultLeft, resultRight) of
         (Right lv, Right rv) -> lv === rv
         _ -> counterexample "One or both resolves failed" (property False)

------------------------------------------------------------------------
-- 5. !$let scoping: inner bindings shadow outer
------------------------------------------------------------------------

-- | let x=v1 in (let x=v2 in !$ x) == v2
prop_let_scoping :: Property
prop_let_scoping =
  forAll ((,) <$> genScalarOValue <*> genScalarOValue) $ \(v1, v2) ->
    let -- Inner let: let x=v2 in !$ x
        innerLet = ppTag (PpLet (LetTag
          [("x", oValueToAst v2)]
          (ppTag (PpVarLookup (VarLookupTag "x" Nothing Nothing)))))
        -- Outer let: let x=v1 in <innerLet>
        outerLet = ppTag (PpLet (LetTag
          [("x", oValueToAst v1)]
          innerLet))
        result = resolveAst emptyContext outerLet
    in counterexample ("v1=" <> show v1 <> " v2=" <> show v2
                        <> " result=" <> show result) $
       result === Right v2

------------------------------------------------------------------------
-- 6. !$if branch selection
------------------------------------------------------------------------

-- | When condition is truthy, the then-branch value is returned.
prop_if_then_branch :: Property
prop_if_then_branch =
  forAll ((,) <$> genSafeText <*> genSafeText) $ \(thenText, elseText) ->
    -- Use OBool True as the condition (always truthy)
    let ifAst = ppTag (PpIf (IfTag
          (bool True)
          (str thenText)
          (Just (str elseText))))
        result = resolveAst emptyContext ifAst
    in result === Right (OString thenText)

-- | When condition is falsy, the else-branch value is returned.
prop_if_else_branch :: Property
prop_if_else_branch =
  forAll ((,) <$> genSafeText <*> genSafeText) $ \(thenText, elseText) ->
    -- Use OBool False as the condition (always falsy)
    let ifAst = ppTag (PpIf (IfTag
          (bool False)
          (str thenText)
          (Just (str elseText))))
        result = resolveAst emptyContext ifAst
    in result === Right (OString elseText)

------------------------------------------------------------------------
-- 7. Resolution idempotency on scalars
------------------------------------------------------------------------

-- | Resolving an already-resolved scalar value produces the same result.
-- A fully-resolved scalar (no tags, no templates) resolves identically
-- on a second pass.
prop_resolution_idempotent :: Property
prop_resolution_idempotent =
  forAll genScalarOValue $ \val ->
    let ast = oValueToAst val
        -- First resolution
        result1 = resolveAst emptyContext ast
        -- Second resolution: re-convert the result back to AST and resolve again
        result2 = case result1 of
          Right v -> resolveAst emptyContext (oValueToAst v)
          Left _  -> result1
    in counterexample ("val=" <> show val
                        <> " result1=" <> show result1
                        <> " result2=" <> show result2) $
       result1 === result2

------------------------------------------------------------------------
-- 8. CFN tag pass-through
------------------------------------------------------------------------

-- | !Ref passes through resolution unchanged: resolves to {"!Ref": <value>}
prop_cfn_ref_passthrough :: Property
prop_cfn_ref_passthrough =
  forAll genSafeText $ \refName ->
    not (T.null refName) ==>
      let ast = cfnTag (CfnRef (str refName))
          result = resolveAst emptyContext ast
      in result === Right (OObject [("!Ref", OString refName)])

-- | !Sub passes through resolution unchanged: resolves to {"!Sub": <value>}
prop_cfn_sub_passthrough :: Property
prop_cfn_sub_passthrough =
  forAll genSafeText $ \subExpr ->
    not (T.null subExpr) ==>
      let ast = cfnTag (CfnSub (str subExpr))
          result = resolveAst emptyContext ast
      in result === Right (OObject [("!Sub", OString subExpr)])

-- | !GetAtt with dot notation passes through unchanged.
prop_cfn_getatt_passthrough :: Property
prop_cfn_getatt_passthrough =
  forAll ((,) <$> genKeyText <*> genKeyText) $ \(resource, attribute) ->
    let dotNotation = resource <> "." <> attribute
        ast = cfnTag (CfnGetAtt (str dotNotation))
        result = resolveAst emptyContext ast
    in result === Right (OObject [("!GetAtt", OString dotNotation)])
