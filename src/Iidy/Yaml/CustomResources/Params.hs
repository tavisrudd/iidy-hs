module Iidy.Yaml.CustomResources.Params
  ( ParamDef(..)
  , TemplateInfo(..)
  , parseParams
  , validateParams
  , mergeParams
  ) where

import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Text.Regex.Posix ((=~))
import Iidy.Yaml.CustomResources.JsonSchema (validateSchema)
import Iidy.Yaml.OValue

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

data ParamDef = ParamDef
  { pdName          :: !Text
  , pdDefault       :: !(Maybe OValue)
  , pdType          :: !(Maybe Text)
  , pdAllowedValues :: !(Maybe [OValue])
  , pdAllowedPattern :: !(Maybe Text)
  , pdSchema        :: !(Maybe Value)
  , pdIsGlobal      :: !Bool
  } deriving stock (Show, Eq)

data TemplateInfo = TemplateInfo
  { tiParams   :: ![ParamDef]
  , tiRawBody  :: !Text
  , tiLocation :: !Text
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Parsing
------------------------------------------------------------------------

parseParams :: Value -> Either Text [ParamDef]
parseParams (Array arr) =
  traverse parseParamDef (V.toList arr)
parseParams _ = Left "$params must be a sequence"

parseParamDef :: Value -> Either Text ParamDef
parseParamDef (Object obj) = do
  name <- case KM.lookup "Name" obj of
    Just (String n) -> Right n
    Just _ -> Left "$params entry: Name must be a string"
    Nothing -> Left "$params entry: Name is required"
  let getOptText key = case KM.lookup (Key.fromText key) obj of
        Just (String s) -> Just s
        _ -> Nothing
      getOptVal key = fmap fromValue (KM.lookup (Key.fromText key) obj)
      isGlobal = case KM.lookup "$global" obj of
        Just (Bool True) -> True
        _ -> False
      allowedValues = case KM.lookup "AllowedValues" obj of
        Just (Array vs) -> Just (map fromValue (V.toList vs))
        _ -> Nothing
  Right ParamDef
    { pdName          = name
    , pdDefault       = getOptVal "Default"
    , pdType          = getOptText "Type"
    , pdAllowedValues = allowedValues
    , pdAllowedPattern = getOptText "AllowedPattern"
    , pdSchema        = KM.lookup (Key.fromText "Schema") obj
    , pdIsGlobal      = isGlobal
    }
parseParamDef _ = Left "$params entries must be mappings"

------------------------------------------------------------------------
-- Validation
------------------------------------------------------------------------

validateParams :: [ParamDef] -> Map Text OValue -> Either Text ()
validateParams defs provided = traverse_ validateOne defs
  where
    validateOne pd =
      let name = pdName pd
          mval = Map.lookup name provided
      in case mval of
        Nothing
          | Just _ <- pdDefault pd -> Right ()
          | otherwise -> Left $ "Required parameter missing: " <> name
        Just val -> do
          validateAllowedValues pd val
          validateAllowedPattern pd val
          validateType pd val
          validateParamSchema pd val

validateAllowedValues :: ParamDef -> OValue -> Either Text ()
validateAllowedValues pd val = case pdAllowedValues pd of
  Nothing -> Right ()
  Just allowed
    | val `elem` allowed -> Right ()
    | isCfnRef val -> Right ()  -- skip for CFN references
    | otherwise -> Left $ pdName pd <> ": value not in AllowedValues"

validateAllowedPattern :: ParamDef -> OValue -> Either Text ()
validateAllowedPattern pd val = case pdAllowedPattern pd of
  Nothing -> Right ()
  Just pat -> case val of
    OString s
      | (T.unpack s =~ T.unpack pat :: Bool) -> Right ()
      | otherwise -> Left $ pdName pd <> ": value does not match AllowedPattern: " <> pat
    _ -> Right ()

validateType :: ParamDef -> OValue -> Either Text ()
validateType pd val = case pdType pd of
  Nothing -> Right ()
  Just "String"  -> expectType pd val isOString "String"
  Just "string"  -> expectType pd val isOString "String"
  Just "Number"  -> expectType pd val isONumber "Number"
  Just "number"  -> expectType pd val isONumber "Number"
  Just "Object"  -> expectType pd val isOObject "Object"
  Just "object"  -> expectType pd val isOObject "Object"
  Just t
    | "AWS:" `T.isPrefixOf` t -> Right ()
    | "List<" `T.isPrefixOf` t -> Right ()
    | t == "CommaDelimitedList" -> Right ()
    | otherwise -> Left $ "Unknown parameter type: " <> t

expectType :: ParamDef -> OValue -> (OValue -> Bool) -> Text -> Either Text ()
expectType pd val check typeName
  | check val = Right ()
  | isCfnRef val = Right ()
  | otherwise = Left $ pdName pd <> ": expected " <> typeName

isOString :: OValue -> Bool
isOString (OString _) = True
isOString _ = False

isONumber :: OValue -> Bool
isONumber (ONumber _) = True
isONumber _ = False

isOObject :: OValue -> Bool
isOObject (OObject _) = True
isOObject _ = False

-- | Validate a param value against its JSON Schema definition, if any.
validateParamSchema :: ParamDef -> OValue -> Either Text ()
validateParamSchema pd val = case pdSchema pd of
  Nothing -> Right ()
  Just schema
    | isCfnRef val -> Right ()  -- skip for CFN intrinsic values
    | otherwise ->
        let jsonVal = Aeson.toJSON (toValue val)
        in case validateSchema schema jsonVal of
          Left err -> Left $ "Schema validation failed for '" <> pdName pd <> "': " <> err
          Right () -> Right ()

isCfnRef :: OValue -> Bool
isCfnRef (OObject kvs) = any (`elem` keys) cfnRefKeys
  where
    keys = map fst kvs
    cfnRefKeys = [ "Ref", "Fn::Sub", "Fn::Join", "Fn::Select", "Fn::If"
                 , "Fn::GetAtt", "Fn::ImportValue", "Fn::FindInMap"
                 , "!Ref", "!Sub", "!Join", "!Select", "!If"
                 , "!GetAtt", "!ImportValue", "!FindInMap"
                 ]
isCfnRef _ = False

------------------------------------------------------------------------
-- Merging
------------------------------------------------------------------------

mergeParams :: [ParamDef] -> Map Text OValue -> Map Text OValue
mergeParams defs provided =
  foldl' addDefault provided defs
  where
    addDefault acc pd = case Map.lookup (pdName pd) acc of
      Just _ -> acc
      Nothing -> case pdDefault pd of
        Just def -> Map.insert (pdName pd) def acc
        Nothing -> acc

traverse_ :: (a -> Either e ()) -> [a] -> Either e ()
traverse_ _ [] = Right ()
traverse_ f (x:xs) = f x >> traverse_ f xs
