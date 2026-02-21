module Iidy.Output.Terminal
  ( TerminalCapabilities(..)
  , detectCapabilities
  ) where

import System.Environment (lookupEnv)
import System.IO (stdout, hIsTerminalDevice)

-- | Terminal capabilities detection result
data TerminalCapabilities = TerminalCapabilities
  { tcHasColor     :: !Bool
  , tcHasTrueColor :: !Bool
  , tcWidth        :: !(Maybe Int)
  , tcIsTty        :: !Bool
  } deriving stock (Show, Eq)

-- | Detect terminal capabilities from environment
detectCapabilities :: IO TerminalCapabilities
detectCapabilities = do
  isTty <- hIsTerminalDevice stdout
  noColor <- lookupEnv "NO_COLOR"
  forceColor <- lookupEnv "FORCE_COLOR"
  colorTerm <- lookupEnv "COLORTERM"
  columns <- lookupEnv "COLUMNS"

  let hasColor = case (noColor, forceColor) of
        (Just _, _) -> False
        (_, Just _) -> True
        _           -> isTty

      hasTrueColor = case colorTerm of
        Just ct -> ct `elem` ["truecolor", "24bit"]
        Nothing -> False

      width = case columns of
        Just s -> case reads s of
          [(n, "")] | n > 0 -> Just n
          _                 -> if isTty then Just 80 else Nothing
        Nothing -> if isTty then Just 80 else Nothing

  pure TerminalCapabilities
    { tcHasColor     = hasColor
    , tcHasTrueColor = hasTrueColor
    , tcWidth        = width
    , tcIsTty        = isTty
    }
