module Iidy.Types
  ( OutputMode(..)
  , ColorChoice(..)
  , Theme(..)
  , YamlSpec(..)
  ) where

data OutputMode = Plain | Interactive | Json
  deriving stock (Show, Eq, Ord)

data ColorChoice = ColorAuto | ColorAlways | ColorNever
  deriving stock (Show, Eq, Ord)

data Theme = ThemeAuto | ThemeLight | ThemeDark | ThemeHighContrast
  deriving stock (Show, Eq, Ord)

data YamlSpec = YamlV11 | YamlV12 | YamlAuto
  deriving stock (Show, Eq, Ord)
