module Iidy.Yaml.CustomResources.Expansion
  ( expandCustomResource
  , ExpansionResult(..)
  ) where

import Data.Bifunctor (bimap)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Iidy.Yaml.CustomResources.Params (TemplateInfo(..), mergeParams, validateParams)
import Iidy.Yaml.CustomResources.RefRewriting (rewriteRefs, collectGlobalRefs)
import Iidy.Yaml.OValue

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

data ExpansionResult = ExpansionResult
  { erResources      :: ![(Text, OValue)]
  , erGlobalSections :: !(Map Text OValue)
  } deriving stock (Show)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

expandCustomResource
  :: Text              -- ^ Resource instance name (e.g., "OrderEvents")
  -> OValue            -- ^ Resource definition (Properties, Overrides, etc.)
  -> TemplateInfo      -- ^ Template definition
  -> (Map Text OValue -> Text -> Either Text OValue)
     -- ^ Re-parser: given params, re-parse and resolve template body
  -> Set Text          -- ^ Additional global refs (parent resource names, not rewritten)
  -> Either Text ExpansionResult
expandCustomResource name resourceDef templateInfo reparse additionalGlobals = do
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
      allGlobals = Set.unions [globals, awsPseudoRefs, additionalGlobals]

  -- Extract resources section
  let resources = extractResources withOverrides

  -- Rewrite refs with prefix
  let rewrittenResources = map (bimap (prefix <>) (rewriteRefs prefix allGlobals)) resources

  -- Collect global sections (Parameters, Outputs, etc.)
  let globalSections = extractGlobalSections prefix allGlobals withOverrides

  Right ExpansionResult
    { erResources      = rewrittenResources
    , erGlobalSections = globalSections
    }

------------------------------------------------------------------------
-- Extraction helpers (work with OValue to preserve key ordering)
------------------------------------------------------------------------

extractPrefix :: Text -> OValue -> Text
extractPrefix defaultName = \case
  OObject kvs -> case lookupO "NamePrefix" kvs of
    Just (OString p) -> p
    _ -> defaultName
  _ -> defaultName

extractProperties :: OValue -> Map Text OValue
extractProperties = \case
  OObject kvs -> case lookupO "Properties" kvs of
    Just (OObject props) -> Map.fromList props
    _ -> Map.empty
  _ -> Map.empty

extractOverrides :: OValue -> Maybe OValue
extractOverrides = \case
  OObject kvs -> lookupO "Overrides" kvs
  _ -> Nothing

extractResources :: OValue -> [(Text, OValue)]
extractResources = \case
  OObject kvs -> case lookupO "Resources" kvs of
    Just (OObject res) -> res
    _ -> []
  _ -> []

extractGlobalSections :: Text -> Set Text -> OValue -> Map Text OValue
extractGlobalSections prefix globals = \case
  OObject kvs ->
    let sections = ["Parameters", "Outputs", "Metadata", "Mappings", "Conditions", "Transform"]
        extractSection name = case lookupO name kvs of
          Just section -> Just (name, prefixAndRewriteSection prefix globals section)
          Nothing -> Nothing
    in Map.fromList (mapMaybe extractSection sections)
  _ -> Map.empty

-- | Prefix keys in a section and rewrite refs within values.
-- Keys marked with $global: true are NOT prefixed (they're shared).
-- $global entries are stripped from the output.
prefixAndRewriteSection :: Text -> Set Text -> OValue -> OValue
prefixAndRewriteSection prefix globals = \case
  OObject kvs ->
    OObject [ (key', stripGlobal (rewriteRefs prefix globals v))
            | (k, v) <- kvs
            , k /= "$global"  -- strip top-level $global
            , let key' = if isMarkedGlobal v then k else prefix <> k
            ]
  other -> rewriteRefs prefix globals other

isMarkedGlobal :: OValue -> Bool
isMarkedGlobal (OObject kvs) = case lookupO "$global" kvs of
  Just (OBool True) -> True
  _ -> False
isMarkedGlobal _ = False

stripGlobal :: OValue -> OValue
stripGlobal (OObject kvs) = OObject [(k, v) | (k, v) <- kvs, k /= "$global"]
stripGlobal other = other

------------------------------------------------------------------------
-- Deep merge
------------------------------------------------------------------------

deepMerge :: OValue -> OValue -> OValue
deepMerge (OObject base) (OObject overlay) =
  OObject (mergeKvs base overlay)
  where
    mergeKvs bs [] = bs
    mergeKvs bs ((k, v):rest) =
      let bs' = case lookupO k bs of
            Just existing -> updateKv k (deepMerge existing v) bs
            Nothing -> bs ++ [(k, v)]
      in mergeKvs bs' rest
    updateKv key val = map (\(k, v) -> if k == key then (k, val) else (k, v))
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
