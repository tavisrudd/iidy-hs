module Test.SpecConformanceTest (specConformanceTests) where

import Data.Aeson (Value (..), (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

import Iidy.Yaml.Ast (NotTag (..), PreprocessingTag (..), SrcMeta (..), YamlAst (..))
import Iidy.Yaml.Handlebars.Engine qualified as HBS
import Iidy.Yaml.JMESPath qualified as JMESPath
import Iidy.Yaml.Location (zeroPosition)
import Iidy.Yaml.OValue (OValue (..), fromValue, oIsTruthy)
import Iidy.Yaml.Resolution.Resolver (astToValueRaw, mergeOObjects, traversePathO)

{- | Build all spec conformance tests from snapshot.json.
Returns an IO action because it reads from disk.
-}
buildSpecConformanceTests :: IO [TestTree]
buildSpecConformanceTests = do
    raw <- BL.readFile "spec/snapshot.json"
    case Aeson.eitherDecode raw of
        Left err -> do
            _ <- assertFailure $ "Failed to parse spec/snapshot.json: " <> err
            pure []
        Right snapshot ->
            pure
                [ testGroup "Truthiness" (truthinessTests (snTruthiness snapshot))
                , testGroup "Truthiness/Handlebars" (hbsTruthinessTests (snTruthinessHandlebars snapshot))
                , testGroup "Truthiness/JMESPath" (jmespathTruthinessTests (snTruthinessJMESPath snapshot))
                , testGroup "Merge" (mergeTests (snMerge snapshot))
                , testGroup "PathResolution" (pathTests (snPathResolution snapshot))
                , testGroup "Escape" (escapeTests (snEscape snapshot))
                , testGroup "MapValuesBinding" (mapValuesBindingTests (snMapValuesBinding snapshot))
                ]

specConformanceTests :: IO [TestTree]
specConformanceTests = buildSpecConformanceTests

------------------------------------------------------------------------
-- Snapshot data types (parsed from JSON)
------------------------------------------------------------------------

data Snapshot = Snapshot
    { snTruthiness :: [TruthinessVector]
    , snTruthinessHandlebars :: [TruthinessVector]
    , snTruthinessJMESPath :: [TruthinessVector]
    , snMerge :: [MergeVector]
    , snPathResolution :: [PathVector]
    , snEscape :: [EscapeVector]
    , snMapValuesBinding :: [MapValuesBindingVector]
    }

instance Aeson.FromJSON Snapshot where
    parseJSON = Aeson.withObject "Snapshot" $ \o -> do
        sections <- o .: "sections"
        Snapshot
            <$> sections .: "truthiness"
            <*> sections .: "truthiness_handlebars"
            <*> sections .: "truthiness_jmespath"
            <*> sections .: "merge"
            <*> sections .: "path_resolution"
            <*> sections .: "escape"
            <*> sections .: "map_values_binding"

-- Truthiness
data TruthinessVector = TruthinessVector
    { tvInput :: Value
    , tvExpected :: Bool
    }

instance Aeson.FromJSON TruthinessVector where
    parseJSON = Aeson.withObject "TruthinessVector" $ \o ->
        TruthinessVector <$> o .: "input" <*> o .: "expected"

-- Merge
data MergeVector = MergeVector
    { mvName :: Text
    , mvBase :: Value
    , mvOverlay :: Value
    , mvExpected :: Value
    }

instance Aeson.FromJSON MergeVector where
    parseJSON = Aeson.withObject "MergeVector" $ \o ->
        MergeVector
            <$> o .: "name"
            <*> o .: "base"
            <*> o .: "overlay"
            <*> o .: "expected"

-- Path resolution
data PathVector = PathVector
    { pvName :: Text
    , pvPath :: [Text]
    , pvExpected :: Value
    }

instance Aeson.FromJSON PathVector where
    parseJSON = Aeson.withObject "PathVector" $ \o ->
        PathVector <$> o .: "name" <*> o .: "path" <*> o .: "expected"

-- Escape
data EscapeVector = EscapeVector
    { evName :: Text
    , evInputType :: Text
    , evInputValue :: Maybe Value
    , evExpected :: Value
    }

instance Aeson.FromJSON EscapeVector where
    parseJSON = Aeson.withObject "EscapeVector" $ \o ->
        EscapeVector
            <$> o .: "name"
            <*> o .: "input_type"
            <*> o .:? "input_value"
            <*> o .: "expected"

-- MapValues binding
data MapValuesBindingVector = MapValuesBindingVector
    { mbName :: Text
    , mbKey :: Text
    , mbValue :: Value
    , mbExpectedBinding :: Value
    }

instance Aeson.FromJSON MapValuesBindingVector where
    parseJSON = Aeson.withObject "MapValuesBindingVector" $ \o ->
        MapValuesBindingVector
            <$> o .: "name"
            <*> o .: "key"
            <*> o .: "value"
            <*> o .: "expected_binding"

------------------------------------------------------------------------
-- Test builders
------------------------------------------------------------------------

-- | Truthiness: oIsTruthy (fromValue input) == expected
truthinessTests :: [TruthinessVector] -> [TestTree]
truthinessTests = map $ \tv ->
    let label = "truthy(" <> showCompact (tvInput tv) <> ") == " <> show (tvExpected tv)
        ov = fromValue (tvInput tv)
     in testCase label $ oIsTruthy ov @?= tvExpected tv

-- | Handlebars truthiness: all numbers are truthy (including 0)
hbsTruthinessTests :: [TruthinessVector] -> [TestTree]
hbsTruthinessTests = map $ \tv ->
    let label = "truthy/hbs(" <> showCompact (tvInput tv) <> ") == " <> show (tvExpected tv)
     in testCase label $ HBS.isTruthy (tvInput tv) @?= tvExpected tv

-- | JMESPath truthiness: all numbers are truthy (including 0)
jmespathTruthinessTests :: [TruthinessVector] -> [TestTree]
jmespathTruthinessTests = map $ \tv ->
    let label = "truthy/jmespath(" <> showCompact (tvInput tv) <> ") == " <> show (tvExpected tv)
     in testCase label $ JMESPath.isTruthy (tvInput tv) @?= tvExpected tv

{- | Merge: mergeOObjects base overlayPairs == expected
Snapshot-driven tests verify merge VALUES; the order-preservation test
below uses direct OValue construction (not JSON) to test key ordering.
-}
mergeTests :: [MergeVector] -> [TestTree]
mergeTests vecs =
    map snapshotTest vecs ++ [orderPreservationTest]
  where
    snapshotTest mv = testCase (T.unpack (mvName mv)) $ do
        let base = fromValue (mvBase mv)
            overlayPairs = case fromValue (mvOverlay mv) of
                OObject kvs -> kvs
                _ -> error "overlay must be an object"
            result = mergeOObjects base overlayPairs
            expected = fromValue (mvExpected mv)
        result @?= expected

    -- This test uses non-alphabetical keys to verify that base key order
    -- is preserved and new overlay keys are appended, not sorted.
    -- Cannot be tested through JSON because JSON objects are unordered.
    orderPreservationTest = testCase "key order: base order preserved, overlay appended" $ do
        let base = OObject [("z", ONumber 1), ("a", ONumber 2), ("m", ONumber 3)]
            overlay = [("a", ONumber 99), ("b", ONumber 4)]
            result = mergeOObjects base overlay
            -- Expected: z (base), a (updated by overlay), m (base), b (new from overlay)
            expected = OObject [("z", ONumber 1), ("a", ONumber 99), ("m", ONumber 3), ("b", ONumber 4)]
        result @?= expected

{- | Path resolution: traversePathO segments env == expected
The snapshot env is baked into the Racket script; we reconstruct it here.
-}
pathTests :: [PathVector] -> [TestTree]
pathTests = map $ \pv ->
    testCase (T.unpack (pvName pv)) $ do
        let result = case pvPath pv of
                [] -> Nothing
                (root : rest) -> case lookup root envPairs of
                    Nothing -> Nothing
                    Just val -> traversePathO rest val
            expected = case pvExpected pv of
                Null -> Nothing
                v -> Just (fromValue v)
        result @?= expected
  where
    -- Mirror the environment from the Racket snapshot script
    envPairs :: [(Text, OValue)]
    envPairs =
        [
            ( "config"
            , OObject
                [
                    ( "db"
                    , OObject
                        [ ("host", OString "localhost")
                        , ("port", ONumber 5432)
                        ]
                    )
                ]
            )
        , ("items", OArray [ONumber 10, ONumber 20, ONumber 30])
        , ("name", OString "test")
        ,
            ( "nested"
            , OArray
                [ OObject [("id", OString "first")]
                , OObject [("id", OString "second")]
                ]
            )
        ]

-- | Escape: astToValueRaw on constructed AST nodes
escapeTests :: [EscapeVector] -> [TestTree]
escapeTests = map $ \ev ->
    testCase (T.unpack (evName ev)) $ do
        let result = case evInputType ev of
                "value" -> case evInputValue ev of
                    Just v -> astToValueRaw (valueToAst v)
                    Nothing -> error "value escape test missing input_value"
                "object" -> case evInputValue ev of
                    Just (Object obj) ->
                        let pairs =
                                [ (AstPlainString (Key.toText k) dm, valueToAst v)
                                | (k, v) <- KM.toList obj
                                ]
                         in astToValueRaw (AstMapping pairs dm)
                    _ -> error "object escape test needs object input_value"
                "template" -> case evInputValue ev of
                    Just (String s) -> astToValueRaw (AstTemplatedString s dm)
                    _ -> error "template escape test needs string input_value"
                "tag" ->
                    -- Any preprocessing tag inside !$escape → sentinel "!$escaped"
                    let dummyTag = PpNot (NotTag (AstBool True dm))
                     in astToValueRaw (AstPreprocessingTag dummyTag dm)
                other -> error $ "unknown escape input_type: " <> T.unpack other
        fromValue result @?= fromValue (evExpected ev)

-- | MapValues binding: verify {key: k, value: v} structure
mapValuesBindingTests :: [MapValuesBindingVector] -> [TestTree]
mapValuesBindingTests = map $ \mb ->
    testCase (T.unpack (mbName mb)) $ do
        -- Construct the binding the same way resolveMapValues does
        let binding = OObject [("key", OString (mbKey mb)), ("value", fromValue (mbValue mb))]
            expected = fromValue (mbExpectedBinding mb)
        binding @?= expected

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Dummy SrcMeta for test AST construction
dm :: SrcMeta
dm = SrcMeta "" zeroPosition zeroPosition

-- | Convert an Aeson Value to a YamlAst node (for escape tests)
valueToAst :: Value -> YamlAst
valueToAst = \case
    Null -> AstNull dm
    Bool b -> AstBool b dm
    Number n -> AstNumber n dm
    String s -> AstPlainString s dm
    Array arr -> AstSequence (map valueToAst (V.toList arr)) dm
    Object obj ->
        AstMapping
            [(AstPlainString (Key.toText k) dm, valueToAst v) | (k, v) <- KM.toList obj]
            dm

-- | Compact string representation of a JSON Value for test labels
showCompact :: Value -> String
showCompact = \case
    Null -> "null"
    Bool True -> "true"
    Bool False -> "false"
    Number n -> show n
    String s -> show s
    Array _ -> "[...]"
    Object _ -> "{...}"
