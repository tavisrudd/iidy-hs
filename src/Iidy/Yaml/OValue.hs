module Iidy.Yaml.OValue (
    OValue (..),
    toValue,
    fromValue,
    oNull,
    oBool,
    oNumber,
    oString,
    oArray,
    oObject,
    oIsTruthy,
    oValuesEqual,
    oValueToText,
    lookupO,
) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Scientific (Scientific)
import Data.Scientific qualified as Sci
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V

-- | Value type that preserves mapping key insertion order.
data OValue
    = ONull
    | OBool !Bool
    | ONumber !Scientific
    | OString !Text
    | OArray ![OValue]
    | OObject ![(Text, OValue)] -- insertion-ordered key-value pairs
    deriving stock (Show, Eq)

-- | Convert ordered value to aeson Value (loses key order).
toValue :: OValue -> Value
toValue = \case
    ONull -> Null
    OBool b -> Bool b
    ONumber n -> Number n
    OString s -> String s
    OArray items -> Array (V.fromList (map toValue items))
    OObject kvs -> Object (KM.fromList [(Key.fromText k, toValue v) | (k, v) <- kvs])

-- | Convert aeson Value to ordered value (preserves insertion order via aeson ordered-keymap).
fromValue :: Value -> OValue
fromValue = \case
    Null -> ONull
    Bool b -> OBool b
    Number n -> ONumber n
    String s -> OString s
    Array arr -> OArray (map fromValue (V.toList arr))
    Object obj -> OObject [(Key.toText k, fromValue v) | (k, v) <- KM.toList obj]

------------------------------------------------------------------------
-- Smart constructors
------------------------------------------------------------------------

oNull :: OValue
oNull = ONull

oBool :: Bool -> OValue
oBool = OBool

oNumber :: Scientific -> OValue
oNumber = ONumber

oString :: Text -> OValue
oString = OString

oArray :: [OValue] -> OValue
oArray = OArray

oObject :: [(Text, OValue)] -> OValue
oObject = OObject

------------------------------------------------------------------------
-- Predicates
------------------------------------------------------------------------

{- | iidy preprocessing truthiness, used by !$if, !$not, !$map filter, etc.
Note: zero is FALSY here (matching Rust iidy's is_truthy: n != 0.0).
This differs from JMESPath.isTruthy and Handlebars.Engine.isTruthy which
both treat all numbers as truthy per their respective specs.
-}
oIsTruthy :: OValue -> Bool
oIsTruthy = \case
    ONull -> False
    OBool b -> b
    OString s -> not (T.null s)
    ONumber n -> n /= 0
    OArray a -> not (null a)
    OObject o -> not (null o)

oValuesEqual :: OValue -> OValue -> Bool
oValuesEqual (ONumber a) (ONumber b) = a == b
oValuesEqual a b = a == b

oValueToText :: OValue -> Text
oValueToText = \case
    OString s -> s
    ONumber n -> case Sci.floatingOrInteger n of
        Left (d :: Double) -> T.pack (show d)
        Right (i :: Integer) -> T.pack (show i)
    OBool True -> "true"
    OBool False -> "false"
    ONull -> "null"
    other -> T.pack (show other)

------------------------------------------------------------------------
-- Lookup
------------------------------------------------------------------------

{- | O(n) linear scan — intentionally kept simple. CloudFormation mappings
have 5-30 keys typically (CFN limits: 500 resources, 60 parameters).
At n=20, list scan averages ~10 Text comparisons; a Map would cost ~87
comparisons just to construct plus ~4 per lookup, making it a net loss
for the single-lookup-per-object pattern used throughout the resolver.
List also wins on cache locality vs scattered tree nodes. Only worth
switching if templates routinely exceed ~100 keys AND the same object
is queried 10+ times — neither happens in practice.
-}
lookupO :: Text -> [(Text, OValue)] -> Maybe OValue
lookupO k kvs = case [v | (k', v) <- kvs, k' == k] of
    (v : _) -> Just v
    [] -> Nothing
