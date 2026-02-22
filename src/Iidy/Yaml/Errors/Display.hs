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
    formatHeader c "Variable error" ("'" <> vnfVariable info <> "' not found") (vnfLocation info) (vnfErrorId info)
    <> formatGuidance c "variable not defined in current scope"
    <> formatSourceContext c source (vnfLocation info) (T.length (vnfVariable info)) "variable not defined"
    <> formatAvailableVars c (vnfAvailableVars info)
    <> formatFooter c (vnfErrorId info)

  TypeMismatchError info ->
    formatHeader c "Type error" ("expected " <> tmiExpected info <> ", found " <> tmiFound info) (tmiLocation info) (tmiErrorId info)
    <> formatGuidance c "data type mismatch"
    <> formatSourceContext c source (tmiLocation info) 8 ("expected " <> tmiExpected info)
    <> formatTypeMismatchHelp c (tmiExpected info) (tmiFound info) (tmiHelp info)
    <> formatFooter c (tmiErrorId info)

  CfnValidationError info ->
    formatHeader c "CloudFormation error" (cviMessage info) (cviLocation info) (cviErrorId info)
    <> formatGuidance c "invalid CloudFormation intrinsic function"
    <> formatSourceContext c source (cviLocation info) 4 "invalid CloudFormation tag"
    <> formatCfnHelp c (cviTagName info) (cviHelpText info)
    <> formatFooter c (cviErrorId info)

  YamlSyntaxError info ->
    formatHeader c "Syntax error" (ysiShortMessage info) (ysiLocation info) (ysiErrorId info)
    <> formatGuidance c (ysiGuidance info)
    <> formatSourceContext c source (ysiLocation info) 1 (ysiShortMessage info)
    <> formatFixHint c (ysiFixHint info)
    <> formatExample c (ysiExample info)
    <> formatFooter c (ysiErrorId info)

  TagParsingError info ->
    formatHeader c "Tag error" (tpiMessage info) (tpiLocation info) (tpiErrorId info)
    <> maybe "" (formatGuidance c) (tpiGuidance info)
    <> formatSourceContextNoCarets c source (tpiLocation info)
    <> formatExample c (tpiSuggestion info)
    <> formatFooter c (tpiErrorId info)

  LookupQueryError info ->
    formatHeader c "Lookup error" (lqiMessage info) (lqiLocation info) (lqiErrorId info)
    <> formatGuidance c ("query failed on variable '" <> lqiVariablePath info <> "'")
    <> formatSourceContext c source (lqiLocation info) 1 (lqiMessage info)
    <> formatAvailableKeys c (lqiAvailableKeys info)
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

-- | Format source context with carets on the current line.
-- Line numbers are right-aligned in a fixed 4-character gutter (matching Rust's {:4}).
formatSourceContext :: ErrorColors -> Text -> SourceLocation -> Int -> Text -> Text
formatSourceContext c source loc spanLen inlineDesc =
  let allLines = T.lines source
      lineNum = srcLocLine loc  -- 1-based
      col = srcLocColumn loc    -- 1-based
      prevLine = getSourceLine allLines (lineNum - 1)
      currLine = getSourceLine allLines lineNum
      nextLine = getSourceLine allLines (lineNum + 1)
      -- Skip carets when column is past the end of the line content
      showCarets = case currLine of
        Just l  -> col <= T.length l
        Nothing -> False
  in T.concat
    [ -- Previous line (grey)
      maybe "" (\l ->
        ecDarkGrey c <> padGutter4 (lineNum - 1) <> ecReset c <> " | " <> ecGrey c <> l <> ecReset c <> "\n"
        ) prevLine
    , -- Current line
      maybe "" (\l ->
        ecRed c <> padGutter4 lineNum <> ecReset c <> " | " <> l <> "\n"
        ) currLine
    , -- Caret line (only when column is within the line)
      if showCarets
      then let lineLen = maybe 0 T.length currLine
               effectiveSpan = max 1 (min spanLen (lineLen - col + 1))
           in "     | " <> T.replicate (max 0 (col - 1)) " "
              <> ecRed c <> T.replicate effectiveSpan "^" <> ecReset c
              <> " " <> inlineDesc <> "\n"
      else ""
    , -- Next line (grey)
      maybe "" (\l ->
        ecDarkGrey c <> padGutter4 (lineNum + 1) <> ecReset c <> " | " <> ecGrey c <> l <> ecReset c <> "\n"
        ) nextLine
    ]

-- | Format source context without caret line (for tag errors with missing fields).
-- Line numbers are right-aligned in a fixed 4-character gutter (matching Rust's {:4}).
formatSourceContextNoCarets :: ErrorColors -> Text -> SourceLocation -> Text
formatSourceContextNoCarets c source loc =
  let allLines = T.lines source
      lineNum = srcLocLine loc  -- 1-based
      prevLine = getSourceLine allLines (lineNum - 1)
      currLine = getSourceLine allLines lineNum
      nextLine = getSourceLine allLines (lineNum + 1)
  in T.concat
    [ maybe "" (\l ->
        ecDarkGrey c <> padGutter4 (lineNum - 1) <> ecReset c <> " | " <> ecGrey c <> l <> ecReset c <> "\n"
        ) prevLine
    , maybe "" (\l ->
        ecRed c <> padGutter4 lineNum <> ecReset c <> " | " <> l <> "\n"
        ) currLine
    , maybe "" (\l ->
        ecDarkGrey c <> padGutter4 (lineNum + 1) <> ecReset c <> " | " <> ecGrey c <> l <> ecReset c <> "\n"
        ) nextLine
    ]

-- | Right-align a line number in a fixed 4-character field (matching Rust's {:4}).
padGutter4 :: Int -> Text
padGutter4 n =
  let s = show n
      pad = max 0 (4 - length s)
  in T.replicate pad " " <> T.pack s

getSourceLine :: [Text] -> Int -> Maybe Text
getSourceLine lns n
  | n >= 1 && n <= length lns = Just (lns !! (n - 1))
  | otherwise = Nothing

-- | Format available variables list (trailing \n for blank line before footer).
formatAvailableVars :: ErrorColors -> [Text] -> Text
formatAvailableVars _ [] = ""
formatAvailableVars c vars =
  "\n   " <> ecLightBlue c <> "available variables: " <> ecReset c
  <> T.intercalate ", " vars <> "\n\n"

-- | Format available keys list (trailing \n for blank line before footer).
formatAvailableKeys :: ErrorColors -> [Text] -> Text
formatAvailableKeys _ [] = ""
formatAvailableKeys c keys =
  "\n   " <> ecLightBlue c <> "available keys: " <> ecReset c
  <> T.intercalate ", " keys <> "\n\n"

-- | Format type mismatch help text (trailing \n for blank line before footer).
formatTypeMismatchHelp :: ErrorColors -> Text -> Text -> Maybe Text -> Text
formatTypeMismatchHelp _c expected found extraHelp =
  let mainHelp = "\n   " <> "expected " <> expected <> ", found " <> found <> "\n"
      extra = case extraHelp of
        Nothing -> ""
        Just h  -> "   " <> h <> "\n"
  in mainHelp <> extra <> "\n"

-- | Format CloudFormation help text (trailing \n for blank line before footer).
formatCfnHelp :: ErrorColors -> Text -> Text -> Text
formatCfnHelp _c _tagName helpText =
  "\n   " <> helpText <> "\n\n"

-- | Format fix hint.
formatFixHint :: ErrorColors -> Maybe Text -> Text
formatFixHint _ Nothing = ""
formatFixHint _c (Just hint) =
  "\n   " <> hint <> "\n"

-- | Format example block (3-space indent, matching Rust format).
formatExample :: ErrorColors -> Maybe Text -> Text
formatExample _ Nothing = ""
formatExample _ (Just ex)
  | T.null ex = ""
  | otherwise =
      "\n   example:\n   " <> ex <> "\n"

-- | Format footer. The leading blank line is controlled by preceding sections.
formatFooter :: ErrorColors -> ErrorId -> Text
formatFooter c eid =
  "   " <> ecGrey c <> "For more info: iidy explain " <> showErrorId eid <> ecReset c <> "\n"
