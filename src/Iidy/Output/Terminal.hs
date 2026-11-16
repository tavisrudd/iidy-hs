module Iidy.Output.Terminal (
    TerminalCapabilities (..),
    detectCapabilities,
    detectCapabilitiesWith,
    resolveWidth,
) where

import System.Console.Terminal.Size qualified as TermSize
import System.Environment (lookupEnv)
import System.IO (hIsTerminalDevice, stdout)

-- | Terminal capabilities detection result
data TerminalCapabilities = TerminalCapabilities
    { tcHasColor :: !Bool
    , tcWidth :: !(Maybe Int)
    , tcIsTty :: !Bool
    }
    deriving stock (Show, Eq)

-- | Detect terminal capabilities from environment and the real terminal size
detectCapabilities :: IO TerminalCapabilities
detectCapabilities = detectCapabilitiesWith (fmap (fmap TermSize.width) TermSize.size)

{- | 'detectCapabilities' with the terminal size query injected, so tests need
no real TTY.
-}
detectCapabilitiesWith :: IO (Maybe Int) -> IO TerminalCapabilities
detectCapabilitiesWith querySize = do
    isTty <- hIsTerminalDevice stdout
    noColor <- lookupEnv "NO_COLOR"
    forceColor <- lookupEnv "FORCE_COLOR"
    columns <- lookupEnv "COLUMNS"
    realSize <- if isTty then querySize else pure Nothing

    let hasColor = case (noColor, forceColor) of
            (Just _, _) -> False
            (_, Just _) -> True
            _noOverride -> isTty

        width = resolveWidth columns isTty realSize

    pure
        TerminalCapabilities
            { tcHasColor = hasColor
            , tcWidth = width
            , tcIsTty = isTty
            }

{- | Width precedence: a valid (positive integer) @COLUMNS@ override, then the
real terminal size when output is a terminal, else 'Nothing' (the renderer
then falls back to its default width). Rust has no @COLUMNS@ override; see
DIVERGENCES.md.
-}
resolveWidth :: Maybe String -> Bool -> Maybe Int -> Maybe Int
resolveWidth columns isTty realSize =
    case columns >>= parseColumns of
        Just n -> Just n
        Nothing -> if isTty then realSize >>= positive else Nothing
  where
    positive :: Int -> Maybe Int
    positive n = if n > 0 then Just n else Nothing

    parseColumns :: String -> Maybe Int
    parseColumns s = case reads s :: [(Integer, String)] of
        [(n, "")] | n > 0 && n <= maxColumns -> Just (fromInteger n)
        _invalid -> Nothing

    -- Parsed as Integer so huge values cannot wrap around; no real terminal
    -- is wider than this.
    maxColumns :: Integer
    maxColumns = 10000
