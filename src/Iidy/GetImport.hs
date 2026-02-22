-- | Get-import command: retrieve and display data from any import location.
module Iidy.GetImport
  ( runGetImport
  ) where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as BL8
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.IO (hPutStrLn, stderr)

import Iidy.Cli (GetImportArgs(..))
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.Imports.Loaders.Env (loadEnvImport)
import Iidy.Yaml.Imports.Types (ImportData(..), ImportError(..), parseImportType, ImportType(..))
import Iidy.Yaml.OValue (fromValue)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- | Run the get-import command.
-- Loads an import, optionally applies a JMESPath query, and formats output.
runGetImport :: GetImportArgs -> IO Int
runGetImport args = do
  let location = giaImport args
      baseLocation = "."

  -- Determine import type
  case parseImportType location baseLocation of
    Left (ImportError err) -> do
      hPutStrLn stderr $ "Import error: " <> T.unpack err
      pure 1
    Right importType -> do
      -- Load the import
      result <- loadImportByType importType location baseLocation
      case result of
        Left (ImportError err) -> do
          hPutStrLn stderr $ "Import error: " <> T.unpack err
          pure 1
        Right importData -> do
          let doc = idDoc importData
          -- Format output
          case T.toLower (giaFormat args) of
            "json" -> do
              BL8.putStrLn (Aeson.encode doc)
              pure 0
            "yaml" -> do
              TIO.putStr (emitYaml (fromValue doc))
              pure 0
            _ -> do
              -- "raw" or any other format: print raw data
              TIO.putStrLn (idRawData importData)
              pure 0

------------------------------------------------------------------------
-- Import dispatch
------------------------------------------------------------------------

-- | Dispatch to the appropriate loader based on import type.
-- Non-AWS loaders are handled directly; AWS loaders require env setup.
loadImportByType :: ImportType -> Text -> Text -> IO (Either ImportError ImportData)
loadImportByType ImportFile location base = loadFileImport location base
loadImportByType ImportEnv location _base = loadEnvImport location
loadImportByType other _location _base =
  pure $ Left $ ImportError $
    "Import type '" <> T.pack (show other) <> "' requires AWS credentials. "
    <> "Use the full render command for AWS-backed imports."
