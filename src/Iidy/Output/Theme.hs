module Iidy.Output.Theme (
    ColorTheme (..),
    resolveTheme,
) where

import Iidy.Output.Color (IidyTheme, darkTheme, highContrastTheme, lightTheme, noColorTheme)

-- | Color theme selection
data ColorTheme
    = ThemeAuto
    | ThemeDark
    | ThemeLight
    | ThemeHighContrast
    deriving stock (Show, Eq, Ord)

-- | Resolve a ColorTheme + enabled flag to an IidyTheme
resolveTheme :: Bool -> ColorTheme -> IidyTheme
resolveTheme colorsEnabled themeChoice
    | not colorsEnabled = noColorTheme
    | otherwise = case themeChoice of
        ThemeAuto -> darkTheme
        ThemeDark -> darkTheme
        ThemeLight -> lightTheme
        ThemeHighContrast -> highContrastTheme
