module Iidy.Yaml.CustomResources.Expansion
  ( expandCustomResource
  , ExpansionResult(..)
  ) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Iidy.Yaml.CustomResources.Params (TemplateInfo(..), mergeParams, validateParams)
import Iidy.Yaml.CustomResources.RefRewriting (rewriteRefs, collectGlobalRefs)

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

data ExpansionResult = ExpansionResult
  { erResources      :: ![(Text, Value)]
  , erGlobalSections :: !(Map Text Value)
  } deriving stock (Show)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

expandCustomResource
  :: Text              -- ^ Resource instance name (e.g., "OrderEvents")
  -> Value             -- ^ Resource definition (Properties, Overrides, etc.)
  -> TemplateInfo      -- ^ Template definition
  -> (Map Text Value -> Text -> Either Text Value)
     -- ^ Re-parser: given params, re-parse and resolve template body
  -> Either Text ExpansionResult
expandCustomResource name resourceDef templateInfo reparse = do
  let prefix = extractPrefix name resourceDef
      properties = extractProperties resourceDef
      overrides = extractOverrides resourceDef

  -- Merge provided properties with defaults
  let merged = mergeParams (tiParams templateInfo) properties

  -- Validate parameters
  validateParams (tiParams templateInfo) merged

  -- Re-parse template with parameter bindings
  resolved <- reparse merged (tiRawBody templateInfo)

  -- Apply overrides (deep merge)
  let withOverrides = case overrides of
        Just ov -> deepMerge resolved ov
        Nothing -> resolved

  -- Collect global refs from template
  let globals = collectGlobalRefs withOverrides
      allGlobals = Set.union globals (awsPseudoRefs)

  -- Extract resources section
  let resources = extractResources withOverrides

  -- Rewrite refs with prefix
  let rewrittenResources = map (\(k, v) -> (prefix <> k, rewriteRefs prefix allGlobals v)) resources

  -- Collect global sections (Parameters, Outputs, etc.)
  let globalSections = extractGlobalSections prefix allGlobals withOverrides

  Right ExpansionResult
    { erResources      = rewrittenResources
    , erGlobalSections = globalSections
    }

------------------------------------------------------------------------
-- Extraction helpers
------------------------------------------------------------------------

extractPrefix :: Text -> Value -> Text
extractPrefix defaultName = \case
  Object obj -> case KM.lookup "NamePrefix" obj of
    Just (String p) -> p
    _ -> defaultName
  _ -> defaultName

extractProperties :: Value -> Map Text Value
extractProperties = \case
  Object obj -> case KM.lookup "Properties" obj of
    Just (Object props) ->
      Map.fromList [(Key.toText k, v) | (k, v) <- KM.toList props]
    _ -> Map.empty
  _ -> Map.empty

extractOverrides :: Value -> Maybe Value
extractOverrides = \case
  Object obj -> KM.lookup "Overrides" obj
  _ -> Nothing

extractResources :: Value -> [(Text, Value)]
extractResources = \case
  Object obj -> case KM.lookup "Resources" obj of
    Just (Object res) -> [(Key.toText k, v) | (k, v) <- KM.toList res]
    _ -> []
  _ -> []

extractGlobalSections :: Text -> Set Text -> Value -> Map Text Value
extractGlobalSections prefix globals = \case
  Object obj ->
    let sections = ["Parameters", "Outputs", "Metadata", "Mappings", "Conditions", "Transform"]
        extractSection name = case KM.lookup (Key.fromText name) obj of
          Just section -> Just (name, prefixAndRewriteSection prefix globals section)
          Nothing -> Nothing
    in Map.fromList (concatMap (maybe [] (:[]) . extractSection) sections)
  _ -> Map.empty

-- | Prefix keys in a section and rewrite refs within values
prefixAndRewriteSection :: Text -> Set Text -> Value -> Value
prefixAndRewriteSection prefix globals = \case
  Object obj ->
    let prefixed = KM.fromList
          [ (Key.fromText (prefix <> Key.toText k), rewriteRefs prefix globals v)
          | (k, v) <- KM.toList obj
          ]
    in Object prefixed
  other -> rewriteRefs prefix globals other

------------------------------------------------------------------------
-- Deep merge
------------------------------------------------------------------------

deepMerge :: Value -> Value -> Value
deepMerge (Object base) (Object overlay) =
  Object (KM.unionWith deepMerge base overlay)
deepMerge _ overlay = overlay

------------------------------------------------------------------------
-- AWS pseudo-references (never rewritten)
------------------------------------------------------------------------

awsPseudoRefs :: Set Text
awsPseudoRefs = Set.fromList
  [ "AWS::AccountId"
  , "AWS::NotificationARNs"
  , "AWS::NoValue"
  , "AWS::Partition"
  , "AWS::Region"
  , "AWS::StackId"
  , "AWS::StackName"
  , "AWS::URLSuffix"
  ]
