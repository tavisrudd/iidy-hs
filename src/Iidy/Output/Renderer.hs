module Iidy.Output.Renderer
  ( OutputRenderer(..)
  , OutputMode(..)
  ) where

import Iidy.Output.Types (OutputData)

-- | Output rendering mode
data OutputMode
  = OutputPlain        -- ^ No colors, no spinners (CI/logs)
  | OutputInteractive  -- ^ Colors, spinners, timestamps (default if TTY)
  | OutputJson         -- ^ JSONL format for automation
  deriving stock (Show, Eq, Ord)

-- | Typeclass for output renderers.
-- Each renderer handles OutputData values according to its mode.
class OutputRenderer r where
  -- | Initialize the renderer
  renderInit :: r -> IO r
  -- | Render a single output data item
  renderOutput :: r -> OutputData -> IO r
  -- | Clean up the renderer (flush buffers, restore terminal)
  renderCleanup :: r -> IO ()
