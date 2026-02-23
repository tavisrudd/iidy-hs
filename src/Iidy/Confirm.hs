-- | Shared confirmation prompt for all commands.
--
-- Provides a consistent confirmation prompt with TTY detection,
-- ANSI colors (bold bright red), and input validation.
-- Matches Rust's confirmation display format.
module Iidy.Confirm
  ( requestConfirmation
  -- * Internal (exported for testing)
  , isConfirmation
  ) where

import Data.Char (toLower)
import System.IO (hFlush, hIsTerminalDevice, hSetBuffering, stdin, stdout, BufferMode(..))

-- | Ask the user to confirm an action on the terminal.
-- Returns True if the user types "y" or "yes", False otherwise.
-- Formats with "? " prefix and bold bright red message text to match Rust.
requestConfirmation :: String -> IO Bool
requestConfirmation prompt = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout NoBuffering
  isTty <- hIsTerminalDevice stdout
  putStrLn ""  -- blank line before prompt
  if isTty
    then putStr $ "? \ESC[1;91m" <> prompt <> "\ESC[0m (y/N) "
    else putStr $ "? " <> prompt <> " (y/N) "
  hFlush stdout
  answer <- getLine
  pure $ isConfirmation answer

-- | Pure check: is the user's input a confirmation ("y" or "yes", case-insensitive)?
isConfirmation :: String -> Bool
isConfirmation answer = map toLower answer `elem` ["y", "yes"]
