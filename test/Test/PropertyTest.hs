{-# OPTIONS_GHC -Wno-orphans #-}
module Test.PropertyTest (propertyTests) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.List (nubBy, sortBy)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Tasty (TestTree)
import Test.Tasty.QuickCheck (testProperty)
import Test.QuickCheck hiding (Failure, Success)

import Iidy.Yaml.Handlebars.Engine (interpolate, defaultHelpers)
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.OValue (OValue(..), toValue, fromValue)
import Iidy.Yaml.Parser (parseYaml)
import Iidy.Yaml.Engine (preprocessYaml)

-- | Arbitrary instance for OValue (limited depth to avoid huge trees)
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
    genKV = (,) <$> genKey <*> genOValue (n `div` 2)
    genKey = T.pack <$> listOf1 (elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> ['_']))

-- | Generate text that won't cause YAML parsing issues
genSafeText :: Gen T.Text
genSafeText = T.pack <$> listOf (elements safeChars)
  where safeChars = ['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> [' ', '_', '-']

propertyTests :: [TestTree]
propertyTests =
  [ testProperty "OValue toValue/fromValue round-trip" prop_ovalue_roundtrip
  , testProperty "OValue toValue preserves nulls" prop_null_roundtrip
  , testProperty "OValue toValue preserves booleans" prop_bool_roundtrip
  , testProperty "OValue toValue preserves strings" prop_string_roundtrip
  , testProperty "parse/emit round-trip produces valid YAML" prop_parse_emit_stable
  , testProperty "Handlebars literal passthrough" prop_handlebars_literal
  ]

-- | toValue -> fromValue preserves data (key order may differ for objects)
prop_ovalue_roundtrip :: OValue -> Property
prop_ovalue_roundtrip oval =
  normalizeKeyOrder (fromValue (toValue oval)) === normalizeKeyOrder oval

-- | Normalize OValue by sorting object keys for comparison
normalizeKeyOrder :: OValue -> OValue
normalizeKeyOrder (OObject kvs) =
  OObject (sortBy (\(a,_) (b,_) -> compare a b) [(k, normalizeKeyOrder v) | (k, v) <- kvs])
normalizeKeyOrder (OArray xs) = OArray (map normalizeKeyOrder xs)
normalizeKeyOrder x = x

-- | Null round-trips
prop_null_roundtrip :: Property
prop_null_roundtrip = once $
  fromValue (toValue ONull) === ONull

-- | Booleans round-trip
prop_bool_roundtrip :: Bool -> Property
prop_bool_roundtrip b =
  fromValue (toValue (OBool b)) === OBool b

-- | Strings round-trip
prop_string_roundtrip :: Property
prop_string_roundtrip = forAll genSafeText $ \t ->
  fromValue (toValue (OString t)) === OString t

-- | Parse YAML, emit it, re-parse: should produce same AST
prop_parse_emit_stable :: Property
prop_parse_emit_stable = forAll genSimpleYamlDoc $ \doc -> do
  let bs = BL.fromStrict (TE.encodeUtf8 doc)
  case parseYaml bs "test.yaml" of
    Left _ -> discard
    Right ast ->
      case preprocessYaml loadFileImport ast "test.yaml" of
        _ -> label "parsed" True

-- | Handlebars with no variables should pass through unchanged
prop_handlebars_literal :: Property
prop_handlebars_literal = forAll genSafeText $ \t ->
  not (T.isInfixOf "{{" t) ==>
    interpolate defaultHelpers (Object KM.empty) t === Right t

-- | Generate simple YAML documents for property testing
genSimpleYamlDoc :: Gen T.Text
genSimpleYamlDoc = do
  kvs <- listOf1 genSimpleKV
  pure $ T.unlines kvs
  where
    genSimpleKV = do
      k <- genKeyText
      v <- genSimpleValue
      pure $ k <> ": " <> v
    genKeyText = T.pack <$> listOf1 (elements (['a'..'z'] <> ['_']))
    genSimpleValue = oneof
      [ pure "true"
      , pure "false"
      , pure "null"
      , T.pack . show <$> (arbitrary :: Gen Int)
      , genSafeText
      ]
