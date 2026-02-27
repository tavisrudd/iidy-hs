-- | Get-import command: retrieve and display data from any import location.
module Iidy.GetImport
  ( runGetImport
  ) where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as BL8
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.IO (hPutStrLn, stderr)

import Iidy.Cli (GetImportArgs(..))
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher)
import Iidy.Yaml.Imports.Types (ImportData(..), ImportError(..))
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
      dispatcher = mkFullDispatcher Nothing

  result <- dispatcher location baseLocation
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
