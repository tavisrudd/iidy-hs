module Iidy.Yaml.Engine (
    preprocessYaml,
    preprocessYaml11,
    preprocessYamlWith,
    PreprocessResult (..),
    PreprocessError (..),
    LoadImportFn,
) where

import Control.Monad (foldM)
import Crypto.Hash (SHA256 (..), hashWith)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteArray qualified as BA
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Iidy.Yaml.Ast
import Iidy.Yaml.CustomResources.Params (parseParams)
import Iidy.Yaml.Handlebars.Engine (InterpolateError (..), defaultHelpers, interpolate)
import Iidy.Yaml.Imports.Manifest
import Iidy.Yaml.Imports.Types (
    ImportBase (..),
    ImportData (..),
    ImportError (..),
    ImportRecord (..),
    TrustedSources,
    childBase,
    isTrustedRequester,
    noTrustedSources,
    rootBase,
 )
import Iidy.Yaml.OValue (OValue (..), fromValue, toValue)
import Iidy.Yaml.Parser (parseYaml)
import Iidy.Yaml.Resolution.Context

import Iidy.Yaml.Resolution.Resolver (ResolveError (..), resolveAst)

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

data PreprocessResult = PreprocessResult
    { prValue :: !OValue
    , prImportRecords :: !ImportManifest
    }
    deriving stock (Show)

data PreprocessError
    = PeResolveError !ResolveError
    | PeImportError !ImportError
    | PeHandlebarsError !InterpolateError
    | PeCycleError !Text
    deriving stock (Show)

{- | Function type for loading imports (passed in by caller): the import
location and the requesting document ('ImportBase').
-}
type LoadImportFn = Text -> ImportBase -> IO (Either ImportError ImportData)

{- | The loader plus the trusted sources it applies, so the engine decides
document trust (for custom templates) with the same policy as the loader.
-}
data Importer = Importer
    { imLoad :: LoadImportFn
    , imTrusted :: TrustedSources
    }

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- | Preprocess with no trusted sources (only local documents are trusted).
preprocessYaml :: LoadImportFn -> YamlAst -> Text -> IO (Either PreprocessError PreprocessResult)
preprocessYaml = preprocessYamlWith noTrustedSources False

preprocessYaml11 :: LoadImportFn -> YamlAst -> Text -> IO (Either PreprocessError PreprocessResult)
preprocessYaml11 = preprocessYamlWith noTrustedSources True

{- | Preprocess with the trusted sources the loader applies (see
"Iidy.Yaml.Imports.Loaders.Dispatch", whose helper passes both from one
policy) and the YAML 1.1 compatibility flag.
-}
preprocessYamlWith ::
    TrustedSources -> Bool -> LoadImportFn -> YamlAst -> Text -> IO (Either PreprocessError PreprocessResult)
preprocessYamlWith trusted yaml11Compat loader ast baseLocation =
    process (Importer{imLoad = loader, imTrusted = trusted}) ast baseLocation yaml11Compat

------------------------------------------------------------------------
-- Main processing pipeline
------------------------------------------------------------------------

process :: Importer -> YamlAst -> Text -> Bool -> IO (Either PreprocessError PreprocessResult)
process importer ast baseLocation yaml11Compat = do
    case pushImport baseLocation emptyStack of
        Left err -> pure $ Left $ pushErrorToPreprocess err
        Right stack' -> do
            -- Phase 1: Load imports and build environment
            result <- loadImportsAndDefs importer ast (rootBase baseLocation) Map.empty Map.empty emptyManifest stack'
            case result of
                Left err -> pure $ Left err
                Right (env, templateDefs, manifest, _stack'') -> do
                    -- Phase 2: Build context and resolve
                    let ctx =
                            emptyContext
                                { tcVariables = env
                                , tcInputUri = Just baseLocation
                                , tcCustomTemplateDefs = templateDefs
                                }
                    case resolveAst ctx ast of
                        Left reErr -> pure $ Left $ PeResolveError reErr
                        Right resolved -> do
                            let final =
                                    if yaml11Compat
                                        then convertYaml11CompatO resolved
                                        else resolved
                            pure $
                                Right $
                                    PreprocessResult
                                        { prValue = final
                                        , prImportRecords = manifest
                                        }

-- | A refused import: a cycle, or one of the import limits.
pushErrorToPreprocess :: PushError -> PreprocessError
pushErrorToPreprocess = \case
    ImportCycle msg -> PeCycleError msg
    ImportLimit msg -> PeImportError (ImportError msg)

------------------------------------------------------------------------
-- Phase 1: Load imports and definitions
------------------------------------------------------------------------

loadImportsAndDefs ::
    Importer ->
    YamlAst ->
    ImportBase ->
    Map Text OValue ->
    Map Text TemplateInfo ->
    ImportManifest ->
    ImportStack ->
    IO (Either PreprocessError (Map Text OValue, Map Text TemplateInfo, ImportManifest, ImportStack))
loadImportsAndDefs importer ast base env0 tmplDefs0 manifest0 stack0 =
    case ast of
        AstMapping pairs _ -> do
            let defsAst = findSectionPairs "$defs" pairs
                importsAst = findSectionPairs "$imports" pairs
            -- Process $defs
            case processDefs env0 defsAst (ibLocation base) of
                Left err -> pure $ Left err
                Right env1 ->
                    processImports importer env1 tmplDefs0 manifest0 stack0 importsAst base
        _nonMapping -> pure $ Right (env0, tmplDefs0, manifest0, stack0)

findSectionPairs :: Text -> [(YamlAst, YamlAst)] -> [(YamlAst, YamlAst)]
findSectionPairs name pairs =
    case filter (isKeyNamed name . fst) pairs of
        [(_, AstMapping subPairs _)] -> subPairs
        _notSingleMapping -> []
  where
    isKeyNamed n (AstPlainString s _) = s == n
    isKeyNamed _name _other = False

------------------------------------------------------------------------
-- Process $defs (sequential let* semantics)
------------------------------------------------------------------------

processDefs :: Map Text OValue -> [(YamlAst, YamlAst)] -> Text -> Either PreprocessError (Map Text OValue)
processDefs env0 defs _baseLocation = foldM processOneDef env0 defs
  where
    processOneDef env (keyAst, valAst) =
        let keyText = extractKeyText keyAst
            ctx =
                emptyContext
                    { tcVariables = env
                    , tcInputUri = Nothing
                    }
         in case resolveAst ctx valAst of
                Left reErr -> Left (PeResolveError reErr)
                Right resolved -> Right (Map.insert keyText resolved env)

------------------------------------------------------------------------
-- Process $imports
------------------------------------------------------------------------

processImports ::
    Importer ->
    Map Text OValue ->
    Map Text TemplateInfo ->
    ImportManifest ->
    ImportStack ->
    [(YamlAst, YamlAst)] ->
    ImportBase ->
    IO (Either PreprocessError (Map Text OValue, Map Text TemplateInfo, ImportManifest, ImportStack))
processImports _importer env tmplDefs manifest stack [] _base =
    pure $ Right (env, tmplDefs, manifest, stack)
processImports importer env tmplDefs manifest stack ((keyAst, locAst) : rest) base = do
    let importKey = extractKeyText keyAst
        locationText = extractKeyText locAst
    -- Interpolate handlebars in import location
    case interpolateLocation env locationText of
        Left err -> pure $ Left $ PeHandlebarsError err
        Right resolvedLoc -> do
            -- Cycle detection: push import location onto stack
            case pushImport resolvedLoc stack of
                Left pushErr -> pure $ Left $ pushErrorToPreprocess pushErr
                Right stack' -> do
                    result <- imLoad importer resolvedLoc base
                    case result of
                        Left err -> pure $ Left $ PeImportError err
                        Right importData -> do
                            -- Check for $params and store as template def if found
                            let tmplDefs' = case idDoc importData of
                                    Object obj | Just paramsVal <- KM.lookup "$params" obj ->
                                        case parseParams paramsVal of
                                            Right params ->
                                                Map.insert
                                                    importKey
                                                    TemplateInfo
                                                        { tiParams = params
                                                        , tiRawBody = idRawData importData
                                                        , tiLocation = idLocation importData
                                                        , tiInheritsParentVars =
                                                            isTrustedRequester (imTrusted importer) (childBase base (idLocation importData))
                                                        }
                                                    tmplDefs
                                            Left _err -> tmplDefs -- Skip malformed $params
                                    _noParams -> tmplDefs
                            -- Record import in manifest for auditing
                            let record =
                                    ImportRecord
                                        { irKey = Just importKey
                                        , irFrom = ibLocation base
                                        , irImported = idLocation importData
                                        , irSha256Digest = computeSha256 (idRawData importData)
                                        }
                                manifest' = addRecord record manifest
                            -- Recursively preprocess if imported doc has $imports or $defs
                            importResult <- processImportedDoc importer (idDoc importData) (idRawData importData) (childBase base (idLocation importData)) manifest' stack'
                            case importResult of
                                Left err -> pure $ Left err
                                Right (importedValue, manifest'', stack'') -> do
                                    let env' = Map.insert importKey importedValue env
                                    let stackFinal = popImport stack''
                                    processImports importer env' tmplDefs' manifest'' stackFinal rest base

------------------------------------------------------------------------
-- Recursive import preprocessing
------------------------------------------------------------------------

{- | Recursively preprocess an imported document if it contains $imports or $defs.
The document starts from an empty environment: it sees only its own
@$defs@ and @$imports@, never the importing document's variables, so its
import locations cannot interpolate the parent's values either. Matches
Rust's process_imported_document (engine.rs:380-442, fresh
@EnvValues::new()@ at :409). Its own imports are requested with
'childBase', which records the documents that led to it, so the
dispatcher can tell whether the requester chain is trusted.
-}
processImportedDoc ::
    Importer ->
    Value ->
    Text ->
    ImportBase ->
    ImportManifest ->
    ImportStack ->
    IO (Either PreprocessError (OValue, ImportManifest, ImportStack))
processImportedDoc importer doc rawData docBase manifest stack =
    case doc of
        Object obj
            | hasImportsOrDefs obj -> do
                -- Re-parse to AST and recursively preprocess
                case parseYaml (BL.fromStrict (TE.encodeUtf8 rawData)) (ibLocation docBase) of
                    Left _parseErr ->
                        -- If re-parse fails, fall back to raw value
                        pure $ Right (fromValue doc, manifest, stack)
                    Right ast -> do
                        result <- loadImportsAndDefs importer ast docBase Map.empty Map.empty manifest stack
                        case result of
                            Left err -> pure $ Left err
                            Right (docEnv, _docTmplDefs, manifest', stack') -> do
                                -- Resolve AST with the document's own environment
                                let ctx =
                                        emptyContext
                                            { tcVariables = docEnv
                                            , tcInputUri = Just (ibLocation docBase)
                                            }
                                case resolveAst ctx ast of
                                    Left reErr -> pure $ Left $ PeResolveError reErr
                                    Right resolved -> pure $ Right (resolved, manifest', stack')
        _nonObject -> pure $ Right (fromValue doc, manifest, stack)

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
isBooleanLike s =
    s
        `elem` [ "true"
               , "false"
               , "yes"
               , "no"
               , "on"
               , "off"
               , "True"
               , "False"
               , "Yes"
               , "No"
               , "On"
               , "Off"
               , "TRUE"
               , "FALSE"
               , "YES"
               , "NO"
               , "ON"
               , "OFF"
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
    _other -> ""

-- | Compute SHA256 hex digest of text content.
computeSha256 :: Text -> Text
computeSha256 t =
    let digest = hashWith SHA256 (TE.encodeUtf8 t)
        bytes = BA.convert digest :: BS.ByteString
     in T.pack (concatMap toHexLower (BS.unpack bytes))
  where
    toHexLower b = [hexDigit (b `div` 16), hexDigit (b `mod` 16)]
    hexDigit :: Word8 -> Char
    hexDigit n
        | n < 10 = toEnum (fromEnum '0' + fromIntegral n)
        | otherwise = toEnum (fromEnum 'a' + fromIntegral n - 10)
