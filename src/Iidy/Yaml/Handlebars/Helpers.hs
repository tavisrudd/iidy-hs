module Iidy.Yaml.Handlebars.Helpers (
    HelperFn,
    defaultHelpers,
) where

import Crypto.Hash (SHA256 (..), hashWith)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty qualified as Pretty
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, isUpper, toUpper)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific)
import Data.Scientific qualified as Sci
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Data.Word (Word8)

import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.OValue (fromValue)

type HelperFn = [Value] -> Either Text Value

------------------------------------------------------------------------
-- Registry
------------------------------------------------------------------------

defaultHelpers :: Map Text HelperFn
defaultHelpers =
    Map.fromList
        -- String case
        [ ("toLowerCase", oneString "toLowerCase" (String . T.toLower))
        , ("toUpperCase", oneString "toUpperCase" (String . T.toUpper))
        , ("titleize", oneString "titleize" (String . titleize))
        , ("camelCase", oneString "camelCase" (String . toCamelCase))
        , ("pascalCase", oneString "pascalCase" (String . toPascalCase))
        , ("snakeCase", oneString "snakeCase" (String . toSnakeCase))
        , ("kebabCase", oneString "kebabCase" (String . toKebabCase))
        , ("capitalize", oneString "capitalize" (String . capitalizeText))
        , -- String manipulation
          ("trim", oneString "trim" (String . T.strip))
        , ("replace", helperReplace)
        , ("substring", helperSubstring)
        , ("length", helperLength)
        , ("pad", helperPad)
        , ("concat", helperConcat)
        , -- Encoding
          ("base64", oneString "base64" (String . encodeBase64))
        , ("urlEncode", oneString "urlEncode" (String . urlEncode))
        , ("sha256", oneString "sha256" (String . sha256Hex))
        , -- Serialization
          ("toJson", helperToJson)
        , ("tojson", helperToJson)
        , ("toJsonPretty", helperToJsonPretty)
        , ("tojsonPretty", helperToJsonPretty)
        , ("toYaml", helperToYaml)
        , ("toyaml", helperToYaml)
        , -- Object access
          ("lookup", helperLookup)
        , -- Equality (for sub-expressions like (eq a b))
          ("eq", helperEq)
        ]

------------------------------------------------------------------------
-- Helper combinators
------------------------------------------------------------------------

oneString :: Text -> (Text -> Value) -> HelperFn
oneString name f = \case
    [String s] -> Right (f s)
    [_nonString] -> Left $ name <> " requires a string parameter"
    _wrongArity -> Left $ name <> " requires exactly one parameter"

------------------------------------------------------------------------
-- String case helpers
------------------------------------------------------------------------

titleize :: Text -> Text
titleize = T.unwords . map capWord . T.words
  where
    capWord w = case T.uncons w of
        Just (c, rest) -> T.cons (toUpper c) (T.toLower rest)
        Nothing -> w

toCamelCase :: Text -> Text
toCamelCase t = case splitWords t of
    [] -> ""
    (w : ws) -> T.toLower w <> T.concat (map capitalizeWord ws)

toPascalCase :: Text -> Text
toPascalCase = T.concat . map capitalizeWord . splitWords

toSnakeCase :: Text -> Text
toSnakeCase = T.intercalate "_" . map T.toLower . splitWords

toKebabCase :: Text -> Text
toKebabCase = T.intercalate "-" . map T.toLower . splitWords

capitalizeText :: Text -> Text
capitalizeText t = case T.uncons t of
    Just (c, rest) -> T.cons (toUpper c) rest
    Nothing -> t

capitalizeWord :: Text -> Text
capitalizeWord w = case T.uncons w of
    Just (c, rest) -> T.cons (toUpper c) (T.toLower rest)
    Nothing -> w

splitWords :: Text -> [Text]
splitWords = filter (not . T.null) . go
  where
    go t
        | T.null t = []
        | otherwise =
            let (word, rest) = takeWord t
             in word : go rest

    takeWord t = case T.uncons t of
        Nothing -> ("", "")
        Just (c, _)
            | isSep c -> ("", T.dropWhile isSep t)
            | isUpper c ->
                let (uppers, afterUppers) = T.span isUpper t
                 in case (T.unsnoc uppers, T.uncons afterUppers) of
                        (Just (uppersInit, lastUpper), Just (afterFirst, _))
                            | T.length uppers > 1
                            , not (isSep afterFirst) ->
                                (uppersInit, T.cons lastUpper afterUppers)
                        _other ->
                            let (lowers, rest) = T.span (\x -> not (isUpper x) && not (isSep x)) afterUppers
                             in (uppers <> lowers, rest)
            | otherwise ->
                T.span (\x -> not (isUpper x) && not (isSep x)) t

    isSep c = c == '_' || c == '-' || c == ' ' || c == '.'

------------------------------------------------------------------------
-- String manipulation helpers
------------------------------------------------------------------------

helperReplace :: HelperFn
helperReplace = \case
    [String s, String search, String replacement] ->
        Right $ String $ T.replace search replacement s
    [_, _, _] -> Left "replace requires string parameters"
    _wrongArity -> Left "replace requires three parameters: string, search, replacement"

helperSubstring :: HelperFn
helperSubstring = \case
    [String s, Number startN, Number lenN] ->
        let start = sciToInt startN
            len = sciToInt lenN
         in Right $ String $ T.take len (T.drop start s)
    [_, _, _] -> Left "substring requires (string, number, number)"
    _wrongArity -> Left "substring requires three parameters: string, start, length"

helperLength :: HelperFn
helperLength = \case
    [String s] -> Right $ String $ T.pack $ show (T.length s)
    [Array a] -> Right $ String $ T.pack $ show (V.length a)
    [Object o] -> Right $ String $ T.pack $ show (KM.size o)
    [_nonCollection] -> Left "length can only be used on strings, arrays, or objects"
    _wrongArity -> Left "length requires one parameter"

helperPad :: HelperFn
helperPad = \case
    [String s, Number targetLen] ->
        doPad s (sciToInt targetLen) " "
    [String s, Number targetLen, String padChar] ->
        doPad s (sciToInt targetLen) padChar
    args
        | Prelude.length args < 2 -> Left "pad requires at least two parameters"
        | otherwise -> Left "pad requires (string, number, [string])"
  where
    doPad s target pc
        | T.length s >= target = Right (String s)
        | otherwise =
            let padCount = target - T.length s
                padding = T.replicate padCount pc
             in Right (String (s <> padding))

helperConcat :: HelperFn
helperConcat args = do
    texts <- traverse valToText args
    Right $ String $ T.concat texts
  where
    valToText (String s) = Right s
    valToText (Number n) = Right $ sciToText n
    valToText (Bool True) = Right "true"
    valToText (Bool False) = Right "false"
    valToText _ = Left "concat only supports strings, numbers, and booleans"

------------------------------------------------------------------------
-- Encoding helpers
------------------------------------------------------------------------

encodeBase64 :: Text -> Text
encodeBase64 t =
    let bytes = TE.encodeUtf8 t
     in TE.decodeUtf8 (b64Encode bytes)

-- Minimal base64 encoder to avoid adding dependency for now
b64Encode :: ByteString -> ByteString
b64Encode input = BS.pack (go (BS.unpack input))
  where
    alphabet :: ByteString
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    enc :: Word8 -> Word8
    enc i = BS.index alphabet (fromIntegral i)

    go :: [Word8] -> [Word8]
    go [] = []
    go [a] =
        [ enc (a `shiftR` 2)
        , enc ((a .&. 3) `shiftL` 4)
        , 61
        , 61 -- ==
        ]
    go [a, b] =
        [ enc (a `shiftR` 2)
        , enc (((a .&. 3) `shiftL` 4) .|. (b `shiftR` 4))
        , enc ((b .&. 15) `shiftL` 2)
        , 61 -- =
        ]
    go (a : b : c : rest) =
        enc (a `shiftR` 2)
            : enc (((a .&. 3) `shiftL` 4) .|. (b `shiftR` 4))
            : enc (((b .&. 15) `shiftL` 2) .|. (c `shiftR` 6))
            : enc (c .&. 63)
            : go rest

urlEncode :: Text -> Text
urlEncode = T.concatMap encodeChar
  where
    encodeChar c
        | isUnreserved c = T.singleton c
        | otherwise =
            let bytes = TE.encodeUtf8 (T.singleton c)
             in T.concat [T.pack ('%' : hexByte b) | b <- BS.unpack bytes]
    isUnreserved c =
        isAsciiUpper c
            || isAsciiLower c
            || isDigit c
            || c `elem` ("-_.~" :: [Char])
    hexByte b = [hexDigit (b `div` 16), hexDigit (b `mod` 16)]
    hexDigit :: Word8 -> Char
    hexDigit n
        | n < 10 = toEnum (fromEnum '0' + fromIntegral n)
        | otherwise = toEnum (fromEnum 'A' + fromIntegral n - 10)

sha256Hex :: Text -> Text
sha256Hex t =
    let digest = hashWith SHA256 (TE.encodeUtf8 t)
        bytes = BA.convert digest :: ByteString
     in T.pack (concatMap toHexLower (BS.unpack bytes))
  where
    toHexLower b = [hexLower (b `div` 16), hexLower (b `mod` 16)]
    hexLower n
        | n < 10 = toEnum (fromEnum '0' + fromIntegral n)
        | otherwise = toEnum (fromEnum 'a' + fromIntegral n - 10)

------------------------------------------------------------------------
-- Serialization helpers
------------------------------------------------------------------------

helperToJson :: HelperFn
helperToJson = \case
    [val] -> Right $ String $ TE.decodeUtf8 $ BL.toStrict $ Aeson.encode val
    _wrongArity -> Left "toJson requires exactly one parameter"

helperToJsonPretty :: HelperFn
helperToJsonPretty = \case
    [val] -> Right $ String $ TE.decodeUtf8 $ BL.toStrict $ Pretty.encodePretty val
    _wrongArity -> Left "toJsonPretty requires exactly one parameter"

helperToYaml :: HelperFn
helperToYaml = \case
    [val] -> Right $ String $ emitYaml (fromValue val) <> "\n"
    _wrongArity -> Left "toYaml requires exactly one parameter"

------------------------------------------------------------------------
-- Object access helpers
------------------------------------------------------------------------

helperLookup :: HelperFn
helperLookup = \case
    [Object obj, String key] ->
        case KM.lookup (Key.fromText key) obj of
            Just val -> Right val
            Nothing -> Right (String "")
    [Array arr, String key] ->
        case reads (T.unpack key) :: [(Int, String)] of
            [(i, "")] | i >= 0 && i < V.length arr -> Right (arr V.! i)
            _notIndex -> Right (String "")
    [_, _] -> Left "lookup requires first parameter to be an object or array"
    _wrongArity -> Left "lookup requires two parameters: object and key"

helperEq :: HelperFn
helperEq = \case
    [a, b] -> Right $ Bool (a == b)
    _wrongArity -> Left "eq requires exactly two parameters"

------------------------------------------------------------------------
-- Numeric helpers
------------------------------------------------------------------------

sciToInt :: Scientific -> Int
sciToInt = either (round :: Double -> Int) (fromIntegral @Integer) . Sci.floatingOrInteger

sciToText :: Scientific -> Text
sciToText n = case Sci.floatingOrInteger n of
    Left (d :: Double) -> T.pack (show d)
    Right (i :: Integer) -> T.pack (show i)
