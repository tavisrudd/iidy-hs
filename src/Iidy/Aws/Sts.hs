{-# LANGUAGE OverloadedRecordDot #-}

{- | STS (Security Token Service) utilities.

Provides getCallerIdentity for credential provenance display
in error contexts like StackAbsentInfo.
-}
module Iidy.Aws.Sts (
    getCallerIdentity,
) where

import Control.Exception (catch)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import System.IO (hPutStrLn, stderr)

import Amazonka qualified
import Amazonka.STS.GetCallerIdentity qualified as STS
import Control.Monad.Trans.Resource (runResourceT)

{- | Get the current IAM caller identity (account, ARN).
Returns (account, arn). Falls back to ("unknown", "unknown") on error.
-}
getCallerIdentity :: Amazonka.Env -> IO (Text, Text)
getCallerIdentity env = do
    let req = STS.newGetCallerIdentity
    ( do
            resp <- runResourceT $ Amazonka.send env req
            let account = fromMaybe "unknown" resp.account
                arn = fromMaybe "unknown" resp.arn
            pure (account, arn)
        )
        `catch` \(e :: Amazonka.Error) -> do
            hPutStrLn stderr $ "Warning: STS GetCallerIdentity failed: " <> show e
            pure ("unknown", "unknown")
