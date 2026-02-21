module Iidy.Output.Manager
  ( DynamicOutputManager(..)
  , OutputOptions(..)
  , defaultOutputOptions
  , newOutputManager
  ) where

import Data.IORef
import Iidy.Output.Color (IidyTheme)
import Iidy.Output.Renderer (OutputMode(..))
import Iidy.Output.Terminal (TerminalCapabilities(..), detectCapabilities)
import Iidy.Output.Theme (ColorTheme(..), resolveTheme)
import Iidy.Output.Types (OutputData)

-- | Options for output configuration
data OutputOptions = OutputOptions
  { ooMode          :: !(Maybe OutputMode)  -- ^ Override auto-detect
  , ooColorTheme    :: !ColorTheme
  , ooShowTimestamps :: !Bool
  , ooShowSpinners  :: !Bool
  } deriving stock (Show, Eq)

-- | Default output options (auto-detect everything)
defaultOutputOptions :: OutputOptions
defaultOutputOptions = OutputOptions
  { ooMode          = Nothing
  , ooColorTheme    = ThemeAuto
  , ooShowTimestamps = True
  , ooShowSpinners  = True
  }

-- | Dynamic output manager that delegates to the appropriate renderer
data DynamicOutputManager = DynamicOutputManager
  { domMode         :: !OutputMode
  , domTheme        :: !IidyTheme
  , domCapabilities :: !TerminalCapabilities
  , domOptions      :: !OutputOptions
  , domBufferRef    :: !(IORef [OutputData])
  }

-- | Create a new output manager, auto-detecting mode if not specified
newOutputManager :: OutputOptions -> IO DynamicOutputManager
newOutputManager opts = do
  caps <- detectCapabilities
  let mode = case ooMode opts of
        Just m  -> m
        Nothing
          | tcIsTty caps -> OutputInteractive
          | otherwise    -> OutputPlain
      colorsEnabled = case mode of
        OutputJson  -> False
        OutputPlain -> False
        OutputInteractive -> tcHasColor caps
      theme = resolveTheme colorsEnabled (ooColorTheme opts)
  bufRef <- newIORef []
  pure DynamicOutputManager
    { domMode         = mode
    , domTheme        = theme
    , domCapabilities = caps
    , domOptions      = opts
    , domBufferRef    = bufRef
    }
