{- | Escaping of terminal control characters in text that comes from outside
the tool (template text, AWS strings, exception text).

Untrusted text is passed through 'escapeControl' before the renderer adds its
own colour codes and before any width calculation, so a value cannot rewrite
or hide lines on the reviewer's terminal. Each escaped character becomes
@\\uNNNN@ (four lower-case hex digits), the spelling the YAML emitter also
uses for control characters.

Deliberately not applied to document output (@OdRawOutput@ and the template
body of @OdStackTemplate@): those bytes must stay exact.
-}
module Iidy.Output.Sanitize (
    escapeControl,
    needsEscape,
) where

import Data.Char (ord)
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (showHex)

{- | Whether a character is escaped unconditionally: C0 controls except
newline and tab (a carriage return is handled by 'escapeControl', since it is
kept before a newline), DEL, C1 controls, line and paragraph separators and
the bidirectional controls.
-}
needsEscape :: Char -> Bool
needsEscape c
    | c == '\n' || c == '\t' = False
    | n < 0x20 = True
    | n == 0x7f = True
    | n >= 0x80 && n <= 0x9f = True
    | n == 0x2028 || n == 0x2029 = True
    | n >= 0x202a && n <= 0x202e = True
    | n >= 0x2066 && n <= 0x2069 = True
    | otherwise = False
  where
    n = ord c

{- | Replace every control character that could disturb a terminal by its
@\\uNNNN@ form. Newline and tab are kept, and so is a carriage return that
is directly followed by a newline. Text without such characters is returned
unchanged.
-}
escapeControl :: Text -> Text
escapeControl t
    | T.all safe t = t
    | otherwise = T.pack (go (T.unpack t))
  where
    safe c = not (needsEscape c) && c /= '\r'
    go [] = []
    go ('\r' : '\n' : rest) = '\r' : '\n' : go rest
    go (c : rest)
        | needsEscape c || c == '\r' = visible c <> go rest
        | otherwise = c : go rest
    visible c =
        let hex = showHex (ord c) ""
         in "\\u" <> replicate (4 - length hex) '0' <> hex
