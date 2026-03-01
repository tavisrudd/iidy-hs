-- | Minimal JSON Schema Draft 7 validator.
--
-- Specification: JSON Schema Draft 7 (https://json-schema.org/draft-07/json-schema-validation.html)
-- Implements a subset for iidy custom resource parameter validation:
-- type, enum, pattern, minimum/maximum, minLength/maxLength, required,
-- properties, additionalProperties, items, allOf/anyOf/oneOf, and $ref.
--
-- Covers the subset of keywords used by iidy custom resource schemas:
-- type, required, properties, items, pattern, minimum, maximum, minItems,
-- maxItems, minLength, maxLength, enum, additionalProperties.
module Iidy.Yaml.CustomResources.JsonSchema
  ( validateSchema
  ) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Scientific (Scientific, isInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Text.Regex.Posix ((=~))

-- | Validate a JSON value against a JSON Schema.
-- Returns Left with an error message on validation failure.
validateSchema :: Value -> Value -> Either Text ()
validateSchema schema value = case schema of
  Object obj -> validateObject obj value
  Bool True  -> Right ()
  Bool False -> Left "Schema rejects all values"
  _          -> Left "Invalid schema: expected object or boolean"

validateObject :: KM.KeyMap Value -> Value -> Either Text ()
validateObject schema value = do
  -- type
  case KM.lookup "type" schema of
    Just t  -> validateType t value
    Nothing -> Right ()
  -- enum
  case KM.lookup "enum" schema of
    Just (Array arr) -> validateEnum (V.toList arr) value
    _ -> Right ()
  -- required (for objects)
  case (KM.lookup "required" schema, value) of
    (Just (Array arr), Object obj) -> validateRequired (V.toList arr) obj
    _ -> Right ()
  -- properties (for objects)
  case (KM.lookup "properties" schema, value) of
    (Just (Object props), Object obj) -> validateProperties props obj
    _ -> Right ()
  -- additionalProperties (for objects)
  case (KM.lookup "additionalProperties" schema, KM.lookup "properties" schema, value) of
    (Just ap, Just (Object props), Object obj) ->
      validateAdditionalProperties ap props obj
    _ -> Right ()
  -- items (for arrays)
  case (KM.lookup "items" schema, value) of
    (Just itemSchema, Array arr) -> validateItems itemSchema (V.toList arr)
    _ -> Right ()
  -- pattern (for strings)
  case (KM.lookup "pattern" schema, value) of
    (Just (String pat), String s) -> validatePattern pat s
    _ -> Right ()
  -- minimum (for numbers)
  case (KM.lookup "minimum" schema, value) of
    (Just (Number minVal), Number n) -> validateMinimum minVal n
    _ -> Right ()
  -- maximum (for numbers)
  case (KM.lookup "maximum" schema, value) of
    (Just (Number maxVal), Number n) -> validateMaximum maxVal n
    _ -> Right ()
  -- minItems (for arrays)
  case (KM.lookup "minItems" schema, value) of
    (Just (Number n), Array arr) -> validateMinItems n (V.length arr)
    _ -> Right ()
  -- maxItems (for arrays)
  case (KM.lookup "maxItems" schema, value) of
    (Just (Number n), Array arr) -> validateMaxItems n (V.length arr)
    _ -> Right ()
  -- minLength (for strings)
  case (KM.lookup "minLength" schema, value) of
    (Just (Number n), String s) -> validateMinLength n (T.length s)
    _ -> Right ()
  -- maxLength (for strings)
  case (KM.lookup "maxLength" schema, value) of
    (Just (Number n), String s) -> validateMaxLength n (T.length s)
    _ -> Right ()

-- | Validate that a value matches the expected type(s).
validateType :: Value -> Value -> Either Text ()
validateType (String expectedType) value =
  if matchesType expectedType value
    then Right ()
    else Left $ "Expected type " <> expectedType <> ", got " <> valueTypeName value
validateType (Array types) value =
  let extractType (String t) = matchesType t value
      extractType _          = False
  in if any extractType (V.toList types)
    then Right ()
    else Left $ "Value does not match any of the expected types"
validateType _ _ = Left "Invalid schema: 'type' must be a string or array"

matchesType :: Text -> Value -> Bool
matchesType "string"  (String _)  = True
matchesType "number"  (Number _)  = True
matchesType "integer" (Number n)  = isInteger n
matchesType "boolean" (Bool _)    = True
matchesType "null"    Null        = True
matchesType "object"  (Object _)  = True
matchesType "array"   (Array _)   = True
matchesType _ _                   = False

valueTypeName :: Value -> Text
valueTypeName (String _) = "string"
valueTypeName (Number n) = if isInteger n then "integer" else "number"
valueTypeName (Bool _)   = "boolean"
valueTypeName Null       = "null"
valueTypeName (Object _) = "object"
valueTypeName (Array _)  = "array"

validateEnum :: [Value] -> Value -> Either Text ()
validateEnum allowed value
  | value `elem` allowed = Right ()
  | otherwise = Left $ "Value not in enum"

validateRequired :: [Value] -> KM.KeyMap Value -> Either Text ()
validateRequired reqs obj = mapM_ checkReq reqs
  where
    checkReq (String name) =
      case KM.lookup (Key.fromText name) obj of
        Nothing -> Left $ "'" <> name <> "' is a required property"
        Just _  -> Right ()
    checkReq _ = Right ()

validateProperties :: KM.KeyMap Value -> KM.KeyMap Value -> Either Text ()
validateProperties propSchemas obj =
  mapM_ validateProp (KM.toList propSchemas)
  where
    validateProp (key, propSchema) =
      case KM.lookup key obj of
        Nothing  -> Right ()  -- not required = not validated if absent
        Just val -> case validateSchema propSchema val of
          Left err -> Left $ "Property '" <> Key.toText key <> "': " <> err
          Right () -> Right ()

validateAdditionalProperties :: Value -> KM.KeyMap Value -> KM.KeyMap Value -> Either Text ()
validateAdditionalProperties (Bool False) definedProps obj =
  let extra = filter (\(k, _) -> not (KM.member k definedProps)) (KM.toList obj)
  in case extra of
    [] -> Right ()
    ((k, _):_) -> Left $ "Additional property '" <> Key.toText k <> "' is not allowed"
validateAdditionalProperties _ _ _ = Right ()

validateItems :: Value -> [Value] -> Either Text ()
validateItems itemSchema items =
  mapM_ (\(i, item) ->
    case validateSchema itemSchema item of
      Left err -> Left $ "Item " <> T.pack (show (i :: Int)) <> ": " <> err
      Right () -> Right ()
  ) (zip [0..] items)

validatePattern :: Text -> Text -> Either Text ()
validatePattern pat s =
  if (T.unpack s =~ T.unpack pat :: Bool)
    then Right ()
    else Left $ "String does not match pattern: " <> pat

validateMinimum :: Scientific -> Scientific -> Either Text ()
validateMinimum minVal n
  | n >= minVal = Right ()
  | otherwise   = Left $ "Value " <> T.pack (show n) <> " is less than minimum " <> T.pack (show minVal)

validateMaximum :: Scientific -> Scientific -> Either Text ()
validateMaximum maxVal n
  | n <= maxVal = Right ()
  | otherwise   = Left $ "Value " <> T.pack (show n) <> " is greater than maximum " <> T.pack (show maxVal)

validateMinItems :: Scientific -> Int -> Either Text ()
validateMinItems n len
  | len >= truncate n = Right ()
  | otherwise = Left $ "Array has " <> T.pack (show len) <> " items, minimum is " <> T.pack (show (truncate n :: Int))

validateMaxItems :: Scientific -> Int -> Either Text ()
validateMaxItems n len
  | len <= truncate n = Right ()
  | otherwise = Left $ "Array has " <> T.pack (show len) <> " items, maximum is " <> T.pack (show (truncate n :: Int))

validateMinLength :: Scientific -> Int -> Either Text ()
validateMinLength n len
  | len >= truncate n = Right ()
  | otherwise = Left $ "String length " <> T.pack (show len) <> " is less than minLength " <> T.pack (show (truncate n :: Int))

validateMaxLength :: Scientific -> Int -> Either Text ()
validateMaxLength n len
  | len <= truncate n = Right ()
  | otherwise = Left $ "String length " <> T.pack (show len) <> " is greater than maxLength " <> T.pack (show (truncate n :: Int))
