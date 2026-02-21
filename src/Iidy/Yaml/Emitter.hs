module Iidy.Yaml.Emitter
  ( emitYaml
  ) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Char (isDigit)
import Data.Scientific (Scientific)
import qualified Data.Scientific as Sci
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- | Emit a Value as iidy-js-compatible YAML.
emitYaml :: Value -> Text
emitYaml val = emitValue 0 True val

------------------------------------------------------------------------
-- Core emission
------------------------------------------------------------------------

emitValue :: Int -> Bool -> Value -> Text
emitValue indent isRoot = \case
  Null -> "null"
  Bool True -> "true"
  Bool False -> "false"
  Number n -> emitNumber n
  String s -> emitString s
  Array arr
    | V.null arr -> "[]"
    | otherwise -> emitArray indent arr
  Object obj
    | KM.null obj -> "{}"
    | isTaggedValue obj -> emitTaggedValue indent obj
    | otherwise -> emitMapping indent isRoot obj

------------------------------------------------------------------------
-- Scalars
------------------------------------------------------------------------

emitNumber :: Scientific -> Text
emitNumber n = case Sci.floatingOrInteger n of
  Left (d :: Double) -> T.pack (show d)
  Right (i :: Integer) -> T.pack (show i)

emitString :: Text -> Text
emitString s
  | T.any (== '\n') s = emitMultilineString s
  | needsQuotes s = quoteString s
  | otherwise = s

emitMultilineString :: Text -> Text
emitMultilineString s =
  let lns = T.splitOn "\n" s
      hasTrailingNewline = T.isSuffixOf "\n" s
      header = if hasTrailingNewline then "|" else "|-"
      bodyLines = if hasTrailingNewline then init lns else lns
      indented = map (\l -> if T.null l then "" else "  " <> l) bodyLines
  in header <> "\n" <> T.intercalate "\n" indented

needsQuotes :: Text -> Bool
needsQuotes s
  | T.null s = True
  | isAmbiguousType s = True
  | not (isPlainSafeFirst (T.head s)) = True
  | T.last s == ':' || T.last s == ' ' = True
  | T.any isFlowIndicator s = True
  | T.isInfixOf ": " s = True
  | T.isInfixOf " #" s = True
  | otherwise = False

isAmbiguousType :: Text -> Bool
isAmbiguousType s = s `elem` ambiguousWords || isAmbiguousNumber s

ambiguousWords :: [Text]
ambiguousWords =
  [ "true", "false", "null", "~"
  , "yes", "no", "on", "off"
  , "True", "False", "Null"
  , "Yes", "No", "On", "Off"
  , "TRUE", "FALSE", "NULL"
  , "YES", "NO", "ON", "OFF"
  ]

isAmbiguousNumber :: Text -> Bool
isAmbiguousNumber s =
  not (T.null s) &&
  let first = T.head s
      isNumStart c = isDigit c || c == '+' || c == '-' || c == '.'
  in isNumStart first && isNumericLooking s

isNumericLooking :: Text -> Bool
isNumericLooking s =
  case reads (T.unpack s) :: [(Double, String)] of
    [(_, "")] -> True
    _ -> case reads (T.unpack s) :: [(Integer, String)] of
      [(_, "")] -> True
      _ -> False

isPlainSafeFirst :: Char -> Bool
isPlainSafeFirst c = not (c `elem` ("-?:,[]{}#&*!|>'\"%@`" :: [Char]))

isFlowIndicator :: Char -> Bool
isFlowIndicator c = c `elem` ("[]{}" :: [Char])

quoteString :: Text -> Text
quoteString s
  | not (T.any (== '\'') s) = "'" <> escapeSingleQuotes s <> "'"
  | not (T.any (== '"') s) = "\"" <> escapeDoubleQuotes s <> "\""
  | otherwise = "\"" <> escapeDoubleQuotes s <> "\""

escapeSingleQuotes :: Text -> Text
escapeSingleQuotes = T.replace "'" "''"

escapeDoubleQuotes :: Text -> Text
escapeDoubleQuotes = T.concatMap $ \case
  '"'  -> "\\\""
  '\\' -> "\\\\"
  '\n' -> "\\n"
  '\r' -> "\\r"
  '\t' -> "\\t"
  c    -> T.singleton c

------------------------------------------------------------------------
-- Arrays
------------------------------------------------------------------------

emitArray :: Int -> V.Vector Value -> Text
emitArray indent arr =
  let items = V.toList arr
      indentStr = T.replicate indent " "
      emitItem val =
        let valStr = emitArrayValue (indent + 2) val
        in indentStr <> "- " <> valStr
  in "\n" <> T.intercalate "\n" (map emitItem items)

emitArrayValue :: Int -> Value -> Text
emitArrayValue indent = \case
  Object obj
    | KM.null obj -> "{}"
    | isTaggedValue obj -> emitTaggedValue indent obj
    | otherwise -> emitMappingInline indent obj
  Array arr
    | V.null arr -> "[]"
    | otherwise -> emitArray indent arr
  other -> emitValue indent False other

------------------------------------------------------------------------
-- Mappings
------------------------------------------------------------------------

emitMapping :: Int -> Bool -> KM.KeyMap Value -> Text
emitMapping indent isRoot obj =
  let pairs = KM.toList obj
      indentStr = T.replicate indent " "
      emitPair (k, v) =
        let keyStr = emitMapKey (Key.toText k)
            valStr = emitMapValue (indent + 2) v
        in indentStr <> keyStr <> ":" <> valStr
      body = T.intercalate "\n" (map emitPair pairs)
  in if isRoot then body else "\n" <> body

emitMappingInline :: Int -> KM.KeyMap Value -> Text
emitMappingInline indent obj =
  let pairs = KM.toList obj
      indentStr = T.replicate indent " "
      emitFirst (k, v) =
        emitMapKey (Key.toText k) <> ":" <> emitMapValue (indent + 2) v
      emitRest (k, v) =
        indentStr <> emitMapKey (Key.toText k) <> ":" <> emitMapValue (indent + 2) v
  in case pairs of
    [] -> "{}"
    (first:rest) -> emitFirst first <> "\n" <> T.intercalate "\n" (map emitRest rest)

emitMapKey :: Text -> Text
emitMapKey k
  | needsQuotes k = quoteString k
  | otherwise = k

emitMapValue :: Int -> Value -> Text
emitMapValue indent = \case
  Null -> " null"
  Bool True -> " true"
  Bool False -> " false"
  Number n -> " " <> emitNumber n
  String s
    | T.any (== '\n') s -> " " <> emitMultilineStringIndented indent s
    | needsQuotes s -> " " <> quoteString s
    | otherwise -> " " <> s
  Array arr
    | V.null arr -> " []"
    | otherwise -> emitArray indent arr
  Object obj
    | KM.null obj -> " {}"
    | isTaggedValue obj -> " " <> emitTaggedValue indent obj
    | otherwise -> emitMapping indent False obj

emitMultilineStringIndented :: Int -> Text -> Text
emitMultilineStringIndented indent s =
  let lns = T.splitOn "\n" s
      hasTrailingNewline = T.isSuffixOf "\n" s
      header = if hasTrailingNewline then "|" else "|-"
      bodyLines = if hasTrailingNewline then init lns else lns
      indentStr = T.replicate indent " "
      indented = map (\l -> if T.null l then "" else indentStr <> l) bodyLines
  in header <> "\n" <> T.intercalate "\n" indented

------------------------------------------------------------------------
-- CloudFormation tagged values
------------------------------------------------------------------------

isTaggedValue :: KM.KeyMap Value -> Bool
isTaggedValue obj =
  KM.size obj == 1 &&
  case KM.toList obj of
    [(k, _)] -> T.isPrefixOf "!" (Key.toText k)
    _ -> False

emitTaggedValue :: Int -> KM.KeyMap Value -> Text
emitTaggedValue indent obj = case KM.toList obj of
  [(k, v)] ->
    let tag = Key.toText k
    in tag <> emitTagArgument indent v
  _ -> "{}"  -- shouldn't happen

emitTagArgument :: Int -> Value -> Text
emitTagArgument indent = \case
  String s -> " " <> emitString s
  Number n -> " " <> emitNumber n
  Bool b -> " " <> if b then "true" else "false"
  Null -> " null"
  Array arr -> emitArray indent arr
  Object obj -> emitMapping indent False obj
