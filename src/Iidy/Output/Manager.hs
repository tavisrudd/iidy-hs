module Iidy.Output.Manager
  ( DynamicOutputManager(..)
  , OutputOptions(..)
  , OutputDispatch(..)
  , defaultOutputOptions
  , newOutputManager
  , mkOutputDispatch
  , renderOutput
  ) where

import Data.IORef
import Iidy.Cli (GlobalOpts(..))
import Iidy.Output.Color (IidyTheme)
import Iidy.Output.Renderer (OutputMode(..))
import Iidy.Output.Renderers.Interactive
  (InteractiveRenderer, InteractiveOptions(..), newInteractiveRenderer,
   renderOutputData)
import Iidy.Output.Renderers.Json
  (JsonRenderer, JsonOptions(..), newJsonRenderer, defaultJsonOptions,
   renderOutputDataJson)
import Iidy.Output.Terminal (TerminalCapabilities(..), detectCapabilities)
import Iidy.Output.Theme (ColorTheme(..), resolveTheme)
import Iidy.Output.Types (OutputData)
import qualified Iidy.Types as T

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

------------------------------------------------------------------------
-- Unified dispatch
------------------------------------------------------------------------

-- | Unified output dispatch: wraps either an InteractiveRenderer or JsonRenderer.
data OutputDispatch
  = DispatchInteractive !InteractiveRenderer
  | DispatchJson !JsonRenderer

-- | Render a single OutputData through the dispatch.
renderOutput :: OutputDispatch -> OutputData -> IO ()
renderOutput (DispatchInteractive r) od = renderOutputData r od
renderOutput (DispatchJson r) od        = renderOutputDataJson r od

-- | Create an OutputDispatch from CLI GlobalOpts.
-- Maps color/theme/output-mode flags to the appropriate renderer.
mkOutputDispatch :: GlobalOpts -> IO OutputDispatch
mkOutputDispatch go = do
  caps <- detectCapabilities
  let -- Resolve output mode
      mode = case goOutputMode go of
        Just T.Json        -> OutputJson
        Just T.Plain       -> OutputPlain
        Just T.Interactive -> OutputInteractive
        Nothing
          | tcIsTty caps   -> OutputInteractive
          | otherwise      -> OutputPlain
      -- Resolve color: --color flag overrides auto-detection
      colorsEnabled = case goColor go of
        T.ColorAlways -> True
        T.ColorNever  -> False
        T.ColorAuto   -> case mode of
          OutputJson  -> False
          OutputPlain -> False
          OutputInteractive -> tcHasColor caps
      -- Map CLI Theme to output ColorTheme
      colorTheme = case goTheme go of
        T.ThemeAuto         -> ThemeAuto
        T.ThemeDark         -> ThemeDark
        T.ThemeLight        -> ThemeLight
        T.ThemeHighContrast -> ThemeHighContrast
  case mode of
    OutputJson -> pure $ DispatchJson (newJsonRenderer defaultJsonOptions)
    _ -> do
      r <- newInteractiveRenderer InteractiveOptions
        { ioTheme          = colorTheme
        , ioShowTimestamps = True
        , ioEnableSpinners = mode == OutputInteractive
        , ioEnableAnsi     = colorsEnabled
        , ioTerminalWidth  = tcWidth caps
        }
      pure $ DispatchInteractive r
