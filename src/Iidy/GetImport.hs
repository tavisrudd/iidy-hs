-- | Get-import command: retrieve and display data from any import location.
module Iidy.GetImport (
    runGetImport,
) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import System.IO (hPutStrLn, stderr)

import Iidy.Cli (GetImportArgs (..), GlobalOpts (..), RenderFormat (..))
import Iidy.Output.Types (OutputData (..))
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig (..), mkFullDispatcher)
import Iidy.Yaml.Imports.Types (ImportData (..), ImportError (..), RemoteImports (..))
import Iidy.Yaml.OValue (fromValue)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

{- | Run the get-import command.
Loads an import, optionally applies a JMESPath query, and formats output.
The emitter callback is used to send output through the output pipeline.
-}
runGetImport :: (OutputData -> IO ()) -> GetImportArgs -> GlobalOpts -> IO Int
runGetImport emit args gopts = do
    let location = giaImport args
        baseLocation = "."
        importCfg =
            ImportConfig
                { icAwsEnv = Nothing
                , icRemoteImports = if goRemoteImports gopts then AllowRemoteImports else BlockRemoteImports
                }
        dispatcher = mkFullDispatcher importCfg

    result <- dispatcher location baseLocation
    case result of
        Left (ImportError err) -> do
            hPutStrLn stderr $ "Import error: " <> T.unpack err
            pure 1
        Right importData -> do
            let doc = idDoc importData
            -- Format output (exhaustive match — no wildcard)
            case giaFormat args of
                RenderJson -> do
                    emit (OdRawOutput (lazyBsToText (Aeson.encode doc) <> "\n"))
                    pure 0
                RenderYaml -> do
                    emit (OdRawOutput (emitYaml (fromValue doc)))
                    pure 0
                RenderCfnYaml -> do
                    emit (OdRawOutput (emitYaml (fromValue doc)))
                    pure 0

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Decode a lazy ByteString (UTF-8 encoded) to strict Text.
lazyBsToText :: BL.ByteString -> Text
lazyBsToText = TL.toStrict . TLE.decodeUtf8
