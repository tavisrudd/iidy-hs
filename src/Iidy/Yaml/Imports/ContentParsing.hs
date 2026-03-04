-- | Shared content-parsing helpers for import loaders.
--
-- All import loaders that parse YAML\/JSON content share the same core
-- logic but differ in two dimensions:
--
-- * __Dispatch by__: file extension (@.yaml@, @.json@) vs. format suffix (@:json@, @:yaml@)
-- * __Error handling__: lenient (fall back to @String@) vs. strict (return @ImportError@)
--
-- This module factors out the shared parsing core and provides four
-- thin wrappers covering each combination.
module Iidy.Yaml.Imports.ContentParsing
  ( -- * Extension-dispatched parsing
    parseByExtensionStrict
    -- * Format-suffix-dispatched parsing
  , parseByFormatSuffix
  , parseByFormatSuffixLenient
    -- * Core parsers (exposed for testing)
  , parseYamlContent
  , parseJsonContent
  ) where

import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Either (fromRight)
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Iidy.Yaml.Imports.Types (ImportError(..))
import Iidy.Yaml.Parser (parseYaml)
import Iidy.Yaml.Resolution.Resolver (astToValueRaw)

------------------------------------------------------------------------
-- Core parsers
------------------------------------------------------------------------

-- | Parse YAML text content to a 'Value'.
-- Returns @Left errorMessage@ on parse failure.
parseYamlContent :: Text -> Either Text Value
parseYamlContent content =
  case parseYaml (BL.fromStrict (TE.encodeUtf8 content)) "<import>" of
    Right ast -> Right (astToValueRaw ast)
    Left err  -> Left (T.pack (show err))

-- | Parse JSON raw bytes to a 'Value'.
-- Returns @Left errorMessage@ on parse failure.
parseJsonContent :: BS.ByteString -> Either Text Value
parseJsonContent rawBytes =
  case Aeson.eitherDecodeStrict' rawBytes of
    Right v   -> Right v
    Left err  -> Left (T.pack err)

------------------------------------------------------------------------
-- Extension-dispatched variants
------------------------------------------------------------------------

-- | Parse content by file extension, returning 'ImportError' on parse failure.
parseByExtensionStrict :: String -> Text -> BS.ByteString -> Either ImportError Value
parseByExtensionStrict ext content rawBytes
  | ext `elem` [".yaml", ".yml"] =
      case parseYamlContent content of
        Right v  -> Right v
        Left err -> Left $ ImportError $ "Failed to parse YAML: " <> err
  | ext == ".json" =
      case parseJsonContent rawBytes of
        Right v  -> Right v
        Left err -> Left $ ImportError $ "Failed to parse JSON: " <> err
  | otherwise = Right (String content)

------------------------------------------------------------------------
-- Format-suffix-dispatched variants
------------------------------------------------------------------------

-- | Parse content by format suffix (@:json@, @:yaml@, or @Nothing@),
-- returning 'ImportError' on parse failure.
-- Used by Ssm loader.
parseByFormatSuffix :: Maybe Text -> Text -> Either ImportError Value
parseByFormatSuffix Nothing val = Right (String val)
parseByFormatSuffix (Just "json") val =
  case parseJsonContent (TE.encodeUtf8 val) of
    Right v  -> Right v
    Left err -> Left $ ImportError $ "Invalid JSON in SSM parameter: " <> err
parseByFormatSuffix (Just "yaml") val =
  case parseYamlContent val of
    Right v  -> Right v
    Left err -> Left $ ImportError $ "Invalid YAML in SSM parameter: " <> err
parseByFormatSuffix (Just _) val =
  -- Unknown format suffix, treat as no format
  Right (String val)

-- | Parse content by format suffix, falling back to @String@ on parse failure.
-- Used by SsmPath loader.
parseByFormatSuffixLenient :: Maybe Text -> Text -> Value
parseByFormatSuffixLenient Nothing val = String val
parseByFormatSuffixLenient (Just "json") val =
  fromRight (String val) (parseJsonContent (TE.encodeUtf8 val))
parseByFormatSuffixLenient (Just "yaml") val =
  fromRight (String val) (parseYamlContent val)
parseByFormatSuffixLenient (Just _) val = String val
