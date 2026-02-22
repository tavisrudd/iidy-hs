module Iidy.Yaml.OValue
  ( OValue(..)
  , toValue
  , fromValue
  , oNull, oBool, oNumber, oString
  , oArray, oObject
  , oIsTruthy
  , oValuesEqual
  , oValueToText
  , lookupO
  ) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Scientific (Scientific)
import qualified Data.Scientific as Sci
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

-- | Value type that preserves mapping key insertion order.
data OValue
  = ONull
  | OBool !Bool
  | ONumber !Scientific
  | OString !Text
  | OArray ![OValue]
  | OObject ![(Text, OValue)]   -- insertion-ordered key-value pairs
  deriving stock (Show, Eq)

-- | Convert ordered value to aeson Value (loses key order).
toValue :: OValue -> Value
toValue = \case
  ONull        -> Null
  OBool b      -> Bool b
  ONumber n    -> Number n
  OString s    -> String s
  OArray items -> Array (V.fromList (map toValue items))
  OObject kvs  -> Object (KM.fromList [(Key.fromText k, toValue v) | (k, v) <- kvs])

-- | Convert aeson Value to ordered value (preserves insertion order via aeson ordered-keymap).
fromValue :: Value -> OValue
fromValue = \case
  Null       -> ONull
  Bool b     -> OBool b
  Number n   -> ONumber n
  String s   -> OString s
  Array arr  -> OArray (map fromValue (V.toList arr))
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

oIsTruthy :: OValue -> Bool
oIsTruthy = \case
  ONull     -> False
  OBool b   -> b
  OString s -> not (T.null s)
  ONumber _ -> True
  OArray a  -> not (null a)
  OObject o -> not (null o)

oValuesEqual :: OValue -> OValue -> Bool
oValuesEqual (ONumber a) (ONumber b) = a == b
oValuesEqual a b = a == b

oValueToText :: OValue -> Text
oValueToText = \case
  OString s  -> s
  ONumber n  -> case Sci.floatingOrInteger n of
    Left (d :: Double) -> T.pack (show d)
    Right (i :: Integer) -> T.pack (show i)
  OBool True  -> "true"
  OBool False -> "false"
  ONull      -> "null"
  other      -> T.pack (show other)

------------------------------------------------------------------------
-- Lookup
------------------------------------------------------------------------

lookupO :: Text -> [(Text, OValue)] -> Maybe OValue
lookupO k kvs = case [v | (k', v) <- kvs, k' == k] of
  (v:_) -> Just v
  []    -> Nothing
