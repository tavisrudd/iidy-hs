{-# LANGUAGE OverloadedRecordDot #-}
-- | SSM Parameter Store client operations.
--
-- Implements get, set, get-by-path, and get-history operations against
-- AWS SSM Parameter Store. All operations use an existing amazonka Env
-- and return Either Text results for uniform error handling.
--
-- Supports @--format simple|json|yaml@ for get, get-by-path, and get-history.
module Iidy.Params.Client
  ( -- * Parameter operations
    fetchParam
  , paramGet
  , paramSet
  , paramGetByPath
  , paramGetHistory
  , GetByPathResult(..)
    -- * Output types (exported for testing)
  , ParamOutput(..)
  , ParamHistoryOutput(..)
  , SimpleHistory(..)
  , SimpleHistoryCurrent(..)
  , SimpleHistoryPrevious(..)
  , FullHistory(..)
    -- * Pure helpers (exported for testing)
  , paramTypeToSsm
  , formatParam
  , formatHistoryEntry
  , paramOutputFromParameter
  , paramHistoryOutputFromHistory
  , formatAsJson
  , formatAsYaml
  , messageTag
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Aeson (ToJSON(..), Value(..), (.=), object)
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Conduit (runConduit, (.|))
import qualified Data.Conduit.List as CL
import qualified Data.ByteString.Lazy as LBS
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Lens.Micro ((^.))

import qualified Amazonka
import qualified Amazonka.SSM as SSM
import qualified Amazonka.SSM.GetParameter as GP
import qualified Amazonka.SSM.PutParameter as PP
import qualified Amazonka.SSM.GetParametersByPath as GPBP
import qualified Amazonka.SSM.GetParameterHistory as GPH
import qualified Amazonka.SSM.ListTagsForResource as LTR
import qualified Amazonka.SSM.Types.Parameter as SSMP
import qualified Amazonka.SSM.Types.ParameterHistory as SSMPH
import qualified Amazonka.SSM.Types.ParameterType as SSMPT
import qualified Amazonka.SSM.Types.ResourceTypeForTagging as RTT
import qualified Amazonka.SSM.Types.Tag as SSMT

import Iidy.Cli
  ( ParamFormat(..), ParamGetArgs(..), ParamSetArgs(..)
  , ParamGetByPathArgs(..), ParamType(..)
  )

------------------------------------------------------------------------
-- Output data types
------------------------------------------------------------------------

-- | Tag key used by iidy to store change messages.
messageTag :: Text
messageTag = "iidy:message"

-- | Serializable representation of an SSM parameter for json/yaml output.
-- Field names use PascalCase matching Rust/AWS SDK conventions.
data ParamOutput = ParamOutput
  { poName             :: !(Maybe Text)
  , poType             :: !(Maybe Text)
  , poValue            :: !(Maybe Text)
  , poVersion          :: !(Maybe Integer)
  , poLastModifiedDate :: !(Maybe Text)
  , poArn              :: !(Maybe Text)
  , poDataType         :: !(Maybe Text)
  , poTags             :: !(Maybe (Map.Map Text Text))
  } deriving stock (Show, Eq)

instance ToJSON ParamOutput where
  toJSON po = object $ catMaybes
    [ fmap ("Name" .=) (poName po)
    , fmap ("Type" .=) (poType po)
    , fmap ("Value" .=) (poValue po)
    , fmap ("Version" .=) (poVersion po)
    , fmap ("LastModifiedDate" .=) (poLastModifiedDate po)
    , fmap ("ARN" .=) (poArn po)
    , fmap ("DataType" .=) (poDataType po)
    , fmap ("Tags" .=) (poTags po)
    ]

-- | Serializable representation of an SSM parameter history entry.
data ParamHistoryOutput = ParamHistoryOutput
  { phoName             :: !(Maybe Text)
  , phoType             :: !(Maybe Text)
  , phoKeyId            :: !(Maybe Text)
  , phoLastModifiedDate :: !(Maybe Text)
  , phoLastModifiedUser :: !(Maybe Text)
  , phoDescription      :: !(Maybe Text)
  , phoValue            :: !(Maybe Text)
  , phoVersion          :: !(Maybe Integer)
  , phoDataType         :: !(Maybe Text)
  , phoTags             :: !(Maybe (Map.Map Text Text))
  } deriving stock (Show, Eq)

instance ToJSON ParamHistoryOutput where
  toJSON pho = object $ catMaybes
    [ fmap ("Name" .=) (phoName pho)
    , fmap ("Type" .=) (phoType pho)
    , fmap ("KeyId" .=) (phoKeyId pho)
    , fmap ("LastModifiedDate" .=) (phoLastModifiedDate pho)
    , fmap ("LastModifiedUser" .=) (phoLastModifiedUser pho)
    , fmap ("Description" .=) (phoDescription pho)
    , fmap ("Value" .=) (phoValue pho)
    , fmap ("Version" .=) (phoVersion pho)
    , fmap ("DataType" .=) (phoDataType pho)
    , fmap ("Tags" .=) (phoTags pho)
    ]

-- | Simple (default) history format: current entry with message, plus previous entries.
data SimpleHistoryCurrent = SimpleHistoryCurrent
  { shcValue            :: !(Maybe Text)
  , shcLastModifiedDate :: !(Maybe Text)
  , shcLastModifiedUser :: !(Maybe Text)
  , shcMessage          :: !Text
  } deriving stock (Show, Eq)

instance ToJSON SimpleHistoryCurrent where
  toJSON shc = object $ catMaybes
    [ fmap ("Value" .=) (shcValue shc)
    , fmap ("LastModifiedDate" .=) (shcLastModifiedDate shc)
    , fmap ("LastModifiedUser" .=) (shcLastModifiedUser shc)
    , Just ("Message" .= shcMessage shc)
    ]

data SimpleHistoryPrevious = SimpleHistoryPrevious
  { shpValue            :: !(Maybe Text)
  , shpLastModifiedDate :: !(Maybe Text)
  , shpLastModifiedUser :: !(Maybe Text)
  } deriving stock (Show, Eq)

instance ToJSON SimpleHistoryPrevious where
  toJSON shp = object $ catMaybes
    [ fmap ("Value" .=) (shpValue shp)
    , fmap ("LastModifiedDate" .=) (shpLastModifiedDate shp)
    , fmap ("LastModifiedUser" .=) (shpLastModifiedUser shp)
    ]

data SimpleHistory = SimpleHistory
  { shCurrent  :: !SimpleHistoryCurrent
  , shPrevious :: ![SimpleHistoryPrevious]
  } deriving stock (Show, Eq)

instance ToJSON SimpleHistory where
  toJSON sh = object
    [ "Current"  .= shCurrent sh
    , "Previous" .= shPrevious sh
    ]

-- | Full history format for json/yaml: all fields, current entry gets tags.
data FullHistory = FullHistory
  { fhCurrent  :: !ParamHistoryOutput
  , fhPrevious :: ![ParamHistoryOutput]
  } deriving stock (Show, Eq)

instance ToJSON FullHistory where
  toJSON fh = object
    [ "Current"  .= fhCurrent fh
    , "Previous" .= fhPrevious fh
    ]

------------------------------------------------------------------------
-- Conversion helpers
------------------------------------------------------------------------

-- | Convert an amazonka Parameter to ParamOutput.
paramOutputFromParameter :: SSM.Parameter -> ParamOutput
paramOutputFromParameter p = ParamOutput
  { poName             = Just (p ^. SSMP.parameter_name)
  , poType             = Just (SSMPT.fromParameterType (p ^. SSMP.parameter_type))
  , poValue            = Just (p ^. SSMP.parameter_value)
  , poVersion          = Just (p ^. SSMP.parameter_version)
  , poLastModifiedDate = fmap formatUtcTime (p ^. SSMP.parameter_lastModifiedDate)
  , poArn              = p ^. SSMP.parameter_arn
  , poDataType         = p ^. SSMP.parameter_dataType
  , poTags             = Nothing
  }

-- | Convert an amazonka ParameterHistory to ParamHistoryOutput.
paramHistoryOutputFromHistory :: SSM.ParameterHistory -> ParamHistoryOutput
paramHistoryOutputFromHistory ph = ParamHistoryOutput
  { phoName             = ph ^. SSMPH.parameterHistory_name
  , phoType             = fmap SSMPT.fromParameterType (ph ^. SSMPH.parameterHistory_type)
  , phoKeyId            = ph ^. SSMPH.parameterHistory_keyId
  , phoLastModifiedDate = fmap formatUtcTime (ph ^. SSMPH.parameterHistory_lastModifiedDate)
  , phoLastModifiedUser = ph ^. SSMPH.parameterHistory_lastModifiedUser
  , phoDescription      = ph ^. SSMPH.parameterHistory_description
  , phoValue            = ph ^. SSMPH.parameterHistory_value
  , phoVersion          = ph ^. SSMPH.parameterHistory_version
  , phoDataType         = ph ^. SSMPH.parameterHistory_dataType
  , phoTags             = Nothing
  }

-- | Attach tags to a ParamOutput.
withParamTags :: Map.Map Text Text -> ParamOutput -> ParamOutput
withParamTags tags po = po { poTags = Just tags }

-- | Attach tags to a ParamHistoryOutput.
withHistoryTags :: Map.Map Text Text -> ParamHistoryOutput -> ParamHistoryOutput
withHistoryTags tags pho = pho { phoTags = Just tags }

-- | Format a UTCTime to ISO 8601 string.
formatUtcTime :: UTCTime -> Text
formatUtcTime = T.pack . iso8601Show

------------------------------------------------------------------------
-- Serialization helpers
------------------------------------------------------------------------

-- | Serialize a value as pretty-printed JSON text.
formatAsJson :: ToJSON a => a -> Text
formatAsJson = decodeUtf8 . LBS.toStrict . encodePretty

-- | Serialize a value as YAML text.
-- Uses a simple Aeson Value -> YAML conversion since the project
-- uses HsYAML (parser-only) and not the yaml package (which has encode).
formatAsYaml :: ToJSON a => a -> Text
formatAsYaml = valueToYaml . toJSON

-- | Convert an Aeson Value to YAML text.
-- Produces output compatible with serde_yaml (Rust).
valueToYaml :: Value -> Text
valueToYaml val = renderYaml 0 val <> "\n"

renderYaml :: Int -> Value -> Text
renderYaml _ Null          = "null"
renderYaml _ (Bool True)   = "true"
renderYaml _ (Bool False)  = "false"
renderYaml _ (Number n)    = T.pack (show n)
renderYaml _ (String s)    = yamlQuoteString s
renderYaml indent (Array arr)
  | null arr  = "[]"
  | otherwise =
      let items = foldMap (\v -> [renderYamlItem indent v]) arr
      in T.intercalate "\n" items
  where
    renderYamlItem i v =
      let prefix = T.replicate i " " <> "- "
      in case v of
        Object _ -> prefix <> renderYamlObject (i + 2) v True
        Array _  -> prefix <> renderYaml (i + 2) v
        _        -> prefix <> renderYaml 0 v
renderYaml indent (Object km)
  | KM.null km = "{}"
  | otherwise  = renderYamlObject indent (Object km) False

renderYamlObject :: Int -> Value -> Bool -> Text
renderYamlObject indent (Object km) isInline =
  let pairs = KM.toList km
      prefix = T.replicate indent " "
      renderPair isFirst (k, v) =
        let keyText = Key.toText k
            linePrefix = if isFirst && isInline then "" else prefix
        in case v of
          Object _ | not (KM.null (asObject v)) ->
            linePrefix <> keyText <> ":\n" <> renderYaml (indent + 2) v
          Array _ | not (null (asArray v)) ->
            linePrefix <> keyText <> ":\n" <> renderYaml (indent + 2) v
          _ ->
            linePrefix <> keyText <> ": " <> renderYaml 0 v
  in case pairs of
    []     -> "{}"
    (p:ps) -> T.intercalate "\n"
                (renderPair True p : map (renderPair False) ps)
renderYamlObject _ _ _ = "{}"

asObject :: Value -> KM.KeyMap Value
asObject (Object km) = km
asObject _           = KM.empty

asArray :: Value -> [Value]
asArray (Array a) = foldr (:) [] a
asArray _         = []

-- | Quote a YAML string if needed.
yamlQuoteString :: Text -> Text
yamlQuoteString s
  | T.null s                    = "''"
  | needsQuoting s              = "'" <> T.replace "'" "''" s <> "'"
  | otherwise                   = s
  where
    needsQuoting t =
      let c = T.head t
      in  c == '{' || c == '[' || c == '&' || c == '*'
       || c == '?' || c == '|' || c == '>' || c == '!'
       || c == '%' || c == '@' || c == '`' || c == '"' || c == '\''
       || c == '#' || c == ','
       || T.elem ':' t || T.elem '\n' t
       || t == "true" || t == "false" || t == "null"
       || t == "True" || t == "False" || t == "Null"
       || t == "yes" || t == "no" || t == "Yes" || t == "No"
       || t == "on" || t == "off" || t == "On" || t == "Off"
       || t == "~"

------------------------------------------------------------------------
-- ListTagsForResource
------------------------------------------------------------------------

-- | Fetch tags for an SSM parameter as a Map.
listParamTags :: Amazonka.Env -> Text -> IO (Either Text (Map.Map Text Text))
listParamTags awsEnv paramName = do
  result <- try @SomeException $ runResourceT $ do
    let req = LTR.newListTagsForResource
                RTT.ResourceTypeForTagging_Parameter
                paramName
    resp <- Amazonka.send awsEnv req
    let tags = fromMaybe [] resp.tagList
    pure $ Map.fromList
      [ (t ^. SSMT.tag_key, t ^. SSMT.tag_value) | t <- tags ]
  case result of
    Left ex   -> pure $ Left $ "ListTagsForResource error for " <> paramName <> ": " <> T.pack (show ex)
    Right m   -> pure (Right m)

------------------------------------------------------------------------
-- paramGet
------------------------------------------------------------------------

-- | Fetch a single SSM parameter value.
-- Returns Right value on success, Left error message on failure.
-- Exported for use in other modules (e.g. Review).
fetchParam :: Amazonka.Env -> Text -> Bool -> IO (Either Text Text)
fetchParam awsEnv paramName withDecryption = do
  result <- try @SomeException $ runResourceT $ do
    let req = (GP.newGetParameter paramName)
                { GP.withDecryption = Just withDecryption }
    resp <- Amazonka.send awsEnv req
    pure (resp.parameter ^. SSMP.parameter_value)
  case result of
    Left ex   -> pure (Left (T.pack (show ex)))
    Right val -> pure (Right val)

-- | Fetch a single SSM parameter (full Parameter object).
fetchParameter :: Amazonka.Env -> Text -> Bool -> IO (Either Text SSM.Parameter)
fetchParameter awsEnv paramName withDecryption = do
  result <- try @SomeException $ runResourceT $ do
    let req = (GP.newGetParameter paramName)
                { GP.withDecryption = Just withDecryption }
    resp <- Amazonka.send awsEnv req
    pure resp.parameter
  case result of
    Left ex -> pure $ Left $ T.pack (show ex)
    Right p -> pure (Right p)

-- | Get a single SSM parameter, formatted according to --format.
-- For simple: bare value. For json/yaml: full ParamOutput with tags.
paramGet :: Amazonka.Env -> ParamGetArgs -> IO (Either Text Text)
paramGet awsEnv args = case args.pgaFormat of
  ParamFormatRaw -> do
    result <- fetchParam awsEnv args.pgaPath args.pgaDecrypt
    case result of
      Left ex  -> pure $ Left $ "SSM GetParameter error for " <> args.pgaPath <> ": " <> ex
      Right val -> pure (Right val)
  fmt -> do
    result <- fetchParameter awsEnv args.pgaPath args.pgaDecrypt
    case result of
      Left ex -> pure $ Left $ "SSM GetParameter error for " <> args.pgaPath <> ": " <> ex
      Right param -> do
        tagsResult <- listParamTags awsEnv args.pgaPath
        case tagsResult of
          Left err -> pure (Left err)
          Right tags -> do
            let output = withParamTags tags (paramOutputFromParameter param)
            pure $ Right $ formatWith fmt output

------------------------------------------------------------------------
-- paramSet
------------------------------------------------------------------------

-- | Write a value to SSM Parameter Store.
-- Respects the overwrite flag and type from ParamSetArgs.
-- The type field maps to SSM ParameterType (String, SecureString, StringList).
paramSet :: Amazonka.Env -> ParamSetArgs -> IO (Either Text ())
paramSet awsEnv args = do
  result <- try @SomeException (putParam awsEnv args)
  case result of
    Left ex -> pure $ Left $ "SSM PutParameter error for " <> args.psaPath <> ": " <> T.pack (show ex)
    Right _  -> pure (Right ())

putParam :: Amazonka.Env -> ParamSetArgs -> IO ()
putParam awsEnv args = runResourceT $ do
  let req = (PP.newPutParameter args.psaPath args.psaValue)
              { PP.overwrite   = Just args.psaOverwrite
              , PP.type'       = Just (paramTypeToSsm args.psaType)
              , PP.description = args.psaMessage
              }
  _ <- Amazonka.send awsEnv req
  pure ()

-- | Convert a ParamType to the corresponding SSM ParameterType.
paramTypeToSsm :: ParamType -> SSM.ParameterType
paramTypeToSsm ParamString       = SSMPT.ParameterType_String
paramTypeToSsm ParamSecureString = SSMPT.ParameterType_SecureString
paramTypeToSsm ParamStringList   = SSMPT.ParameterType_StringList

------------------------------------------------------------------------
-- paramGetByPath
------------------------------------------------------------------------

-- | Result type for paramGetByPath: either formatted text or exit code 1 signal.
data GetByPathResult
  = ByPathOutput !Text    -- ^ Formatted output to print
  | ByPathEmpty           -- ^ No parameters found (exit code 1)

-- | Fetch all parameters under a path prefix, formatted according to --format.
-- Returns Right (Just text) for output, Right Nothing for "no params" (exit 1),
-- or Left on error.
paramGetByPath :: Amazonka.Env -> ParamGetByPathArgs -> IO (Either Text GetByPathResult)
paramGetByPath awsEnv args = do
  result <- try @SomeException (fetchByPathRaw awsEnv args)
  case result of
    Left ex  -> pure $ Left $ "SSM GetParametersByPath error for " <> args.gpbPath <> ": " <> T.pack (show ex)
    Right params
      | null params -> pure (Right ByPathEmpty)
      | otherwise   -> do
          let sorted = List.sortBy (comparing (\p -> p ^. SSMP.parameter_name)) params
          case args.gpbFormat of
            ParamFormatRaw -> do
              -- Default: sort by name, build Map name->value, print as YAML
              let m = Map.fromList
                        [ (p ^. SSMP.parameter_name, p ^. SSMP.parameter_value)
                        | p <- sorted
                        ]
              pure $ Right $ ByPathOutput $ formatAsYaml m
            fmt -> do
              -- json/yaml: for each param fetch tags, build Map name->ParamOutput
              taggedMap <- buildTaggedMap awsEnv sorted
              case taggedMap of
                Left err -> pure (Left err)
                Right m  -> pure $ Right $ ByPathOutput $ formatWith fmt m

-- | Fetch raw parameters (not formatted).
fetchByPathRaw :: Amazonka.Env -> ParamGetByPathArgs -> IO [SSM.Parameter]
fetchByPathRaw awsEnv args = runResourceT $ do
  let req = (GPBP.newGetParametersByPath args.gpbPath)
              { GPBP.recursive      = Just args.gpbRecursive
              , GPBP.withDecryption = Just args.gpbDecrypt
              }
  pages <- runConduit $ Amazonka.paginate awsEnv req .| CL.consume
  pure $ concatMap (fromMaybe [] . (.parameters)) pages

-- | Build a Map from parameter name to tagged ParamOutput.
buildTaggedMap :: Amazonka.Env -> [SSM.Parameter] -> IO (Either Text (Map.Map Text ParamOutput))
buildTaggedMap awsEnv params = go params Map.empty
  where
    go [] acc = pure (Right acc)
    go (p:ps) acc = do
      let name = p ^. SSMP.parameter_name
      tagsResult <- listParamTags awsEnv name
      case tagsResult of
        Left err -> pure (Left err)
        Right tags -> go ps (Map.insert name (withParamTags tags (paramOutputFromParameter p)) acc)

------------------------------------------------------------------------
-- paramGetHistory
------------------------------------------------------------------------

-- | Fetch the version history of a single SSM parameter, formatted.
-- For simple: sort by date, split current/previous, fetch tags for message, YAML.
-- For json/yaml: FullHistory with current getting tags.
paramGetHistory :: Amazonka.Env -> ParamGetArgs -> IO (Either Text Text)
paramGetHistory awsEnv args = do
  result <- try @SomeException (fetchHistoryRaw awsEnv args.pgaPath args.pgaDecrypt)
  case result of
    Left ex  -> pure $ Left $ "SSM GetParameterHistory error for " <> args.pgaPath <> ": " <> T.pack (show ex)
    Right entries
      | null entries -> pure $ Left $ "No history found for parameter '" <> args.pgaPath <> "'"
      | otherwise -> do
          -- Sort by last_modified_date ascending
          let sorted = List.sortBy (comparing historyDate) entries
              current = last' sorted
              previous = init' sorted
          -- Fetch tags for the parameter (current entry)
          tagsResult <- listParamTags awsEnv args.pgaPath
          case tagsResult of
            Left err -> pure (Left err)
            Right tags -> case args.pgaFormat of
              ParamFormatRaw -> do
                let msg = fromMaybe "" (Map.lookup messageTag tags)
                    sh = SimpleHistory
                      { shCurrent = SimpleHistoryCurrent
                          { shcValue            = current ^. SSMPH.parameterHistory_value
                          , shcLastModifiedDate = fmap formatUtcTime (current ^. SSMPH.parameterHistory_lastModifiedDate)
                          , shcLastModifiedUser = current ^. SSMPH.parameterHistory_lastModifiedUser
                          , shcMessage          = msg
                          }
                      , shPrevious = map mkPrevious previous
                      }
                pure $ Right $ formatAsYaml sh
              fmt -> do
                let fh = FullHistory
                      { fhCurrent  = withHistoryTags tags (paramHistoryOutputFromHistory current)
                      , fhPrevious = map paramHistoryOutputFromHistory previous
                      }
                pure $ Right $ formatWith fmt fh
  where
    mkPrevious :: SSM.ParameterHistory -> SimpleHistoryPrevious
    mkPrevious ph = SimpleHistoryPrevious
      { shpValue            = ph ^. SSMPH.parameterHistory_value
      , shpLastModifiedDate = fmap formatUtcTime (ph ^. SSMPH.parameterHistory_lastModifiedDate)
      , shpLastModifiedUser = ph ^. SSMPH.parameterHistory_lastModifiedUser
      }

    historyDate :: SSM.ParameterHistory -> Maybe UTCTime
    historyDate ph = ph ^. SSMPH.parameterHistory_lastModifiedDate

-- | Fetch raw ParameterHistory entries.
fetchHistoryRaw :: Amazonka.Env -> Text -> Bool -> IO [SSM.ParameterHistory]
fetchHistoryRaw awsEnv paramName withDecryption = runResourceT $ do
  let req = (GPH.newGetParameterHistory paramName)
              { GPH.withDecryption = Just withDecryption }
  pages <- runConduit $ Amazonka.paginate awsEnv req .| CL.consume
  pure $ concatMap (fromMaybe [] . (.parameters)) pages

------------------------------------------------------------------------
-- Legacy pure helpers (still exported for existing tests)
------------------------------------------------------------------------

-- | Format a Parameter as "name=value".
formatParam :: SSM.Parameter -> Text
formatParam p =
  let name  = p ^. SSMP.parameter_name
      value = p ^. SSMP.parameter_value
  in name <> "=" <> value

-- | Format a ParameterHistory entry as "version: value".
-- Skips entries where both version and value are absent.
formatHistoryEntry :: SSM.ParameterHistory -> Maybe Text
formatHistoryEntry ph =
  let mValue   = ph ^. SSMPH.parameterHistory_value
      mVersion = ph ^. SSMPH.parameterHistory_version
  in case (mVersion, mValue) of
    (Just ver, Just val) -> Just $ "v" <> T.pack (show ver) <> ": " <> val
    (Nothing,  Just val) -> Just val
    _                    -> Nothing

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

-- | Format a value with the given ParamFormat (json or yaml).
-- Precondition: format is not ParamFormatRaw.
formatWith :: ToJSON a => ParamFormat -> a -> Text
formatWith ParamFormatJson x = formatAsJson x
formatWith ParamFormatYaml x = formatAsYaml x
formatWith ParamFormatRaw  _ = ""  -- Should not be called with Raw

-- | Safe last that returns first element if list is singleton or more.
-- Precondition: list is non-empty.
last' :: [a] -> a
last' []     = errorWithoutStackTrace "last': empty list"
last' [x]    = x
last' (_:xs) = last' xs

-- | Safe init that returns empty list if list is singleton.
-- Precondition: list is non-empty.
init' :: [a] -> [a]
init' []     = []
init' [_]    = []
init' (x:xs) = x : init' xs
