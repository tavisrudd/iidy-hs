module Iidy.Yaml.Imports.Types (
    ImportType (..),
    ImportData (..),
    ImportRecord (..),
    ImportLoader (..),
    ImportError (..),
    RemoteImports (..),
    parseImportType,
) where

import Data.Aeson (Value)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import Data.Text qualified as T

import Iidy.Yaml.OValue (OValue)

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
    { idType :: !ImportType
    , idLocation :: !Text
    , idRawData :: !Text
    , idDoc :: !Value
    , idOrdered :: Maybe OValue
    {- ^ The document with mapping keys in source order, when the loader parsed
    it from YAML or JSON text. Only unqueried YAML output of get-import reads
    it; 'Nothing' means use 'idDoc'. Lazy, so an unqueried
    import pays nothing for it unless it is read.
    -}
    }
    deriving stock (Show, Eq)

data ImportRecord = ImportRecord
    { irKey :: !(Maybe Text)
    , irFrom :: !Text
    , irImported :: !Text
    , irSha256Digest :: !Text
    }
    deriving stock (Show, Eq)

newtype ImportError = ImportError Text
    deriving stock (Show, Eq)

-- | Whether remote (HTTP\/S3) imports are permitted.
data RemoteImports = AllowRemoteImports | BlockRemoteImports
    deriving stock (Show, Eq)

class ImportLoader m where
    loadImport :: Text -> Text -> m (Either ImportError ImportData)

------------------------------------------------------------------------
-- Import type parsing with security model
------------------------------------------------------------------------

parseImportType :: Text -> Text -> Either ImportError ImportType
parseImportType location baseLocation = do
    (typeStr, _rest) <- parseTypePrefix location
    importType <- case typeStr of
        "file" -> Right ImportFile
        "env" -> Right ImportEnv
        "git" -> Right ImportGit
        "random" -> Right ImportRandom
        "filehash" -> Right ImportFilehash
        "filehash-base64" -> Right ImportFilehashBase64
        "cfn" -> Right ImportCfn
        "ssm" -> Right ImportSsm
        "ssm-path" -> Right ImportSsmPath
        "s3" -> Right ImportS3
        "http" -> Right ImportHttp
        "https" -> Right ImportHttp
        "" -> Right ImportFile -- default: plain file path
        other -> Left $ ImportError $ "Unknown import type: " <> other
    if not (isLocalBase baseLocation) && isLocalOnly importType
        then
            Left $
                ImportError $
                    "Import type " <> typeStr <> " is not allowed from remote templates"
        else Right importType

{- | Parse an import type prefix from a location string.
Returns @Right ("", loc)@ for plain file paths (no colon or relative/absolute paths).
Returns @Right (prefix, rest)@ for known prefixes.
Returns @Left ImportError@ for unknown prefixes (e.g. "bogus:x").
-}
parseTypePrefix :: Text -> Either ImportError (Text, Text)
parseTypePrefix loc
    | T.isPrefixOf "./" loc || T.isPrefixOf "../" loc || T.isPrefixOf "/" loc =
        Right ("file", loc)
    | otherwise = case T.breakOn ":" loc of
        (prefix, rest)
            | T.null rest -> Right ("", loc)
            | prefix `elem` knownTypes -> Right (prefix, T.drop 1 rest)
            | otherwise ->
                Left $
                    ImportError $
                        "Unknown import type '" <> prefix <> "' in " <> loc
  where
    knownTypes :: [Text]
    knownTypes =
        [ "file"
        , "env"
        , "git"
        , "random"
        , "filehash"
        , "filehash-base64"
        , "cfn"
        , "ssm"
        , "ssm-path"
        , "s3"
        , "http"
        , "https"
        ]

{- | Whether a parent document's base location is positively a local file:
a plain path, @./@, @../@, @/@ or @file:@, or a path whose text before its
first colon is not URI-scheme shaped (such as @dir/./c:d.yaml@), which only
a local path can produce. The trust gate fails closed: every other base
(@s3:@ in either form, @ssm:@, @ssm-path:@, @cfn:@, @http(s):@ and any
unknown scheme-shaped prefix, including @a:b.yaml@) is untrusted and may
not use the local-only import types.
-}
isLocalBase :: Text -> Bool
isLocalBase loc = case parseTypePrefix loc of
    Right (prefix, _rest) -> prefix == "" || prefix == "file"
    Left _unknownPrefix -> not (isUriScheme (T.takeWhile (/= ':') loc))

-- | RFC 3986 scheme syntax: @ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )@.
isUriScheme :: Text -> Bool
isUriScheme t = case T.uncons t of
    Just (c, rest) -> isAsciiAlpha c && T.all isSchemeChar rest
    Nothing -> False
  where
    isAsciiAlpha :: Char -> Bool
    isAsciiAlpha ch = isAsciiLower ch || isAsciiUpper ch
    isSchemeChar :: Char -> Bool
    isSchemeChar ch = isAsciiAlpha ch || isDigit ch || ch `elem` ("+-." :: String)

isLocalOnly :: ImportType -> Bool
isLocalOnly = \case
    ImportFile -> True
    ImportEnv -> True
    ImportGit -> True
    ImportFilehash -> True
    ImportFilehashBase64 -> True
    _remoteType -> False
