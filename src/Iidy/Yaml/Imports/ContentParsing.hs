{- | Shared content-parsing helpers for import loaders.

All import loaders that parse YAML\/JSON content share the same core
logic but differ in two dimensions:

* __Dispatch by__: file extension (@.yaml@, @.json@) vs. format suffix (@:json@, @:yaml@)
* __Error handling__: lenient (fall back to @String@) vs. strict (return @ImportError@)

This module factors out the shared parsing core and provides four
thin wrappers covering each combination.
-}
module Iidy.Yaml.Imports.ContentParsing (
    -- * Extension-dispatched parsing
    parseByExtensionStrict,

    -- * Format-suffix-dispatched parsing
    parseByFormatSuffix,
    parseByFormatSuffixLenient,

    -- * Core parsers (exposed for testing)
    ParsedDoc (..),
    parseYamlContent,
    parseYamlOrdered,
    parseJsonContent,
) where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Either (fromRight)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Iidy.Yaml.Imports.Types (ImportError (..))
import Iidy.Yaml.OValue (OValue, toValue)
import Iidy.Yaml.Parser (parseYaml)
import Iidy.Yaml.Resolution.Resolver (astToOValueKeepingTags)

------------------------------------------------------------------------
-- Core parsers
------------------------------------------------------------------------

{- | Parse YAML text content to a 'Value'.
Returns @Left errorMessage@ on parse failure.
-}
parseYamlContent :: Text -> Either Text Value
parseYamlContent = fmap toValue . parseYamlOrdered

{- | Parse YAML text to an 'OValue' that keeps mapping keys in source order
(a duplicate key keeps its first position and takes the last value).
-}
parseYamlOrdered :: Text -> Either Text OValue
parseYamlOrdered content =
    case parseYaml (BL.fromStrict (TE.encodeUtf8 content)) "<import>" of
        Right ast -> Right (astToOValueKeepingTags ast)
        Left err -> Left (T.pack (show err))

{- | A parsed import document: the aeson value (sorted keys) the engine uses,
and, when the text could be read as YAML, the same document in source order.
-}
data ParsedDoc = ParsedDoc
    { pdValue :: !Value
    , pdOrdered :: Maybe OValue -- lazy: see 'idOrdered'
    }
    deriving stock (Show, Eq)

-- | A YAML document: both views come from the one parse.
yamlDoc :: OValue -> ParsedDoc
yamlDoc o = ParsedDoc (toValue o) (Just o)

{- | A JSON document. The value stays the aeson parse (numbers and duplicate
keys as before); the ordered view reads the same text as YAML, as Rust does.
-}
jsonDoc :: Text -> Value -> ParsedDoc
jsonDoc content v = ParsedDoc v (either (const Nothing) Just (parseYamlOrdered content))

-- | A document with no key order to keep (scalars, lenient fallbacks).
plainDoc :: Value -> ParsedDoc
plainDoc v = ParsedDoc v Nothing

{- | Parse JSON raw bytes to a 'Value'.
Returns @Left errorMessage@ on parse failure.
-}
parseJsonContent :: BS.ByteString -> Either Text Value
parseJsonContent rawBytes =
    case Aeson.eitherDecodeStrict' rawBytes of
        Right v -> Right v
        Left err -> Left (T.pack err)

------------------------------------------------------------------------
-- Extension-dispatched variants
------------------------------------------------------------------------

-- | Parse content by file extension, returning 'ImportError' on parse failure.
parseByExtensionStrict :: String -> Text -> BS.ByteString -> Either ImportError ParsedDoc
parseByExtensionStrict ext content rawBytes
    | ext `elem` [".yaml", ".yml"] =
        case parseYamlOrdered content of
            Right o -> Right (yamlDoc o)
            Left err -> Left $ ImportError $ "Failed to parse YAML: " <> err
    | ext == ".json" =
        case parseJsonContent rawBytes of
            Right v -> Right (jsonDoc content v)
            Left err -> Left $ ImportError $ "Failed to parse JSON: " <> err
    | otherwise = Right (plainDoc (String content))

------------------------------------------------------------------------
-- Format-suffix-dispatched variants
------------------------------------------------------------------------

{- | Parse content by format suffix (@:json@, @:yaml@, or @Nothing@),
returning 'ImportError' on parse failure.
Used by Ssm loader.
-}
parseByFormatSuffix :: Maybe Text -> Text -> Either ImportError ParsedDoc
parseByFormatSuffix Nothing val = Right (plainDoc (String val))
parseByFormatSuffix (Just "json") val =
    case parseJsonContent (TE.encodeUtf8 val) of
        Right v -> Right (jsonDoc val v)
        Left err -> Left $ ImportError $ "Invalid JSON in SSM parameter: " <> err
parseByFormatSuffix (Just "yaml") val =
    case parseYamlOrdered val of
        Right o -> Right (yamlDoc o)
        Left err -> Left $ ImportError $ "Invalid YAML in SSM parameter: " <> err
parseByFormatSuffix (Just _) val =
    -- Unknown format suffix, treat as no format
    Right (plainDoc (String val))

{- | Parse content by format suffix, falling back to @String@ on parse failure.
Used by SsmPath loader.
-}
parseByFormatSuffixLenient :: Maybe Text -> Text -> Value
parseByFormatSuffixLenient Nothing val = String val
parseByFormatSuffixLenient (Just "json") val =
    fromRight (String val) (parseJsonContent (TE.encodeUtf8 val))
parseByFormatSuffixLenient (Just "yaml") val =
    fromRight (String val) (parseYamlContent val)
parseByFormatSuffixLenient (Just _) val = String val
