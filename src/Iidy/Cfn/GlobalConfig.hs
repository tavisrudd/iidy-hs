{-# LANGUAGE OverloadedRecordDot #-}
-- | Global SSM configuration for iidy.
--
-- Reads parameters from SSM Parameter Store under the @\/iidy\/@ path and
-- applies them to 'StackArgs' before a CFN operation runs.  This mirrors
-- the Rust implementation in @src\/cfn\/stack_args.rs:324-393@.
--
-- Parameters currently recognised:
--
--   * @\/iidy\/default-notification-arn@ -- SNS topic ARN appended to
--     'saNotificationArns'.  Note: SNS topic validation is skipped because
--     @amazonka-sns@ is incompatible with GHC 9.10.3 \/ base 4.20.  The ARN
--     is appended unconditionally (same runtime effect when the topic is
--     reachable; a downstream AWS error surfaces it otherwise).
--   * @\/iidy\/disable-template-approval@ -- if the value is @\"true\"@
--     (case-insensitive) and 'saApprovedTemplateLocation' is set, clears it.
--
-- All errors are swallowed silently so that missing IAM permissions do not
-- block normal usage.
module Iidy.Cfn.GlobalConfig
  ( applyGlobalConfiguration
    -- * Pure helpers (exported for testing)
  , applyParams
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Conduit (runConduit, (.|))
import qualified Data.Conduit.List as CL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Lens.Micro ((^.))
import System.IO (hPutStrLn, stderr)

import qualified Amazonka
import qualified Amazonka.SSM.GetParametersByPath as GBP
import qualified Amazonka.SSM.Types.Parameter as SSMP

import Iidy.Cfn.Types (StackArgs(..))

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- | Apply global iidy configuration from SSM Parameter Store.
--
-- Fetches all parameters under @\/iidy\/@ with decryption enabled and
-- applies recognised ones to the supplied 'StackArgs'.  Any exception
-- (network, permissions, etc.) is caught and silently ignored so that
-- callers without SSM access are not blocked.
applyGlobalConfiguration :: Amazonka.Env -> StackArgs -> IO StackArgs
applyGlobalConfiguration awsEnv stackArgs = do
  result <- try @SomeException (fetchParametersByPath awsEnv "/iidy/")
  case result of
    Left _ex ->
      -- Silently continue -- missing permissions or SSM unavailable
      pure stackArgs
    Right params ->
      applyParams stackArgs params

------------------------------------------------------------------------
-- Parameter application
------------------------------------------------------------------------

-- | Apply a list of (name, value) pairs to 'StackArgs'.
applyParams :: StackArgs -> [(Text, Text)] -> IO StackArgs
applyParams = go
  where
    go sa []                     = pure sa
    go sa ((name, value) : rest) = do
      sa' <- applyParam sa name value
      go sa' rest

-- | Apply a single SSM parameter to 'StackArgs'.
applyParam :: StackArgs -> Text -> Text -> IO StackArgs
applyParam sa name value =
  case name of
    "/iidy/default-notification-arn" ->
      -- Append the ARN to the notification list.
      -- SNS topic validation (GetTopicAttributes) is skipped here because
      -- amazonka-sns is incompatible with GHC 9.10.3 / base 4.20.
      -- A bad ARN will produce an AWS error on first use (create-stack, etc.).
      let existing = fromMaybe [] (saNotificationArns sa)
      in pure sa { saNotificationArns = Just (existing ++ [value]) }

    "/iidy/disable-template-approval" ->
      if T.toLower value == "true"
        then case saApprovedTemplateLocation sa of
               Just _ -> do
                 hPutStrLn stderr $
                   "Disabling template approval based on global "
                   <> T.unpack name
                   <> " parameter store configuration"
                 pure sa { saApprovedTemplateLocation = Nothing }
               Nothing -> pure sa
        else pure sa

    _ -> pure sa

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

-- | Fetch all parameters under the given SSM path (non-recursive, with
-- decryption).  Paginates through all pages to avoid silent truncation
-- at the default SSM page size (max 10 results per page).
-- Returns a list of (name, value) pairs.
fetchParametersByPath :: Amazonka.Env -> Text -> IO [(Text, Text)]
fetchParametersByPath awsEnv path = runResourceT $ do
  let req = (GBP.newGetParametersByPath path)
              { GBP.withDecryption = Just True }
  pages <- runConduit $ Amazonka.paginate awsEnv req .| CL.consume
  let params = concatMap (fromMaybe [] . (.parameters)) pages
  pure [ (p ^. SSMP.parameter_name, p ^. SSMP.parameter_value)
       | p <- params
       ]
