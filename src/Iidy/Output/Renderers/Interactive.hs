{- | Interactive renderer for terminal output with colors, spinners, and timestamps.

Handles all console output formatting, including ANSI colors, column alignment,
spinner management, and section-based ordering for CloudFormation operations.

This module re-exports everything from its sub-modules:

  * "Iidy.Output.Renderers.Interactive.Types" -- Types, constructors, formatting helpers, spinner management
  * "Iidy.Output.Renderers.Interactive.Sections" -- Per-variant rendering functions

The 'renderOutputData' dispatch function lives here to avoid circular imports
(it references both spinner management from Types and render functions from Sections).
-}
module Iidy.Output.Renderers.Interactive (
    -- * Re-exported from Types
    InteractiveRenderer (..),
    InteractiveOptions (..),
    defaultInteractiveOptions,
    plainInteractiveOptions,
    newInteractiveRenderer,
    newInteractiveRendererWithHandles,

    -- * Constants
    column2Start,
    minStatusPadding,
    maxPadding,
    resourceTypePadding,
    defaultScreenWidth,

    -- * Formatting helpers (exported for testing)
    formatSectionHeading,
    formatSectionLabel,
    formatSectionEntry,
    formatLogicalId,
    formatTimestampText,
    renderTimestamp,
    styleMuted,
    calcPadding,
    padRight,
    prettyFormatTags,
    prettyFormatParameters,
    formatTokenSource,

    -- * Spinner management
    startSpinner,
    stopSpinner,
    formatTimingText,

    -- * Main dispatch
    renderOutputData,
) where

import Data.Text.IO qualified as TIO
import Iidy.Output.Renderers.Interactive.Sections
import Iidy.Output.Renderers.Interactive.Types
import Iidy.Output.Types

------------------------------------------------------------------------
-- Main dispatch
------------------------------------------------------------------------

renderOutputData :: InteractiveRenderer -> OutputData -> IO ()
renderOutputData r od = do
    -- Clear spinner before rendering any output that isn't spinner-managed
    case od of
        OdNewStackEvents _ -> pure () -- manages its own spinner lifecycle
        OdPollingStarted _ -> pure () -- starts spinner
        OdTokenInfo _ -> pure () -- no-op
        _ -> stopSpinner r
    case od of
        OdCommandMetadata meta -> renderCommandMetadata r meta
        OdStackDefinition def showT -> renderStackDefinition r def showT
        OdStackEvents evts -> renderStackEvents r evts
        OdStackContents contents -> renderStackContents r contents
        OdStatusUpdate upd -> renderStatusUpdate r upd
        OdCommandResult res -> renderCommandResult r res
        OdFinalCommandSummary summ -> renderFinalCommandSummary r summ
        OdStackList lst -> renderStackList r lst
        OdChangeSetResult cs -> renderChangesetResult r cs
        OdStackDrift drift -> renderStackDrift r drift
        OdError err -> renderError r err
        OdTokenInfo _ -> pure ()
        OdNewStackEvents evts -> renderNewStackEvents r evts
        OdOperationComplete info -> renderOperationComplete r info
        OdInactivityTimeout info -> renderInactivityTimeout r info
        OdConfirmationPrompt req -> renderConfirmationPrompt r req
        OdStackChangeDetails details -> renderStackChangeDetails r details
        OdStackAbsentInfo info -> renderStackAbsentInfo r info
        OdCostEstimate est -> renderCostEstimate r est
        OdStackTemplate tmpl -> renderStackTemplate r tmpl
        OdApprovalRequestResult res -> renderApprovalRequestResult r res
        OdTemplateValidation val -> renderTemplateValidation r val
        OdApprovalStatus st -> renderApprovalStatus r st
        OdTemplateDiff diff -> renderTemplateDiff r diff
        OdApprovalResult res -> renderApprovalResult r res
        OdPollingStarted msg -> startSpinner r msg
        OdRawOutput txt -> TIO.putStr txt
