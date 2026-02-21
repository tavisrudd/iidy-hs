module Iidy.Yaml.Imports.Types
  ( ImportType(..)
  , ImportData(..)
  , ImportRecord(..)
  , ImportLoader(..)
  , ImportError(..)
  , parseImportType
  ) where

import Data.Aeson (Value)
import Data.Text (Text)
import qualified Data.Text as T

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

data ImportType
  = ImportFile
  | ImportEnv
  | ImportGit
  | ImportRandom
  | ImportFilehash
  | ImportFilehashBase64
  | ImportCfn
  | ImportSsm
  | ImportSsmPath
  | ImportS3
  | ImportHttp
  deriving stock (Show, Eq, Ord)

data ImportData = ImportData
  { idType     :: !ImportType
  , idLocation :: !Text
  , idRawData  :: !Text
  , idDoc      :: !Value
  } deriving stock (Show, Eq)

data ImportRecord = ImportRecord
  { irKey          :: !(Maybe Text)
  , irFrom         :: !Text
  , irImported     :: !Text
  , irSha256Digest :: !Text
  } deriving stock (Show, Eq)

newtype ImportError = ImportError Text
  deriving stock (Show, Eq)

class ImportLoader m where
  loadImport :: Text -> Text -> m (Either ImportError ImportData)

------------------------------------------------------------------------
-- Import type parsing with security model
------------------------------------------------------------------------

parseImportType :: Text -> Text -> Either ImportError ImportType
parseImportType location baseLocation =
  let (typeStr, _rest) = parseTypePrefix location
      importType = case typeStr of
        "file"            -> Right ImportFile
        "env"             -> Right ImportEnv
        "git"             -> Right ImportGit
        "random"          -> Right ImportRandom
        "filehash"        -> Right ImportFilehash
        "filehash-base64" -> Right ImportFilehashBase64
        "cfn"             -> Right ImportCfn
        "ssm"             -> Right ImportSsm
        "ssm-path"        -> Right ImportSsmPath
        "s3"              -> Right ImportS3
        "http"            -> Right ImportHttp
        "https"           -> Right ImportHttp
        ""                -> Right ImportFile  -- default
        other             -> Left $ ImportError $ "Unknown import type: " <> other
  in case importType of
       Left e -> Left e
       Right it
         | isRemoteBase baseLocation && isLocalOnly it ->
             Left $ ImportError $
               "Import type " <> typeStr <> " is not allowed from remote templates"
         | otherwise -> Right it

parseTypePrefix :: Text -> (Text, Text)
parseTypePrefix loc
  | T.isPrefixOf "./" loc || T.isPrefixOf "../" loc || T.isPrefixOf "/" loc = ("file", loc)
  | otherwise = case T.breakOn ":" loc of
      (prefix, rest)
        | T.null rest -> ("", loc)
        | prefix `elem` knownTypes -> (prefix, T.drop 1 rest)
        | otherwise -> ("", loc)  -- treat as file path
  where
    knownTypes :: [Text]
    knownTypes = ["file", "env", "git", "random", "filehash", "filehash-base64",
                  "cfn", "ssm", "ssm-path", "s3", "http", "https"]

isRemoteBase :: Text -> Bool
isRemoteBase loc =
  T.isPrefixOf "s3://" loc
  || T.isPrefixOf "http://" loc
  || T.isPrefixOf "https://" loc

isLocalOnly :: ImportType -> Bool
isLocalOnly = \case
  ImportFile          -> True
  ImportEnv           -> True
  ImportGit           -> True
  ImportFilehash      -> True
  ImportFilehashBase64 -> True
  _                   -> False
