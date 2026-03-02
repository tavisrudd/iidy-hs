-- | Get-import command: retrieve and display data from any import location.
module Iidy.GetImport
  ( runGetImport
  ) where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import System.IO (hPutStrLn, stderr)

import Iidy.Cli (GetImportArgs(..))
import Iidy.Output.Types (OutputData(..))
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher)
import Iidy.Yaml.Imports.Types (ImportData(..), ImportError(..))
import Iidy.Yaml.OValue (fromValue)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- | Run the get-import command.
-- Loads an import, optionally applies a JMESPath query, and formats output.
-- The emitter callback is used to send output through the output pipeline.
runGetImport :: (OutputData -> IO ()) -> GetImportArgs -> IO Int
runGetImport emit args = do
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
          emit (OdRawOutput (lazyBsToText (Aeson.encode doc) <> "\n"))
          pure 0
        "yaml" -> do
          emit (OdRawOutput (emitYaml (fromValue doc)))
          pure 0
        _ -> do
          -- "raw" or any other format: print raw data
          emit (OdRawOutput (idRawData importData <> "\n"))
          pure 0

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Decode a lazy ByteString (UTF-8 encoded) to strict Text.
lazyBsToText :: BL.ByteString -> Text
lazyBsToText = TL.toStrict . TLE.decodeUtf8
