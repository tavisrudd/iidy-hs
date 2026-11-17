{- | Mapping key identity for duplicate detection, following Rust's serde_yaml
(@~/src/iidy@, "duplicate entry"): a scalar key is compared by the type its
spelling resolves to, not by a value shared across types. @1@ and @1.0@ are
different keys, @1@ and @0x1@ are the same key, @01@ is a string, @a@ and
@"a"@ are the same key and @1@ and @"1"@ are not.
-}
module Iidy.Yaml.DuplicateKeys (
    KeyId,
    scalarKeyId,
    firstDuplicate,
    duplicateMessage,
) where

import Data.Char (isDigit, isHexDigit, isOctDigit)
import Data.Scientific (Scientific)
import Data.Scientific qualified as Sci
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (readBin, readHex, readOct)

data KeyId
    = KeyText Text
    | KeyInt Integer
    | KeyFloat FloatKey
    | KeyBool Bool
    | KeyNull
    deriving stock (Eq, Ord)

-- | A float key: equal values are one key, and NaN equals NaN.
data FloatKey = FloatNaN | FloatInf Bool | FloatNum Scientific
    deriving stock (Eq, Ord)

{- | The identity of a scalar key. Only an untagged plain scalar is resolved
to a number, boolean or null; any other scalar is its text.
-}
scalarKeyId :: Bool -> Text -> KeyId
scalarKeyId resolved text
    | not resolved = KeyText text
    | text `elem` ["null", "Null", "NULL", "~", ""] = KeyNull
    | text `elem` ["true", "True", "TRUE"] = KeyBool True
    | text `elem` ["false", "False", "FALSE"] = KeyBool False
    | Just n <- intKey text = KeyInt n
    | Just f <- floatKey text = KeyFloat f
    | otherwise = KeyText text

-- | Decimal without leading zeros (signed), or @0x@, @0o@, @0b@ digits.
intKey :: Text -> Maybe Integer
intKey t = case T.unpack t of
    '0' : 'x' : ds | digitsOk isHexDigit ds -> first readHex ds
    '0' : 'o' : ds | digitsOk isOctDigit ds -> first readOct ds
    '0' : 'b' : ds | digitsOk (`elem` ['0', '1']) ds -> first readBin ds
    '-' : ds -> negate <$> decimal ds
    '+' : ds -> decimal ds
    ds -> decimal ds
  where
    digitsOk p ds = not (null ds) && all p ds
    first reader ds = case reader ds of
        [(n, "")] -> Just n
        _unreadable -> Nothing
    decimal = \case
        "0" -> Just 0
        d : ds | d /= '0' && all isDigit (d : ds) -> Just (read (d : ds))
        _other -> Nothing

-- | A float spelled with a point or an exponent, or @.inf@ or @.nan@.
floatKey :: Text -> Maybe FloatKey
floatKey t = case T.unpack t of
    s | s `elem` [".nan", ".NaN", ".NAN"] -> Just FloatNaN
    '-' : s | isInf s -> Just (FloatInf False)
    '+' : s | isInf s -> Just (FloatInf True)
    s | isInf s -> Just (FloatInf True)
    '-' : s -> FloatNum . negate <$> number s
    '+' : s -> FloatNum <$> number s
    s -> FloatNum <$> number s
  where
    isInf s = s `elem` [".inf", ".Inf", ".INF"]
    number s =
        let (whole, afterWhole) = span isDigit s
            (frac, hasPoint, afterFrac) = case afterWhole of
                '.' : r -> let (f, r') = span isDigit r in (f, True, r')
                r -> ("", False, r)
         in do
                exponent' <- case afterFrac of
                    "" -> Just (0, False)
                    e : r | e `elem` ['e', 'E'] -> (,True) <$> expo r
                    _other -> Nothing
                let (ex, hasExp) = exponent'
                if (hasPoint || hasExp) && not (null (whole ++ frac))
                    then Just (Sci.scientific (read (whole ++ frac)) (ex - length frac))
                    else Nothing
    expo = \case
        '-' : ds | digitsOnly ds -> Just (negate (read ds))
        '+' : ds | digitsOnly ds -> Just (read ds)
        ds | digitsOnly ds -> Just (read ds)
        _other -> Nothing
    digitsOnly ds = not (null ds) && all isDigit ds

{- | The first element whose key repeats an earlier one, with Rust's message
for that key. Elements without a key identity never repeat.
-}
firstDuplicate :: [(a, Maybe KeyId)] -> Maybe (a, String)
firstDuplicate = go Set.empty
  where
    go _ [] = Nothing
    go seen ((x, mk) : rest) = case mk of
        Nothing -> go seen rest
        Just k
            | k `Set.member` seen -> Just (x, duplicateMessage k)
            | otherwise -> go (Set.insert k seen) rest

-- | Rust's wording: a string key quoted, a boolean in backquotes.
duplicateMessage :: KeyId -> String
duplicateMessage = \case
    KeyText t -> "duplicate entry with key " <> show t
    KeyInt n -> "duplicate entry with key " <> show n
    KeyFloat FloatNaN -> "duplicate entry with key .nan"
    KeyFloat (FloatInf positive) -> "duplicate entry with key " <> (if positive then "" else "-") <> ".inf"
    KeyFloat (FloatNum n) -> "duplicate entry with key " <> showFloat n
    KeyBool b -> "duplicate entry with key `" <> (if b then "true" else "false") <> "`"
    KeyNull -> "duplicate entry with null key"
  where
    showFloat n
        | Sci.isInteger n = show (truncate n :: Integer) <> ".0"
        | otherwise = Sci.formatScientific Sci.Fixed Nothing n
