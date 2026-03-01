module Iidy.Output.Renderer
  ( OutputMode(..)
  ) where

-- | Output rendering mode
data OutputMode
  = OutputPlain        -- ^ No colors, no spinners (CI/logs)
  | OutputInteractive  -- ^ Colors, spinners, timestamps (default if TTY)
  | OutputJson         -- ^ JSONL format for automation
  deriving stock (Show, Eq, Ord)
