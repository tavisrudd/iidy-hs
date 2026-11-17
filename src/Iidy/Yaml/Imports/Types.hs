module Iidy.Yaml.Imports.Types (
    ImportType (..),
    ImportData (..),
    ImportRecord (..),
    ImportLoader (..),
    ImportError (..),
    RemoteImports (..),
    ImportPolicy (..),
    importPolicy,
    TrustedSource,
    trustedSourceText,
    TrustedSources,
    noTrustedSources,
    mkTrustedSources,
    trustedSourceList,
    parseTrustedSource,
    isTrustedBase,
    ImportBase (..),
    rootBase,
    childBase,
    isTrustedRequester,
    isAwsBacked,
    needsAwsEnv,
    checkImport,
    parseImportType,
) where

import Data.Aeson (Value)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List qualified as List
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

{- | What imports a run permits: whether remote (HTTP\/S3) imports are
allowed at all, and which remote locations are trusted like local files.
-}
data ImportPolicy = ImportPolicy
    { ipRemoteImports :: !RemoteImports
    , ipTrustedSources :: !TrustedSources
    }
    deriving stock (Show, Eq)

-- | A policy with no trusted sources.
importPolicy :: RemoteImports -> ImportPolicy
importPolicy ri = ImportPolicy{ipRemoteImports = ri, ipTrustedSources = noTrustedSources}

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

{- | Whether an import type is read with the user's AWS credentials
(@cfn:@, @ssm:@, @ssm-path:@ and both @s3:@ forms).
-}
isAwsBacked :: ImportType -> Bool
isAwsBacked = \case
    ImportCfn -> True
    ImportSsm -> True
    ImportSsmPath -> True
    ImportS3 -> True
    ImportFile -> False
    ImportEnv -> False
    ImportGit -> False
    ImportRandom -> False
    ImportFilehash -> False
    ImportFilehashBase64 -> False
    ImportHttp -> False

{- | Whether loading an import of this type needs an AWS environment.
S3 imports are excluded when remote imports are blocked, so the user sees
the --no-remote-imports error rather than a credentials error.
-}
needsAwsEnv :: RemoteImports -> ImportType -> Bool
needsAwsEnv remoteImports ty =
    isAwsBacked ty && (ty /= ImportS3 || remoteImports == AllowRemoteImports)

{- | The import gate: 'parseImportType' (local-only types need a local
base) plus the AWS-backed check: a requesting document that is not trusted
('isTrustedRequester') may not import @cfn:@, @ssm:@, @ssm-path:@ or @s3:@.
-}
checkImport :: TrustedSources -> Text -> ImportBase -> Either ImportError ImportType
checkImport trusted location base = do
    importType <- parseImportType location (ibLocation base)
    case untrustedLink trusted base of
        Just untrusted | isAwsBacked importType -> Left (ImportError (refusal untrusted))
        _trustedOrNotAws -> Right importType
  where
    refusal :: Text -> Text
    refusal untrusted =
        "Import type "
            <> T.takeWhile (/= ':') location
            <> " is not allowed from remote templates: "
            <> ( if untrusted == ibLocation base
                    then ibLocation base
                    else ibLocation base <> " was requested through " <> untrusted <> ", which"
               )
            <> " is not a trusted source (to allow it, pass --trust-import-source"
            <> " with a prefix of that location)"

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

------------------------------------------------------------------------
-- Requesting documents
------------------------------------------------------------------------

{- | The document an import is requested from: its location (the base
that relative imports resolve against) and the locations of the documents
that led to it, nearest first, ending at the root template.
-}
data ImportBase = ImportBase
    { ibLocation :: !Text
    , ibRequesters :: ![Text]
    }
    deriving stock (Show, Eq)

-- | The base of a root document (a template or argsfile given directly).
rootBase :: Text -> ImportBase
rootBase loc = ImportBase{ibLocation = loc, ibRequesters = []}

-- | The base of a document loaded at @loc@ by a request from @parent@.
childBase :: ImportBase -> Text -> ImportBase
childBase parent loc = ImportBase{ibLocation = loc, ibRequesters = ibLocation parent : ibRequesters parent}

{- | Whether a requesting document is trusted: its own location and every
document that led to it are trusted ('isTrustedBase'). Trust cannot be
gained through the import chain, so a document under a trusted prefix
that an untrusted document requested is itself untrusted.
-}
isTrustedRequester :: TrustedSources -> ImportBase -> Bool
isTrustedRequester trusted = null . untrustedLink trusted

-- | The nearest untrusted location in a requester chain, if any.
untrustedLink :: TrustedSources -> ImportBase -> Maybe Text
untrustedLink trusted base = List.find (not . isTrustedBase trusted) (ibLocation base : ibRequesters base)

------------------------------------------------------------------------
-- Trusted sources
------------------------------------------------------------------------

-- | A remote location prefix validated by 'parseTrustedSource'.
newtype TrustedSource = TrustedSource Text
    deriving stock (Show, Eq)

trustedSourceText :: TrustedSource -> Text
trustedSourceText (TrustedSource t) = t

-- | The remote prefixes whose documents are trusted like local files.
newtype TrustedSources = TrustedSources [TrustedSource]
    deriving stock (Show, Eq)

noTrustedSources :: TrustedSources
noTrustedSources = TrustedSources []

mkTrustedSources :: [TrustedSource] -> TrustedSources
mkTrustedSources = TrustedSources

trustedSourceList :: TrustedSources -> [TrustedSource]
trustedSourceList (TrustedSources ts) = ts

{- | Validate a trusted-source prefix. It must start with a remote scheme
(@s3://@, @s3:@, @http://@, @https://@, @ssm:@, @ssm-path:@ or @cfn:@,
lower case), end in @/@, name a bucket or host for the S3 and HTTP forms,
and contain no @.@ or @..@ path segment. Matching is a literal,
case-sensitive text prefix, so @s3:b/@ and @s3://b/@ are listed
separately.
-}
parseTrustedSource :: Text -> Either Text TrustedSource
parseTrustedSource p
    | not (any (`T.isPrefixOf` p) remoteSchemes) =
        bad ("must start with one of " <> T.intercalate ", " remoteSchemes)
    | not ("/" `T.isSuffixOf` p) = bad "must end in /"
    | not namesAuthority = bad "must name a bucket or host"
    | any isDotSegment (T.splitOn "/" p) = bad "must not contain . or .. path segments"
    | otherwise = Right (TrustedSource p)
  where
    bad :: Text -> Either Text TrustedSource
    bad why = Left ("invalid trusted import source '" <> p <> "': " <> why)
    namesAuthority :: Bool
    namesAuthority = case List.find (`T.isPrefixOf` p) authoritySchemes of
        Just scheme -> not (T.null (T.takeWhile (/= '/') (T.drop (T.length scheme) p)))
        Nothing -> True

-- | Schemes a trusted-source prefix may use. Longer spellings come first.
remoteSchemes :: [Text]
remoteSchemes = authoritySchemes <> ["ssm-path:", "ssm:", "cfn:"]

-- | Schemes whose prefix must name a bucket or host before the first @/@.
authoritySchemes :: [Text]
authoritySchemes = ["s3://", "http://", "https://", "s3:"]

{- | A path segment that may climb out of the prefix: @.@ or @..@, also
when percent-encoded.
-}
isDotSegment :: Text -> Bool
isDotSegment seg = T.replace "%2e" "." (T.toLower seg) `elem` [".", ".."]

{- | The one trust decision: a document's base is trusted when it is a
local file ('isLocalBase') or lies under a listed trusted-source prefix.
A location under a prefix whose remainder has a @.@ or @..@ segment is
not trusted, since it may resolve outside the prefix.
-}
isTrustedBase :: TrustedSources -> Text -> Bool
isTrustedBase (TrustedSources ts) loc = isLocalBase loc || any under ts
  where
    under :: TrustedSource -> Bool
    under (TrustedSource p) = case T.stripPrefix p loc of
        Just rest -> not (any isDotSegment (T.splitOn "/" rest))
        Nothing -> False
