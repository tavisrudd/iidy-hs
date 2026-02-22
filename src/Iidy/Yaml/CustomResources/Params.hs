module Iidy.Yaml.CustomResources.Params
  ( ParamDef(..)
  , TemplateInfo(..)
  , parseParams
  , validateParams
  , mergeParams
  ) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Vector as V
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
  Just _pattern -> case val of
    OString _s -> Right ()  -- TODO: regex matching
    _ -> Right ()

validateType :: ParamDef -> OValue -> Either Text ()
validateType pd val = case pdType pd of
  Nothing -> Right ()
  Just "String" -> case val of
    OString _ -> Right ()
    _ | isCfnRef val -> Right ()
    _ -> Left $ pdName pd <> ": expected String"
  Just "Number" -> case val of
    ONumber _ -> Right ()
    _ | isCfnRef val -> Right ()
    _ -> Left $ pdName pd <> ": expected Number"
  Just _ -> Right ()  -- AWS types etc

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
