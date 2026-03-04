module Iidy.Yaml.Errors.Display (
    formatError,
    formatSourceContext,
    ErrorColors (..),
    defaultColors,
    noColors,
    detectErrorColors,
    formatGuidance,
    formatFooter,
) where

import Data.Text (Text)
import Data.Text qualified as T
import Iidy.Types (ColorChoice (..))
import Iidy.Yaml.Errors.Enhanced
import Iidy.Yaml.Errors.Ids (ErrorId, showErrorId)
import Iidy.Yaml.Location (SourceLocation (..))
import System.Environment (lookupEnv)
import System.IO (hIsTerminalDevice, stderr)

------------------------------------------------------------------------
-- Color scheme
------------------------------------------------------------------------

data ErrorColors = ErrorColors
    { ecBoldRed :: !Text -- error type header
    , ecRed :: !Text -- carets
    , ecCyan :: !Text -- file locations
    , ecGrey :: !Text -- context lines
    , ecLightBlue :: !Text -- guidance/help
    , ecDarkGrey :: !Text -- line numbers
    , ecReset :: !Text
    }
    deriving stock (Show)

defaultColors :: ErrorColors
defaultColors =
    ErrorColors
        { ecBoldRed = "\ESC[1;31m"
        , ecRed = "\ESC[31m"
        , ecCyan = "\ESC[36m"
        , ecGrey = "\ESC[38;5;245m"
        , ecLightBlue = "\ESC[38;5;75m"
        , ecDarkGrey = "\ESC[90m"
        , ecReset = "\ESC[0m"
        }

noColors :: ErrorColors
noColors = ErrorColors "" "" "" "" "" "" ""

-- | Detect error colors from CLI --color flag, NO_COLOR, FORCE_COLOR, and stderr TTY.
detectErrorColors :: ColorChoice -> IO ErrorColors
detectErrorColors ColorAlways = pure defaultColors
detectErrorColors ColorNever = pure noColors
detectErrorColors ColorAuto = do
    noColorEnv <- lookupEnv "NO_COLOR"
    forceColorEnv <- lookupEnv "FORCE_COLOR"
    case (noColorEnv, forceColorEnv) of
        (Just _, _) -> pure noColors -- NO_COLOR takes precedence
        (_, Just _) -> pure defaultColors -- FORCE_COLOR forces colors on
        _ -> do
            isTty <- hIsTerminalDevice stderr
            pure $ if isTty then defaultColors else noColors

------------------------------------------------------------------------
-- Format enhanced errors
------------------------------------------------------------------------

formatError :: ErrorColors -> Text -> EnhancedPreprocessingError -> Text
formatError c source = \case
    VariableNotFoundError info ->
        formatHeader c "Variable error" ("'" <> vnfVariable info <> "' not found") (vnfLocation info) (vnfErrorId info)
            <> formatGuidance c "variable not defined in current scope"
            <> formatSourceContext c source (vnfLocation info) (T.length (vnfVariable info) + 3) "variable not defined"
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
            <> formatSourceContext c source (ysiLocation info) 1 ""
            <> formatFixHint c (ysiFixHint info)
            <> formatExampleInline c (ysiExample info)
            <> "\n"
            <> formatFooter c (ysiErrorId info)
    TagParsingError info
        | tpiSpanLen info > 0 ->
            -- Unknown tag errors with carets
            formatHeader c "Tag error" (tpiMessage info) (tpiLocation info) (tpiErrorId info)
                <> maybe "" (formatGuidance c) (tpiGuidance info)
                <> formatSourceContext c source (tpiLocation info) (tpiSpanLen info) ""
                <> formatExample c (tpiSuggestion info)
                <> formatFooter c (tpiErrorId info)
        | otherwise ->
            formatHeader c "Tag error" (tpiMessage info) (tpiLocation info) (tpiErrorId info)
                <> maybe "" (formatGuidance c) (tpiGuidance info)
                <> formatSourceContextNoCarets c source (tpiLocation info)
                <> formatExample c (tpiSuggestion info)
                <> formatFooter c (tpiErrorId info)
    LookupQueryError info ->
        let keys = lqiAvailableKeys info
            keysSection = if null keys then "\n\n" else formatAvailableKeys c keys
         in formatHeader c "Lookup error" (lqiMessage info) (lqiLocation info) (lqiErrorId info)
                <> formatGuidance c ("query failed on variable '" <> lqiVariablePath info <> "'")
                <> formatSourceContext c source (lqiLocation info) 1 (lqiMessage info)
                <> keysSection
                <> formatFooter c (lqiErrorId info)

------------------------------------------------------------------------
-- Formatting helpers
------------------------------------------------------------------------

formatHeader :: ErrorColors -> Text -> Text -> SourceLocation -> ErrorId -> Text
formatHeader c errType msg loc eid =
    ecBoldRed c
        <> errType
        <> ecReset c
        <> ": "
        <> msg
        <> " @ "
        <> ecCyan c
        <> formatLocation loc
        <> ecReset c
        <> ecGrey c
        <> " (errno: "
        <> showErrorId eid
        <> ")"
        <> ecReset c
        <> "\n"

formatLocation :: SourceLocation -> Text
formatLocation loc =
    srcLocFile loc <> ":" <> T.pack (show (srcLocLine loc)) <> ":" <> T.pack (show (srcLocColumn loc))

formatGuidance :: ErrorColors -> Text -> Text
formatGuidance c msg =
    "  " <> ecLightBlue c <> "-> " <> msg <> ecReset c <> "\n\n"

{- | Format source context with carets on the current line.
Line numbers are right-aligned in a fixed 4-character gutter (matching Rust's {:4}).
-}
formatSourceContext :: ErrorColors -> Text -> SourceLocation -> Int -> Text -> Text
formatSourceContext c source loc spanLen inlineDesc =
    let allLines = T.lines source
        lineNum = srcLocLine loc -- 1-based
        col = srcLocColumn loc -- 1-based
        prevLine = getSourceLine allLines (lineNum - 1)
        currLine = getSourceLine allLines lineNum
        nextLine = getSourceLine allLines (lineNum + 1)
        -- Skip carets when spanLen is 0, column is 0, or past end of line
        showCarets =
            spanLen > 0 && case currLine of
                Just l -> col > 0 && col <= T.length l
                Nothing -> False
     in T.concat
            [ -- Previous line (grey)
              maybe
                ""
                ( \l ->
                    ecDarkGrey c <> padGutter4 (lineNum - 1) <> ecReset c <> " | " <> ecGrey c <> l <> ecReset c <> "\n"
                )
                prevLine
            , -- Current line
              maybe
                ""
                ( \l ->
                    ecRed c <> padGutter4 lineNum <> ecReset c <> " | " <> l <> "\n"
                )
                currLine
            , -- Caret line (only when column is within the line)
              if showCarets
                then
                    let lineLen = maybe 0 T.length currLine
                        effectiveSpan = max 1 (min spanLen (lineLen - col + 1))
                     in "     | "
                            <> T.replicate (max 0 (col - 1)) " "
                            <> ecRed c
                            <> T.replicate effectiveSpan "^"
                            <> ecReset c
                            <> (if T.null inlineDesc then "" else " " <> ecGrey c <> inlineDesc <> ecReset c)
                            <> "\n"
                else ""
            , -- Next line (grey)
              maybe
                ""
                ( \l ->
                    ecDarkGrey c <> padGutter4 (lineNum + 1) <> ecReset c <> " | " <> ecGrey c <> l <> ecReset c <> "\n"
                )
                nextLine
            ]

-- | Format source context without caret line (for tag errors with missing fields).
formatSourceContextNoCarets :: ErrorColors -> Text -> SourceLocation -> Text
formatSourceContextNoCarets c source loc = formatSourceContext c source loc 0 ""

-- | Right-align a line number in a fixed 4-character field (matching Rust's {:4}).
padGutter4 :: Int -> Text
padGutter4 n =
    let s = show n
        pad = max 0 (4 - length s)
     in T.replicate pad " " <> T.pack s

getSourceLine :: [Text] -> Int -> Maybe Text
getSourceLine lns n
    | n >= 1 = case drop (n - 1) lns of
        (x : _) -> Just x
        _ -> Nothing
    | otherwise = Nothing

-- | Format available variables list (trailing \n for blank line before footer).
formatAvailableVars :: ErrorColors -> [Text] -> Text
formatAvailableVars _ [] = ""
formatAvailableVars c vars =
    "\n"
        <> ecLightBlue c
        <> "   available variables: "
        <> T.intercalate ", " vars
        <> ecReset c
        <> "\n\n"

-- | Format available keys list (trailing \n for blank line before footer).
formatAvailableKeys :: ErrorColors -> [Text] -> Text
formatAvailableKeys _ [] = ""
formatAvailableKeys c keys =
    "\n"
        <> ecLightBlue c
        <> "   available keys: "
        <> T.intercalate ", " keys
        <> ecReset c
        <> "\n\n"

-- | Format type mismatch help text (trailing \n for blank line before footer).
formatTypeMismatchHelp :: ErrorColors -> Text -> Text -> Maybe Text -> Text
formatTypeMismatchHelp c expected found extraHelp =
    let mainHelp = "\n   " <> ecLightBlue c <> "expected " <> expected <> ", found " <> found <> ecReset c <> "\n"
        extra = case extraHelp of
            Nothing -> ""
            Just h -> "   " <> ecLightBlue c <> h <> ecReset c <> "\n"
     in mainHelp <> extra <> "\n"

-- | Format CloudFormation help text (trailing \n for blank line before footer).
formatCfnHelp :: ErrorColors -> Text -> Text -> Text
formatCfnHelp c _tagName helpText =
    "\n   " <> ecLightBlue c <> helpText <> ecReset c <> "\n\n"

-- | Format fix hint.
formatFixHint :: ErrorColors -> Maybe Text -> Text
formatFixHint _ Nothing = ""
formatFixHint c (Just hint) =
    "\n   " <> ecLightBlue c <> "fix: " <> hint <> ecReset c <> "\n"

-- | Format example block for tag errors (always multi-line, matching Rust's tag_example).
formatExample :: ErrorColors -> Maybe Text -> Text
formatExample _ Nothing = ""
formatExample c (Just ex)
    | T.null ex = ""
    | otherwise =
        "\n" <> ecLightBlue c <> "   example:\n   " <> ex <> ecReset c <> "\n"

-- | Format example inline for syntax errors (single line, matching Rust's render_yaml_syntax).
formatExampleInline :: ErrorColors -> Maybe Text -> Text
formatExampleInline _ Nothing = ""
formatExampleInline c (Just ex)
    | T.null ex = ""
    | otherwise =
        ecLightBlue c <> "   example: " <> ex <> ecReset c <> "\n"

-- | Format footer. The leading blank line is controlled by preceding sections.
formatFooter :: ErrorColors -> ErrorId -> Text
formatFooter c eid =
    "   " <> ecLightBlue c <> "For more info: iidy explain " <> showErrorId eid <> ecReset c <> "\n"
