module Iidy.Output.Renderer (
    OutputMode (..),
) where

-- | Output rendering mode
data OutputMode
    = -- | No colors, no spinners (CI/logs)
      OutputPlain
    | -- | Colors, spinners, timestamps (default if TTY)
      OutputInteractive
    | -- | JSONL format for automation
      OutputJson
    deriving stock (Show, Eq, Ord)
