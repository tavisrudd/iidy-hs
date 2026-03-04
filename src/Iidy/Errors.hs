{-# LANGUAGE OverloadedRecordDot #-}

{- | Error handling utilities for iidy-hs.

Formats unhandled exceptions matching Rust's error output style,
strips GHC backtrace noise, and provides common error exit helpers.
-}
module Iidy.Errors (
    handleUncaughtException,
    handleAwsError,
    dieTxt,
    handleEither,
) where

import Amazonka qualified
import Control.Exception (IOException, SomeException, displayException, fromException)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

{- | Format unhandled exceptions matching Rust's error output style.
Strips GHC backtrace noise and formats IO errors cleanly.
Amazonka ServiceErrors get the message extracted; other errors get best-effort formatting.
-}
handleUncaughtException :: SomeException -> IO ()
handleUncaughtException e
    | Just ec <- fromException e = exitWith (ec :: ExitCode)
    | Just awsErr <- fromException e = do
        handleAwsError (awsErr :: Amazonka.Error)
        exitWith (ExitFailure 1)
    | Just ioe <- fromException e = do
        -- IO exceptions: format like Rust's "No such file or directory (os error 2)"
        let msg = displayException (ioe :: IOException)
        hPutStrLn stderr $ "ERROR: " <> firstLine msg
        hPutStrLn stderr "  \x2022 Check the AWS CloudFormation console for more details"
        exitWith (ExitFailure 1)
    | otherwise = do
        let msg = firstLine (displayException e)
        hPutStrLn stderr $ "ERROR: " <> msg
        hPutStrLn stderr "  \x2022 Check the AWS CloudFormation console for more details"
        exitWith (ExitFailure 1)
  where
    firstLine s = case lines s of
        (l : _) -> l
        [] -> s

-- | Format an Amazonka error with the service error message extracted.
handleAwsError :: Amazonka.Error -> IO ()
handleAwsError (Amazonka.ServiceError se) = do
    let Amazonka.ErrorCode code = se.code
        msg = maybe "" Amazonka.fromErrorMessage se.message
        errMsg = T.unpack (code <> ": " <> msg)
    hPutStrLn stderr $ "ERROR: " <> errMsg
    hPutStrLn stderr "  \x2022 Check the AWS CloudFormation console for more details"
handleAwsError err = do
    hPutStrLn stderr $ "ERROR: " <> firstLine' (displayException err)
    hPutStrLn stderr "  \x2022 Check the AWS CloudFormation console for more details"
  where
    firstLine' s = case lines s of
        (l : _) -> l
        [] -> s

-- | Print error to stderr and exit with code 1
dieTxt :: Text -> IO a
dieTxt msg = do
    TIO.hPutStrLn stderr $ "iidy-hs: " <> msg
    exitWith (ExitFailure 1)

-- | Handle Either Text Int result
handleEither :: Either Text Int -> IO Int
handleEither (Left err) = dieTxt err
handleEither (Right rc) = pure rc
