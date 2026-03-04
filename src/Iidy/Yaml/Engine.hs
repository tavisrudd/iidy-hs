module Iidy.Yaml.Engine
  ( preprocessYaml
  , preprocessYaml11
  , PreprocessResult(..)
  , PreprocessError(..)
  , LoadImportFn
  ) where

import Control.Monad (foldM)
import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Iidy.Yaml.Ast
import Iidy.Yaml.Handlebars.Engine (interpolate, defaultHelpers, InterpolateError(..))
import Iidy.Yaml.Imports.Manifest
import Iidy.Yaml.Imports.Types (ImportData(..), ImportError(..))
import Iidy.Yaml.CustomResources.Params (parseParams)
import Iidy.Yaml.OValue (OValue(..), toValue, fromValue)
import Iidy.Yaml.Parser (parseYaml)
import Iidy.Yaml.Resolution.Context

import Iidy.Yaml.Resolution.Resolver (resolveAst, ResolveError(..))

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

data PreprocessResult = PreprocessResult
  { prValue         :: !OValue
  , prImportRecords :: !ImportManifest
  } deriving stock (Show)

data PreprocessError
  = PeResolveError !ResolveError
  | PeImportError !ImportError
  | PeHandlebarsError !InterpolateError
  | PeCycleError !Text
  deriving stock (Show)

-- | Function type for loading imports (passed in by caller)
type LoadImportFn = Text -> Text -> IO (Either ImportError ImportData)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

preprocessYaml :: LoadImportFn -> YamlAst -> Text -> IO (Either PreprocessError PreprocessResult)
preprocessYaml loader ast baseLocation = process loader ast baseLocation False

preprocessYaml11 :: LoadImportFn -> YamlAst -> Text -> IO (Either PreprocessError PreprocessResult)
preprocessYaml11 loader ast baseLocation = process loader ast baseLocation True

------------------------------------------------------------------------
-- Main processing pipeline
------------------------------------------------------------------------

process :: LoadImportFn -> YamlAst -> Text -> Bool -> IO (Either PreprocessError PreprocessResult)
process loader ast baseLocation yaml11Compat = do
  case pushImport baseLocation emptyStack of
    Left err -> pure $ Left $ PeCycleError err
    Right stack' -> do
      -- Phase 1: Load imports and build environment
      result <- loadImportsAndDefs loader ast baseLocation Map.empty Map.empty emptyManifest stack'
      case result of
        Left err -> pure $ Left err
        Right (env, templateDefs, manifest, _stack'') -> do
          -- Phase 2: Build context and resolve
          let ctx = emptyContext
                { tcVariables = env
                , tcInputUri = Just baseLocation
                , tcCustomTemplateDefs = templateDefs
                }
          case resolveAst ctx ast of
            Left reErr -> pure $ Left $ PeResolveError reErr
            Right resolved -> do
              let final = if yaml11Compat
                          then convertYaml11CompatO resolved
                          else resolved
              pure $ Right $ PreprocessResult
                { prValue = final
                , prImportRecords = manifest
                }

------------------------------------------------------------------------
-- Phase 1: Load imports and definitions
------------------------------------------------------------------------

loadImportsAndDefs
  :: LoadImportFn -> YamlAst -> Text -> Map Text OValue -> Map Text TemplateInfo
  -> ImportManifest -> ImportStack
  -> IO (Either PreprocessError (Map Text OValue, Map Text TemplateInfo, ImportManifest, ImportStack))
loadImportsAndDefs loader ast baseLocation env0 tmplDefs0 manifest0 stack0 =
  case ast of
    AstMapping pairs _ -> do
      let defsAst = findSectionPairs "$defs" pairs
          importsAst = findSectionPairs "$imports" pairs
      -- Process $defs
      case processDefs env0 defsAst baseLocation of
        Left err -> pure $ Left err
        Right env1 ->
          processImports loader env1 tmplDefs0 manifest0 stack0 importsAst baseLocation
    _ -> pure $ Right (env0, tmplDefs0, manifest0, stack0)

findSectionPairs :: Text -> [(YamlAst, YamlAst)] -> [(YamlAst, YamlAst)]
findSectionPairs name pairs =
  case filter (isKeyNamed name . fst) pairs of
    [(_, AstMapping subPairs _)] -> subPairs
    _ -> []
  where
    isKeyNamed n (AstPlainString s _) = s == n
    isKeyNamed _ _ = False

------------------------------------------------------------------------
-- Process $defs (sequential let* semantics)
------------------------------------------------------------------------

processDefs :: Map Text OValue -> [(YamlAst, YamlAst)] -> Text -> Either PreprocessError (Map Text OValue)
processDefs env0 defs _baseLocation = foldM processOneDef env0 defs
  where
    processOneDef env (keyAst, valAst) =
      let keyText = extractKeyText keyAst
          ctx = emptyContext
                  { tcVariables = env
                  , tcInputUri = Nothing
                  }
      in case resolveAst ctx valAst of
           Left reErr -> Left (PeResolveError reErr)
           Right resolved -> Right (Map.insert keyText resolved env)

------------------------------------------------------------------------
-- Process $imports
------------------------------------------------------------------------

processImports
  :: LoadImportFn -> Map Text OValue -> Map Text TemplateInfo
  -> ImportManifest -> ImportStack
  -> [(YamlAst, YamlAst)] -> Text
  -> IO (Either PreprocessError (Map Text OValue, Map Text TemplateInfo, ImportManifest, ImportStack))
processImports _loader env tmplDefs manifest stack [] _baseLocation =
  pure $ Right (env, tmplDefs, manifest, stack)
processImports loader env tmplDefs manifest stack ((keyAst, locAst):rest) baseLocation = do
  let importKey = extractKeyText keyAst
      locationText = extractKeyText locAst
  -- Interpolate handlebars in import location
  case interpolateLocation env locationText of
    Left err -> pure $ Left $ PeHandlebarsError err
    Right resolvedLoc -> do
      -- Cycle detection: push import location onto stack
      case pushImport resolvedLoc stack of
        Left cycleErr -> pure $ Left $ PeCycleError cycleErr
        Right stack' -> do
          result <- loader resolvedLoc baseLocation
          case result of
            Left err -> pure $ Left $ PeImportError err
            Right importData -> do
              -- Check for $params and store as template def if found
              let tmplDefs' = case idDoc importData of
                    Object obj | Just paramsVal <- KM.lookup "$params" obj ->
                      case parseParams paramsVal of
                        Right params ->
                          Map.insert importKey (TemplateInfo params (idRawData importData) (idLocation importData)) tmplDefs
                        Left _err -> tmplDefs  -- Skip malformed $params
                    _ -> tmplDefs
              -- Recursively preprocess if imported doc has $imports or $defs
              importResult <- processImportedDoc loader (idDoc importData) (idRawData importData) (idLocation importData) env manifest stack'
              case importResult of
                Left err -> pure $ Left err
                Right (importedValue, manifest', stack'') -> do
                  let env' = Map.insert importKey importedValue env
                  let stackFinal = popImport stack''
                  processImports loader env' tmplDefs' manifest' stackFinal rest baseLocation

------------------------------------------------------------------------
-- Recursive import preprocessing
------------------------------------------------------------------------

-- | Recursively preprocess an imported document if it contains $imports or $defs.
-- Matches Rust's process_imported_document behavior (engine.rs:380-442).
processImportedDoc
  :: LoadImportFn -> Value -> Text -> Text
  -> Map Text OValue -> ImportManifest -> ImportStack
  -> IO (Either PreprocessError (OValue, ImportManifest, ImportStack))
processImportedDoc loader doc rawData docLocation env manifest stack =
  case doc of
    Object obj
      | hasImportsOrDefs obj -> do
          -- Re-parse to AST and recursively preprocess
          case parseYaml (BL.fromStrict (TE.encodeUtf8 rawData)) docLocation of
            Left _parseErr ->
              -- If re-parse fails, fall back to raw value
              pure $ Right (fromValue doc, manifest, stack)
            Right ast -> do
              result <- loadImportsAndDefs loader ast docLocation env Map.empty manifest stack
              case result of
                Left err -> pure $ Left err
                Right (docEnv, _docTmplDefs, manifest', stack') -> do
                  -- Resolve AST with the document's own environment
                  let ctx = emptyContext
                        { tcVariables = docEnv
                        , tcInputUri = Just docLocation
                        }
                  case resolveAst ctx ast of
                    Left reErr -> pure $ Left $ PeResolveError reErr
                    Right resolved -> pure $ Right (resolved, manifest', stack')
    _ -> pure $ Right (fromValue doc, manifest, stack)

-- | Check if a JSON object has $imports or $defs keys that need preprocessing.
hasImportsOrDefs :: KM.KeyMap Value -> Bool
hasImportsOrDefs obj =
  KM.member (Key.fromText "$imports") obj || KM.member (Key.fromText "$defs") obj

------------------------------------------------------------------------
-- Handlebars interpolation for import locations
------------------------------------------------------------------------

interpolateLocation :: Map Text OValue -> Text -> Either InterpolateError Text
interpolateLocation env loc
  | not (T.isInfixOf "{{" loc) = Right loc
  | otherwise =
      let ctx = Object (KM.fromList [(Key.fromText k, toValue v) | (k, v) <- Map.toList env])
      in interpolate defaultHelpers ctx loc

------------------------------------------------------------------------
-- YAML 1.1 compatibility
------------------------------------------------------------------------

convertYaml11CompatO :: OValue -> OValue
convertYaml11CompatO = \case
  OObject kvs -> OObject [(k, convertYaml11CompatO v) | (k, v) <- kvs]
  OArray items -> OArray (map convertYaml11CompatO items)
  OString s
    | isBooleanLike s -> OBool (isTrueIsh s)
    | otherwise -> OString s
  other -> other

isBooleanLike :: Text -> Bool
isBooleanLike s = s `elem`
  [ "true", "false", "yes", "no", "on", "off"
  , "True", "False", "Yes", "No", "On", "Off"
  , "TRUE", "FALSE", "YES", "NO", "ON", "OFF"
  ]

isTrueIsh :: Text -> Bool
isTrueIsh s = T.toLower s `elem` ["true", "yes", "on"]

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

extractKeyText :: YamlAst -> Text
extractKeyText = \case
  AstPlainString s _ -> s
  AstTemplatedString s _ -> s
  AstNumber n _ -> T.pack (show n)
  AstBool True _ -> "true"
  AstBool False _ -> "false"
  AstNull _ -> "null"
  _ -> ""

