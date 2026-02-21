module Iidy.Yaml.Imports.Loaders.File
  ( loadFileImport
  ) where

import Control.Exception (IOException, try)
import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.FilePath (takeExtension, takeDirectory, (</>))
import Iidy.Yaml.Imports.Types (ImportData(..), ImportType(..), ImportError(..))

loadFileImport :: Text -> Text -> IO (Either ImportError ImportData)
loadFileImport location baseLocation = do
  let rawPath = stripFilePrefix location
      basePath = T.unpack (stripFilePrefix baseLocation)
      baseDir = takeDirectory basePath
      fullPath = if isAbsolutePath rawPath
                 then T.unpack rawPath
                 else baseDir </> T.unpack rawPath
  result <- try @IOException (BS.readFile fullPath)
  case result of
    Left err -> pure $ Left $ ImportError $ "Failed to read file: " <> T.pack (show err)
    Right bs -> case TE.decodeUtf8' bs of
      Left err -> pure $ Left $ ImportError $ "Invalid UTF-8 in file: " <> T.pack (show err)
      Right content -> do
        let ext = takeExtension fullPath
            doc = parseByExtension ext content
        pure $ Right $ ImportData
          { idType     = ImportFile
          , idLocation = T.pack fullPath
          , idRawData  = content
          , idDoc      = doc
          }

stripFilePrefix :: Text -> Text
stripFilePrefix loc = maybe loc id (T.stripPrefix "file:" loc)

isAbsolutePath :: Text -> Bool
isAbsolutePath t = T.isPrefixOf "/" t

parseByExtension :: String -> Text -> Value
parseByExtension ext content
  | ext `elem` [".yaml", ".yml"] = parseJson content  -- HsYAML produces JSON-compatible Values via aeson
  | ext == ".json" = parseJson content
  | otherwise = String content

parseJson :: Text -> Value
parseJson content =
  case Aeson.eitherDecodeStrict' (TE.encodeUtf8 content) of
    Right val -> val
    Left _ -> String content
