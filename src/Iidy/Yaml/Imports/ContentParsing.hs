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
import Data.Aeson.Decoding.ByteString (bsToTokens)
import Data.Aeson.Decoding.Tokens qualified as Tk
import Data.Aeson.Key qualified as Key
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Either (fromRight)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Iidy.Yaml.Imports.Types (ImportError (..))
import Iidy.Yaml.OValue (OValue (..), toValue)
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

-- | A document whose ordered view the value is derived from (one parse).
yamlDoc :: OValue -> ParsedDoc
yamlDoc o = ParsedDoc (toValue o) (Just o)

{- | Read JSON bytes straight from aeson's token stream into an 'OValue' with
keys in source order (a duplicate key keeps its first position and takes the
last value). 'Nothing' on malformed input. aeson decodes the escapes, so
surrogate pairs come out right; the 'Value' is 'toValue' of the result, so
the text is parsed once.
-}
jsonToOValue :: BS.ByteString -> Maybe OValue
jsonToOValue bytes = case value (bsToTokens bytes) of
    Right (v, rest) | BS.all isJsonSpace rest -> Just v
    _ -> Nothing
  where
    isJsonSpace w = w `elem` [0x20, 0x09, 0x0a, 0x0d]
    value :: Tk.Tokens k String -> Either String (OValue, k)
    value = \case
        Tk.TkLit l k -> Right (lit l, k)
        Tk.TkText t k -> Right (OString t, k)
        Tk.TkNumber n k -> Right (ONumber (num n), k)
        Tk.TkArrayOpen a -> array [] a
        Tk.TkRecordOpen r -> record [] r
        Tk.TkErr e -> Left e
    lit = \case
        Tk.LitNull -> ONull
        Tk.LitTrue -> OBool True
        Tk.LitFalse -> OBool False
    num = \case
        Tk.NumInteger i -> fromInteger i
        Tk.NumDecimal s -> s
        Tk.NumScientific s -> s
    array acc = \case
        Tk.TkItem ts -> value ts >>= \(v, rest) -> array (v : acc) rest
        Tk.TkArrayEnd k -> Right (OArray (reverse acc), k)
        Tk.TkArrayErr e -> Left e
    record acc = \case
        Tk.TkPair key ts ->
            value ts >>= \(v, rest) -> record (setKey (Key.toText key) v acc) rest
        Tk.TkRecordEnd k -> Right (OObject (reverse acc), k)
        Tk.TkRecordErr e -> Left e
    -- acc is reversed; a repeated key is replaced in place
    setKey k v acc
        | any ((== k) . fst) acc = [(k', if k' == k then v else v') | (k', v') <- acc]
        | otherwise = (k, v) : acc

{- | Parse JSON bytes once. A malformed document takes the error text from
'parseJsonContent', so messages stay those of aeson's @eitherDecode@.
-}
parseJsonDoc :: BS.ByteString -> Either Text ParsedDoc
parseJsonDoc bytes = case jsonToOValue bytes of
    Just o -> Right (yamlDoc o)
    Nothing -> plainDoc <$> parseJsonContent bytes

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
        case parseJsonDoc rawBytes of
            Right d -> Right d
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
    case parseJsonDoc (TE.encodeUtf8 val) of
        Right d -> Right d
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
