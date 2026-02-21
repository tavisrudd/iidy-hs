module Iidy.Yaml.Errors.Display
  ( formatError
  , formatSourceContext
  , ErrorColors(..)
  , defaultColors
  , noColors
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Iidy.Yaml.Errors.Enhanced
import Iidy.Yaml.Errors.Ids (ErrorId, showErrorId)
import Iidy.Yaml.Location (SourceLocation(..))

------------------------------------------------------------------------
-- Color scheme
------------------------------------------------------------------------

data ErrorColors = ErrorColors
  { ecBoldRed    :: !Text  -- error type header
  , ecRed        :: !Text  -- carets
  , ecCyan       :: !Text  -- file locations
  , ecGrey       :: !Text  -- context lines
  , ecLightBlue  :: !Text  -- guidance/help
  , ecDarkGrey   :: !Text  -- line numbers
  , ecReset      :: !Text
  } deriving stock (Show)

defaultColors :: ErrorColors
defaultColors = ErrorColors
  { ecBoldRed   = "\ESC[1;31m"
  , ecRed       = "\ESC[31m"
  , ecCyan      = "\ESC[36m"
  , ecGrey      = "\ESC[38;5;245m"
  , ecLightBlue = "\ESC[38;5;75m"
  , ecDarkGrey  = "\ESC[90m"
  , ecReset     = "\ESC[0m"
  }

noColors :: ErrorColors
noColors = ErrorColors "" "" "" "" "" "" ""

------------------------------------------------------------------------
-- Format enhanced errors
------------------------------------------------------------------------

formatError :: ErrorColors -> Text -> EnhancedPreprocessingError -> Text
formatError c source = \case
  VariableNotFoundError info ->
    formatHeader c "Variable error" (vnfVariable info <> " not found") (vnfLocation info) (vnfErrorId info)
    <> formatSourceContext c source (vnfLocation info) (T.length (vnfVariable info)) ("not defined")
    <> formatSuggestions c "Available variables" (vnfAvailableVars info)
    <> formatDidYouMean c (vnfSuggestions info)
    <> formatFooter c (vnfErrorId info)

  TypeMismatchError info ->
    formatHeader c "Type error" (tmiContext info) (tmiLocation info) (tmiErrorId info)
    <> formatGuidance c ("expected " <> tmiExpected info <> ", found " <> tmiFound info)
    <> formatSourceContext c source (tmiLocation info) 1 (tmiFound info)
    <> formatHelp c (tmiHelp info)
    <> formatFooter c (tmiErrorId info)

  CfnValidationError info ->
    formatHeader c "CloudFormation error" (cviMessage info) (cviLocation info) (cviErrorId info)
    <> formatGuidance c (cviHelpText info)
    <> formatSourceContext c source (cviLocation info) (T.length (cviTagName info)) (cviMessage info)
    <> formatFooter c (cviErrorId info)

  YamlSyntaxError info ->
    formatHeader c "Syntax error" (ysiShortMessage info) (ysiLocation info) (ysiErrorId info)
    <> formatGuidance c (ysiGuidance info)
    <> formatSourceContext c source (ysiLocation info) 1 (ysiShortMessage info)
    <> formatHelp c (ysiFixHint info)
    <> formatExample c (ysiExample info)
    <> formatFooter c (ysiErrorId info)

  TagParsingError info ->
    formatHeader c "Tag error" (tpiMessage info) (tpiLocation info) (tpiErrorId info)
    <> formatSourceContext c source (tpiLocation info) (tpiSpanLen info) (tpiMessage info)
    <> formatHelp c (tpiSuggestion info)
    <> formatFooter c (tpiErrorId info)

  LookupQueryError info ->
    formatHeader c "Lookup error" (lqiMessage info) (lqiLocation info) (lqiErrorId info)
    <> formatSourceContext c source (lqiLocation info) 1 (lqiMessage info)
    <> formatSuggestions c "Available keys" (lqiAvailableKeys info)
    <> formatFooter c (lqiErrorId info)

------------------------------------------------------------------------
-- Formatting helpers
------------------------------------------------------------------------

formatHeader :: ErrorColors -> Text -> Text -> SourceLocation -> ErrorId -> Text
formatHeader c errType msg loc eid =
  ecBoldRed c <> errType <> ecReset c <> ": " <> msg
  <> " @ " <> ecCyan c <> formatLocation loc <> ecReset c
  <> ecGrey c <> " (errno: " <> showErrorId eid <> ")" <> ecReset c <> "\n"

formatLocation :: SourceLocation -> Text
formatLocation loc =
  srcLocFile loc <> ":" <> T.pack (show (srcLocLine loc)) <> ":" <> T.pack (show (srcLocColumn loc))

formatGuidance :: ErrorColors -> Text -> Text
formatGuidance c msg =
  "  " <> ecLightBlue c <> "-> " <> msg <> ecReset c <> "\n\n"

formatSourceContext :: ErrorColors -> Text -> SourceLocation -> Int -> Text -> Text
formatSourceContext c source loc spanLen inlineDesc =
  let allLines = T.lines source
      lineNum = srcLocLine loc  -- 1-based
      col = srcLocColumn loc    -- 1-based
      prevLine = getSourceLine allLines (lineNum - 1)
      currLine = getSourceLine allLines lineNum
      nextLine = getSourceLine allLines (lineNum + 1)
      gutterWidth = length (show (lineNum + 1))
      padGutter n = let s = show n
                    in T.replicate (gutterWidth - length s) " " <> T.pack s
      emptyGutter = T.replicate gutterWidth " "
  in T.concat
    [ -- Previous line (grey)
      maybe "" (\l ->
        ecDarkGrey c <> padGutter (lineNum - 1) <> " | " <> ecGrey c <> l <> ecReset c <> "\n"
        ) prevLine
    , -- Current line (highlighted line number)
      maybe "" (\l ->
        ecRed c <> padGutter lineNum <> ecReset c <> " | " <> l <> "\n"
        ) currLine
    , -- Caret line
      emptyGutter <> " | " <> T.replicate (max 0 (col - 1)) " "
      <> ecRed c <> T.replicate (max 1 spanLen) "^" <> ecReset c
      <> " " <> inlineDesc <> "\n"
    , -- Next line (grey)
      maybe "" (\l ->
        ecDarkGrey c <> padGutter (lineNum + 1) <> " | " <> ecGrey c <> l <> ecReset c <> "\n"
        ) nextLine
    ]

getSourceLine :: [Text] -> Int -> Maybe Text
getSourceLine lns n
  | n >= 1 && n <= length lns = Just (lns !! (n - 1))
  | otherwise = Nothing

formatSuggestions :: ErrorColors -> Text -> [Text] -> Text
formatSuggestions _ _ [] = ""
formatSuggestions c label items =
  "\n  " <> ecLightBlue c <> label <> ": " <> ecReset c
  <> T.intercalate ", " items <> "\n"

formatDidYouMean :: ErrorColors -> [Text] -> Text
formatDidYouMean _ [] = ""
formatDidYouMean c suggestions =
  "  " <> ecLightBlue c <> "Did you mean: " <> ecReset c
  <> T.intercalate " or " suggestions <> "?\n"

formatHelp :: ErrorColors -> Maybe Text -> Text
formatHelp _ Nothing = ""
formatHelp c (Just help) =
  "\n  " <> ecLightBlue c <> "Help: " <> ecReset c <> help <> "\n"

formatExample :: ErrorColors -> Maybe Text -> Text
formatExample _ Nothing = ""
formatExample c (Just ex) =
  "\n  " <> ecLightBlue c <> "Example:" <> ecReset c <> "\n"
  <> "  " <> ex <> "\n"

formatFooter :: ErrorColors -> ErrorId -> Text
formatFooter c eid =
  "\n  " <> ecGrey c <> "For more info: iidy explain " <> showErrorId eid <> ecReset c <> "\n"
