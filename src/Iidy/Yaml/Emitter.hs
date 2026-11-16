module Iidy.Yaml.Emitter (
    SeqStyle (..),
    emitYaml,
    emitYamlWith,
) where

import Data.Char (isDigit)
import Data.Scientific (Scientific)
import Data.Scientific qualified as Sci
import Data.Text (Text)
import Data.Text qualified as T
import Iidy.Yaml.OValue

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

{- | Where the dashes of a block sequence under a mapping key go.

'SeqIndented' is iidy-js / Rust @serialize_yaml_iidy_js_compatible@ (the
@render@ output): dashes two columns right of the key. 'SeqFlush' is Rust
@serde_yaml@ (@get-import@): dashes at the key's own column.
-}
data SeqStyle = SeqIndented | SeqFlush
    deriving (Show, Eq)

-- | Emit an OValue as iidy-js-compatible YAML ('SeqIndented').
emitYaml :: OValue -> Text
emitYaml = emitYamlWith SeqIndented

-- | Emit an OValue as YAML with the given sequence layout.
emitYamlWith :: SeqStyle -> OValue -> Text
emitYamlWith st = emitValue st 0 True

------------------------------------------------------------------------
-- Core emission
------------------------------------------------------------------------

emitValue :: SeqStyle -> Int -> Bool -> OValue -> Text
emitValue st indent isRoot = \case
    ONull -> "null"
    OBool True -> "true"
    OBool False -> "false"
    ONumber n -> emitNumber n
    OString s -> emitString s
    OArray items
        | null items -> "[]"
        | isRoot && st == SeqFlush -> T.drop 1 (emitArray st indent items)
        | otherwise -> emitArray st indent items
    OObject kvs
        | null kvs -> "{}"
        | isTaggedKvs kvs -> emitTaggedKvs st indent kvs
        | otherwise -> emitMapping st indent isRoot kvs

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
        bodyLines = if hasTrailingNewline then safeInit lns else lns
        indented = map (\l -> if T.null l then "" else "  " <> l) bodyLines
     in header <> "\n" <> T.intercalate "\n" indented

needsQuotes :: Text -> Bool
needsQuotes s
    | Just (first, _) <- T.uncons s
    , Just (_, lastCh) <- T.unsnoc s =
        isAmbiguousType s
            || first == ' '
            || T.any (== '\t') s
            || not (isPlainSafeFirst first)
            || lastCh == ':'
            || lastCh == ' '
            || first `elem` ("[]{},:" :: [Char])
            || T.isInfixOf ": " s
            || T.isInfixOf " #" s
    | otherwise = True -- empty string

isAmbiguousType :: Text -> Bool
isAmbiguousType s = s `elem` ambiguousWords || isAmbiguousNumber s

ambiguousWords :: [Text]
ambiguousWords =
    [ "true"
    , "false"
    , "null"
    , "~"
    , "yes"
    , "no"
    , "on"
    , "off"
    , "True"
    , "False"
    , "Null"
    , "Yes"
    , "No"
    , "On"
    , "Off"
    , "TRUE"
    , "FALSE"
    , "NULL"
    , "YES"
    , "NO"
    , "ON"
    , "OFF"
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
        _notDouble -> case reads (T.unpack s) :: [(Integer, String)] of
            [(_, "")] -> True
            _notInteger -> False

isPlainSafeFirst :: Char -> Bool
isPlainSafeFirst c = c `notElem` ("-?:,[]{}#&*!|>'\"%@`" :: [Char])

quoteString :: Text -> Text
quoteString s
    | not (T.any (== '\'') s) = "'" <> escapeSingleQuotes s <> "'"
    | not (T.any (== '"') s) = "\"" <> escapeDoubleQuotes s <> "\""
    | otherwise = "\"" <> escapeDoubleQuotes s <> "\""

escapeSingleQuotes :: Text -> Text
escapeSingleQuotes = T.replace "'" "''"

escapeDoubleQuotes :: Text -> Text
escapeDoubleQuotes = T.concatMap $ \case
    '"' -> "\\\""
    '\\' -> "\\\\"
    '\n' -> "\\n"
    '\r' -> "\\r"
    '\t' -> "\\t"
    c -> T.singleton c

------------------------------------------------------------------------
-- Arrays
------------------------------------------------------------------------

emitArray :: SeqStyle -> Int -> [OValue] -> Text
emitArray st indent items =
    let indentStr = T.replicate indent " "
        emitItem val =
            let valStr = emitArrayValue st (indent + 2) val
             in indentStr <> "- " <> valStr
     in "\n" <> T.intercalate "\n" (map emitItem items)

emitArrayInline :: SeqStyle -> Int -> [OValue] -> Text
emitArrayInline st indent items =
    let indentStr = T.replicate indent " "
        emitFirst val = "- " <> emitArrayValue st (indent + 2) val
        emitRest val = indentStr <> "- " <> emitArrayValue st (indent + 2) val
     in case items of
            [] -> "[]"
            (first : rest) -> emitFirst first <> "\n" <> T.intercalate "\n" (map emitRest rest)

emitArrayValue :: SeqStyle -> Int -> OValue -> Text
emitArrayValue st indent = \case
    OObject kvs
        | null kvs -> "{}"
        | isTaggedKvs kvs -> emitTaggedKvs st indent kvs
        | otherwise -> emitMappingInline st indent kvs
    OArray items
        | null items -> "[]"
        | otherwise -> emitArrayInline st indent items
    OString s
        | T.any (== '\n') s -> emitMultilineStringIndented indent s
        | needsQuotes s -> quoteString s
        | otherwise -> s
    other -> emitValue st indent False other

------------------------------------------------------------------------
-- Mappings
------------------------------------------------------------------------

emitMapping :: SeqStyle -> Int -> Bool -> [(Text, OValue)] -> Text
emitMapping st indent isRoot kvs =
    let indentStr = T.replicate indent " "
        emitPair (k, v) =
            let keyStr = emitMapKey k
                valStr = emitMapValue st (indent + 2) v
             in indentStr <> keyStr <> ":" <> valStr
        body = T.intercalate "\n" (map emitPair kvs)
     in if isRoot then body else "\n" <> body

emitMappingInline :: SeqStyle -> Int -> [(Text, OValue)] -> Text
emitMappingInline st indent kvs =
    let indentStr = T.replicate indent " "
        emitFirst (k, v) =
            emitMapKey k <> ":" <> emitMapValue st (indent + 2) v
        emitRest (k, v) =
            indentStr <> emitMapKey k <> ":" <> emitMapValue st (indent + 2) v
     in case kvs of
            [] -> "{}"
            (first : rest) -> emitFirst first <> "\n" <> T.intercalate "\n" (map emitRest rest)

emitMapKey :: Text -> Text
emitMapKey k
    | needsQuotes k = quoteString k
    | otherwise = k

emitMapValue :: SeqStyle -> Int -> OValue -> Text
emitMapValue st indent = \case
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
        | otherwise -> emitArray st (seqIndent st indent) items
    OObject kvs
        | null kvs -> " {}"
        | isTaggedKvs kvs -> " " <> emitTaggedKvs st indent kvs
        | otherwise -> emitMapping st indent False kvs

{- | Column of the dashes of a sequence under a mapping key, given the column
its value would otherwise be indented to (the key's column plus two).
-}
seqIndent :: SeqStyle -> Int -> Int
seqIndent SeqIndented indent = indent
seqIndent SeqFlush indent = max 0 (indent - 2)

emitMultilineStringIndented :: Int -> Text -> Text
emitMultilineStringIndented indent s =
    let lns = T.splitOn "\n" s
        hasTrailingNewline = T.isSuffixOf "\n" s
        header = if hasTrailingNewline then "|" else "|-"
        bodyLines = if hasTrailingNewline then safeInit lns else lns
        indentStr = T.replicate indent " "
        indented = map (\l -> if T.null l then "" else indentStr <> l) bodyLines
     in header <> "\n" <> T.intercalate "\n" indented

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

{- | Safe version of 'init' that returns '[]' on empty input instead of
crashing. Uses reverse + drop + reverse to avoid calling the partial
'Prelude.init'. T.splitOn never returns an empty list, but we avoid
partial functions as a matter of policy (CLAUDE.md: "No partial functions").
-}
safeInit :: [a] -> [a]
safeInit [] = []
safeInit xs = reverse (drop 1 (reverse xs))

------------------------------------------------------------------------
-- CloudFormation tagged values
------------------------------------------------------------------------

isTaggedKvs :: [(Text, OValue)] -> Bool
isTaggedKvs kvs =
    length kvs == 1
        && case kvs of
            [(k, _)] -> T.isPrefixOf "!" k
            _notSingleton -> False

emitTaggedKvs :: SeqStyle -> Int -> [(Text, OValue)] -> Text
emitTaggedKvs st indent kvs = case kvs of
    [(tag, v)] -> tag <> emitTagArgument st indent v
    _notSingleton -> "{}"

emitTagArgument :: SeqStyle -> Int -> OValue -> Text
emitTagArgument st indent = \case
    OString s
        | T.any (== '\n') s -> " " <> emitMultilineStringIndented indent s
        | needsQuotes s -> " " <> quoteString s
        | otherwise -> " " <> s
    ONumber n -> " " <> emitNumber n
    OBool b -> " " <> if b then "true" else "false"
    ONull -> " null"
    OArray [single] -> emitTagArgument st indent single
    OArray items -> emitArray st indent items
    OObject kvs
        | isTaggedKvs kvs -> " " <> emitTaggedKvs st indent kvs
        | otherwise -> emitMapping st indent False kvs
