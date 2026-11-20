module Iidy.Yaml.Location (
    Position (..),
    SourceLocation (..),
    zeroPosition,
) where

import Data.Text (Text)

-- | Source position with line, column, and byte offset
data Position = Position
    { posLine :: !Int
    -- ^ 1-based line number
    , posColumn :: !Int
    {- ^ 0-based column number, as the YAML parser (HsYAML) reports it;
    error displays add 1 to show it 1-based, as Rust does
    -}
    , posOffset :: !Int
    -- ^ Byte offset in source text
    }
    deriving stock (Show, Eq, Ord)

zeroPosition :: Position
zeroPosition = Position 0 0 0

-- | Source location with file path and YAML path context
data SourceLocation = SourceLocation
    { srcLocFile :: !Text
    , srcLocLine :: !Int
    , srcLocColumn :: !Int
    , srcLocYamlPath :: !Text
    }
    deriving stock (Show, Eq)
