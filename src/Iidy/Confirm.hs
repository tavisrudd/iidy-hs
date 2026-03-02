-- | Shared confirmation prompt for all commands.
--
-- Provides a consistent confirmation prompt with TTY detection,
-- ANSI colors (bold bright red), and input validation.
-- Matches Rust's confirmation display format.
module Iidy.Confirm
  ( ConfirmResult(..)
  , requestConfirmation
  -- * Internal (exported for testing)
  , isConfirmation
  ) where

import Data.Char (toLower)
import Data.Text (Text)
import qualified Data.Text as T
import System.IO (hFlush, hIsTerminalDevice, hSetBuffering, stdin, stdout, BufferMode(..))

-- | Result of a confirmation prompt. Makes exit-code semantics explicit
-- instead of hiding them behind Bool.
data ConfirmResult
  = Confirmed   -- ^ User typed "y" or "yes"
  | Declined    -- ^ User typed anything else
  deriving (Eq, Show)

-- | Ask the user to confirm an action on the terminal.
-- Formats with "? " prefix and bold bright red message text to match Rust.
requestConfirmation :: Text -> IO ConfirmResult
requestConfirmation prompt = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout NoBuffering
  isTty <- hIsTerminalDevice stdout
  putStrLn ""  -- blank line before prompt
  if isTty
    then putStr $ "? \ESC[1;91m" <> T.unpack prompt <> "\ESC[0m (y/N) "
    else putStr $ "? " <> T.unpack prompt <> " (y/N) "
  hFlush stdout
  answer <- getLine
  pure $ if isConfirmation answer then Confirmed else Declined

-- | Pure check: is the user's input a confirmation ("y" or "yes", case-insensitive)?
isConfirmation :: String -> Bool
isConfirmation answer = map toLower answer `elem` ["y", "yes"]
