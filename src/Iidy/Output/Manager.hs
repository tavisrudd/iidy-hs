module Iidy.Output.Manager
  ( OutputDispatch(..)
  , mkOutputDispatch
  , renderOutput
  ) where

import Iidy.Cli (GlobalOpts(..))
import Iidy.Output.Renderer (OutputMode(..))
import Iidy.Output.Renderers.Interactive
  (InteractiveRenderer, InteractiveOptions(..), newInteractiveRenderer,
   renderOutputData)
import Iidy.Output.Renderers.Json
  (JsonRenderer, newJsonRenderer, defaultJsonOptions,
   renderOutputDataJson)
import Iidy.Output.Terminal (TerminalCapabilities(..), detectCapabilities)
import Iidy.Output.Theme (ColorTheme(..))
import Iidy.Output.Types (OutputData)
import qualified Iidy.Types as T

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
      -- Note: newInteractiveRenderer calls detectCapabilities internally,
      -- duplicating the check above. This is harmless (cheap I/O) but redundant.
      r <- newInteractiveRenderer InteractiveOptions
        { ioTheme          = colorTheme
        , ioShowTimestamps = True
        , ioEnableSpinners = mode == OutputInteractive
        , ioEnableAnsi     = colorsEnabled
        , ioTerminalWidth  = tcWidth caps
        }
      pure $ DispatchInteractive r
