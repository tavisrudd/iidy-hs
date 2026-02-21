module Iidy.Output.Theme
  ( ColorTheme(..)
  , themeFromEnv
  , resolveTheme
  ) where

import Data.Char (toLower)
import System.Environment (lookupEnv)
import Iidy.Output.Color (IidyTheme, darkTheme, lightTheme, highContrastTheme, noColorTheme)

-- | Color theme selection
data ColorTheme
  = ThemeAuto
  | ThemeDark
  | ThemeLight
  | ThemeHighContrast
  deriving stock (Show, Eq, Ord)

-- | Detect theme from environment variable IIDY_THEME
themeFromEnv :: IO ColorTheme
themeFromEnv = do
  env <- lookupEnv "IIDY_THEME"
  pure $ case fmap (map toLower) env of
    Just "light"          -> ThemeLight
    Just "high-contrast"  -> ThemeHighContrast
    Just "highcontrast"   -> ThemeHighContrast
    Just "dark"           -> ThemeDark
    _                     -> ThemeAuto

-- | Resolve a ColorTheme + enabled flag to an IidyTheme
resolveTheme :: Bool -> ColorTheme -> IidyTheme
resolveTheme colorsEnabled themeChoice
  | not colorsEnabled = noColorTheme
  | otherwise = case themeChoice of
      ThemeAuto         -> darkTheme
      ThemeDark         -> darkTheme
      ThemeLight        -> lightTheme
      ThemeHighContrast -> highContrastTheme
