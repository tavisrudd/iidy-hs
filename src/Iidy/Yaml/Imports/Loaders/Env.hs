module Iidy.Yaml.Imports.Loaders.Env (
    loadEnvImport,
) where

import Data.Aeson (Value (..))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Iidy.Yaml.Imports.Types (ImportData (..), ImportError (..), ImportType (..))
import System.Environment (lookupEnv)

{- | Load an environment variable import.
Format: env:VAR_NAME or env:VAR_NAME:default_value
-}
loadEnvImport :: Text -> IO (Either ImportError ImportData)
loadEnvImport location = do
    let stripped = fromMaybe location (T.stripPrefix "env:" location)
        (varName, defaultVal) = parseEnvSpec stripped
    result <- lookupEnv (T.unpack varName)
    case result of
        Just val -> pure $ Right $ mkImportData location (T.pack val)
        Nothing -> case defaultVal of
            Just def -> pure $ Right $ mkImportData location def
            Nothing ->
                pure $
                    Left $
                        ImportError $
                            "Environment variable not found: " <> varName

parseEnvSpec :: Text -> (Text, Maybe Text)
parseEnvSpec spec =
    case T.breakOn ":" spec of
        (name, rest)
            | T.null rest -> (name, Nothing)
            | otherwise -> (name, Just (T.drop 1 rest))

mkImportData :: Text -> Text -> ImportData
mkImportData loc val =
    ImportData
        { idType = ImportEnv
        , idLocation = loc
        , idRawData = val
        , idDoc = String val
        }
