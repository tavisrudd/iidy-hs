module Iidy.Output.Color
  ( -- * Dynamic color type
    DynColor(..)
  , colorToSgr
    -- * Theme type
  , IidyTheme(..)
  , darkTheme
  , lightTheme
  , highContrastTheme
  , noColorTheme
    -- * Color application
  , colorize
  , colorizeBold
  , colorizeOnBg
  , bold
  , resetCode
    -- * Semantic color helpers
  , colorizeResourceStatus
  , colorizeResourceStatusText
  , colorByEnvironment
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Iidy.Cfn.Status (StackStatus, toText)
import Iidy.Output.Status (StatusCategory (..), categorizeStatus)

------------------------------------------------------------------------
-- Dynamic color type (matches Rust's owo_colors::DynColors)
------------------------------------------------------------------------

data DynColor
  = AnsiDefault
  | AnsiBlack
  | AnsiRed
  | AnsiGreen
  | AnsiYellow
  | AnsiBrightYellow  -- needed for alias
  | AnsiMagenta
  | AnsiWhite
  | AnsiBrightWhite
  | AnsiBrightRed
  | AnsiBrightGreen
  | AnsiBrightBlue
  | AnsiBrightMagenta
  | AnsiBrightBlack
  | AnsiBrightCyan
  | Rgb !Int !Int !Int
  deriving stock (Show, Eq)

-- | Convert DynColor to ANSI SGR foreground code
colorToSgr :: DynColor -> Text
colorToSgr = \case
  AnsiDefault       -> "39"
  AnsiBlack         -> "30"
  AnsiRed           -> "31"
  AnsiGreen         -> "32"
  AnsiYellow        -> "33"
  AnsiBrightYellow  -> "93"
  AnsiMagenta       -> "35"
  AnsiWhite         -> "37"
  AnsiBrightWhite   -> "97"
  AnsiBrightRed     -> "91"
  AnsiBrightGreen   -> "92"
  AnsiBrightBlue    -> "94"
  AnsiBrightMagenta -> "95"
  AnsiBrightBlack   -> "90"
  AnsiBrightCyan    -> "96"
  Rgb r g b         -> "38;2;" <> T.pack (show r) <> ";" <> T.pack (show g) <> ";" <> T.pack (show b)

-- | Convert DynColor to ANSI SGR background code
colorToBgSgr :: DynColor -> Text
colorToBgSgr = \case
  AnsiDefault       -> "49"
  AnsiBlack         -> "40"
  AnsiRed           -> "41"
  AnsiGreen         -> "42"
  AnsiYellow        -> "43"
  AnsiBrightYellow  -> "103"
  AnsiMagenta       -> "45"
  AnsiWhite         -> "47"
  AnsiBrightWhite   -> "107"
  AnsiBrightRed     -> "101"
  AnsiBrightGreen   -> "102"
  AnsiBrightBlue    -> "104"
  AnsiBrightMagenta -> "105"
  AnsiBrightBlack   -> "100"
  AnsiBrightCyan    -> "106"
  Rgb r g b         -> "48;2;" <> T.pack (show r) <> ";" <> T.pack (show g) <> ";" <> T.pack (show b)

------------------------------------------------------------------------
-- Theme type (matches Rust's IidyTheme)
------------------------------------------------------------------------

data IidyTheme = IidyTheme
  { thColorsEnabled   :: !Bool
  , thTimestamp       :: !DynColor   -- ^ xterm 253 (light gray)
  , thResourceId      :: !DynColor   -- ^ xterm 252 (light gray)
  , thSectionHeading  :: !DynColor   -- ^ xterm 255 (white)
  , thMuted           :: !DynColor   -- ^ truecolor(128,128,128)
  , thPrimary         :: !DynColor   -- ^ magenta
  , thSuccess         :: !DynColor   -- ^ green
  , thError           :: !DynColor   -- ^ red
  , thWarning         :: !DynColor   -- ^ yellow
  , thInfo            :: !DynColor   -- ^ white
  , thSkipped         :: !DynColor   -- ^ xterm 240 (dark gray)
  , thEnvProduction   :: !DynColor   -- ^ red
  , thEnvIntegration  :: !DynColor   -- ^ xterm 75 (blue)
  , thEnvDevelopment  :: !DynColor   -- ^ xterm 194 (green)
  } deriving stock (Show, Eq)

-- | Dark theme - exact iidy-js colors
darkTheme :: IidyTheme
darkTheme = IidyTheme
  { thColorsEnabled   = True
  , thTimestamp       = Rgb 212 212 212   -- xterm 253
  , thResourceId      = Rgb 198 198 198   -- xterm 252
  , thSectionHeading  = Rgb 238 238 238   -- xterm 255
  , thMuted           = Rgb 128 128 128   -- blackBright
  , thPrimary         = AnsiMagenta
  , thSuccess         = AnsiGreen
  , thError           = AnsiRed
  , thWarning         = AnsiYellow
  , thInfo            = AnsiWhite
  , thSkipped         = Rgb 88 88 88      -- xterm 240
  , thEnvProduction   = AnsiRed
  , thEnvIntegration  = Rgb 95 175 255    -- xterm 75
  , thEnvDevelopment  = Rgb 215 255 215   -- xterm 194
  }

-- | Light theme - adjusted for light backgrounds
lightTheme :: IidyTheme
lightTheme = IidyTheme
  { thColorsEnabled   = True
  , thTimestamp       = Rgb 105 105 105
  , thResourceId      = Rgb 70 70 70
  , thSectionHeading  = AnsiBlack
  , thMuted           = Rgb 105 105 105
  , thPrimary         = Rgb 163 21 21
  , thSuccess         = Rgb 34 139 34
  , thError           = Rgb 220 20 60
  , thWarning         = Rgb 255 140 0
  , thInfo            = Rgb 70 130 180
  , thSkipped         = Rgb 169 169 169
  , thEnvProduction   = Rgb 220 20 60
  , thEnvIntegration  = Rgb 70 130 180
  , thEnvDevelopment  = Rgb 218 165 32
  }

-- | High contrast theme for accessibility
highContrastTheme :: IidyTheme
highContrastTheme = IidyTheme
  { thColorsEnabled   = True
  , thTimestamp       = AnsiBrightWhite
  , thResourceId      = AnsiBrightCyan
  , thSectionHeading  = AnsiBrightWhite
  , thMuted           = AnsiWhite
  , thPrimary         = AnsiBrightMagenta
  , thSuccess         = AnsiBrightGreen
  , thError           = AnsiBrightRed
  , thWarning         = AnsiBrightYellow
  , thInfo            = AnsiBrightWhite
  , thSkipped         = AnsiBrightBlack
  , thEnvProduction   = AnsiBrightRed
  , thEnvIntegration  = AnsiBrightBlue
  , thEnvDevelopment  = AnsiBrightYellow
  }

-- | No-color theme
noColorTheme :: IidyTheme
noColorTheme = IidyTheme
  { thColorsEnabled   = False
  , thTimestamp       = AnsiDefault
  , thResourceId      = AnsiDefault
  , thSectionHeading  = AnsiDefault
  , thMuted           = AnsiDefault
  , thPrimary         = AnsiDefault
  , thSuccess         = AnsiDefault
  , thError           = AnsiDefault
  , thWarning         = AnsiDefault
  , thInfo            = AnsiDefault
  , thSkipped         = AnsiDefault
  , thEnvProduction   = AnsiDefault
  , thEnvIntegration  = AnsiDefault
  , thEnvDevelopment  = AnsiDefault
  }

------------------------------------------------------------------------
-- Color application
------------------------------------------------------------------------

resetCode :: Text
resetCode = "\ESC[0m"

-- | Apply foreground color to text
colorize :: IidyTheme -> DynColor -> Text -> Text
colorize theme color t
  | thColorsEnabled theme = "\ESC[" <> colorToSgr color <> "m" <> t <> resetCode
  | otherwise = t

-- | Apply foreground color + bold to text
colorizeBold :: IidyTheme -> DynColor -> Text -> Text
colorizeBold theme color t
  | thColorsEnabled theme = "\ESC[1;" <> colorToSgr color <> "m" <> t <> resetCode
  | otherwise = t

-- | Apply background color + foreground to text
colorizeOnBg :: IidyTheme -> DynColor -> DynColor -> Text -> Text
colorizeOnBg theme fg bg t
  | thColorsEnabled theme = "\ESC[" <> colorToSgr fg <> ";" <> colorToBgSgr bg <> "m" <> t <> resetCode
  | otherwise = t

-- | Bold only
bold :: IidyTheme -> Text -> Text
bold theme t
  | thColorsEnabled theme = "\ESC[1m" <> t <> resetCode
  | otherwise = t

------------------------------------------------------------------------
-- Semantic helpers
------------------------------------------------------------------------

-- | Colorize a CloudFormation resource status.
-- Takes a StackStatus ADT and renders it with the appropriate color.
-- The displayed text is the AWS-style string (e.g., "CREATE_COMPLETE").
colorizeResourceStatus :: IidyTheme -> StackStatus -> Text
colorizeResourceStatus theme status =
  let statusText = toText status
  in case categorizeStatus status of
    StatusInProgress -> colorize theme (thWarning theme) statusText
    StatusComplete   -> colorize theme (thSuccess theme) statusText
    StatusFailed     -> colorize theme (thError theme) statusText
    StatusSkipped    -> colorize theme (thSkipped theme) statusText
    StatusUnknown    -> colorize theme (thInfo theme) statusText

-- | Colorize arbitrary text using the color appropriate for a given StackStatus.
-- Used when the text has been padded or otherwise modified before colorizing.
colorizeResourceStatusText :: IidyTheme -> StackStatus -> Text -> Text
colorizeResourceStatusText theme status txt = case categorizeStatus status of
  StatusInProgress -> colorize theme (thWarning theme) txt
  StatusComplete   -> colorize theme (thSuccess theme) txt
  StatusFailed     -> colorize theme (thError theme) txt
  StatusSkipped    -> colorize theme (thSkipped theme) txt
  StatusUnknown    -> colorize theme (thInfo theme) txt

-- | Color text by environment name
colorByEnvironment :: IidyTheme -> Text -> Text -> Text
colorByEnvironment theme envName t = case envName of
  "production"  -> colorize theme (thEnvProduction theme) t
  "integration" -> colorize theme (thEnvIntegration theme) t
  "development" -> colorize theme (thEnvDevelopment theme) t
  _             -> t
