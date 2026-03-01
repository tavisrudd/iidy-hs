module Iidy.Yaml.Emitter
  ( emitYaml
  ) where

import Data.Char (isDigit)
import Data.Scientific (Scientific)
import qualified Data.Scientific as Sci
import Data.Text (Text)
import qualified Data.Text as T
import Iidy.Yaml.OValue

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- | Emit an OValue as iidy-js-compatible YAML.
emitYaml :: OValue -> Text
emitYaml val = emitValue 0 True val

------------------------------------------------------------------------
-- Core emission
------------------------------------------------------------------------

emitValue :: Int -> Bool -> OValue -> Text
emitValue indent isRoot = \case
  ONull -> "null"
  OBool True -> "true"
  OBool False -> "false"
  ONumber n -> emitNumber n
  OString s -> emitString s
  OArray items
    | null items -> "[]"
    | otherwise -> emitArray indent items
  OObject kvs
    | null kvs -> "{}"
    | isTaggedKvs kvs -> emitTaggedKvs indent kvs
    | otherwise -> emitMapping indent isRoot kvs

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
  | Just (first, _) <- T.uncons s
  , Just (_, lastCh) <- T.unsnoc s
  = isAmbiguousType s
    || first == ' '
    || T.any (== '\t') s
    || not (isPlainSafeFirst first)
    || lastCh == ':' || lastCh == ' '
    || first `elem` ("[]{},:" :: [Char])
    || T.isInfixOf ": " s
    || T.isInfixOf " #" s
  | otherwise = True  -- empty string

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
isAmbiguousNumber s = case T.uncons s of
  Nothing -> False
  Just (first, _) ->
    let isNumStart c = isDigit c || c == '+' || c == '-' || c == '.'
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

emitArray :: Int -> [OValue] -> Text
emitArray indent items =
  let indentStr = T.replicate indent " "
      emitItem val =
        let valStr = emitArrayValue (indent + 2) val
        in indentStr <> "- " <> valStr
  in "\n" <> T.intercalate "\n" (map emitItem items)

emitArrayInline :: Int -> [OValue] -> Text
emitArrayInline indent items =
  let indentStr = T.replicate indent " "
      emitFirst val = "- " <> emitArrayValue (indent + 2) val
      emitRest val = indentStr <> "- " <> emitArrayValue (indent + 2) val
  in case items of
    [] -> "[]"
    (first:rest) -> emitFirst first <> "\n" <> T.intercalate "\n" (map emitRest rest)

emitArrayValue :: Int -> OValue -> Text
emitArrayValue indent = \case
  OObject kvs
    | null kvs -> "{}"
    | isTaggedKvs kvs -> emitTaggedKvs indent kvs
    | otherwise -> emitMappingInline indent kvs
  OArray items
    | null items -> "[]"
    | otherwise -> emitArrayInline indent items
  OString s
    | T.any (== '\n') s -> emitMultilineStringIndented indent s
    | needsQuotes s -> quoteString s
    | otherwise -> s
  other -> emitValue indent False other

------------------------------------------------------------------------
-- Mappings
------------------------------------------------------------------------

emitMapping :: Int -> Bool -> [(Text, OValue)] -> Text
emitMapping indent isRoot kvs =
  let indentStr = T.replicate indent " "
      emitPair (k, v) =
        let keyStr = emitMapKey k
            valStr = emitMapValue (indent + 2) v
        in indentStr <> keyStr <> ":" <> valStr
      body = T.intercalate "\n" (map emitPair kvs)
  in if isRoot then body else "\n" <> body

emitMappingInline :: Int -> [(Text, OValue)] -> Text
emitMappingInline indent kvs =
  let indentStr = T.replicate indent " "
      emitFirst (k, v) =
        emitMapKey k <> ":" <> emitMapValue (indent + 2) v
      emitRest (k, v) =
        indentStr <> emitMapKey k <> ":" <> emitMapValue (indent + 2) v
  in case kvs of
    [] -> "{}"
    (first:rest) -> emitFirst first <> "\n" <> T.intercalate "\n" (map emitRest rest)

emitMapKey :: Text -> Text
emitMapKey k
  | needsQuotes k = quoteString k
  | otherwise = k

emitMapValue :: Int -> OValue -> Text
emitMapValue indent = \case
  ONull -> " null"
  OBool True -> " true"
  OBool False -> " false"
  ONumber n -> " " <> emitNumber n
  OString s
    | T.any (== '\n') s -> " " <> emitMultilineStringIndented indent s
    | needsQuotes s -> " " <> quoteString s
    | otherwise -> " " <> s
  OArray items
    | null items -> " []"
    | otherwise -> emitArray indent items
  OObject kvs
    | null kvs -> " {}"
    | isTaggedKvs kvs -> " " <> emitTaggedKvs indent kvs
    | otherwise -> emitMapping indent False kvs

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

isTaggedKvs :: [(Text, OValue)] -> Bool
isTaggedKvs kvs =
  length kvs == 1 &&
  case kvs of
    [(k, _)] -> T.isPrefixOf "!" k
    _ -> False

emitTaggedKvs :: Int -> [(Text, OValue)] -> Text
emitTaggedKvs indent kvs = case kvs of
  [(tag, v)] -> tag <> emitTagArgument indent v
  _ -> "{}"

emitTagArgument :: Int -> OValue -> Text
emitTagArgument indent = \case
  OString s
    | T.any (== '\n') s -> " " <> emitMultilineStringIndented indent s
    | needsQuotes s -> " " <> quoteString s
    | otherwise -> " " <> s
  ONumber n -> " " <> emitNumber n
  OBool b -> " " <> if b then "true" else "false"
  ONull -> " null"
  OArray [single] -> emitTagArgument indent single
  OArray items -> emitArray indent items
  OObject kvs
    | isTaggedKvs kvs -> " " <> emitTaggedKvs indent kvs
    | otherwise -> emitMapping indent False kvs
