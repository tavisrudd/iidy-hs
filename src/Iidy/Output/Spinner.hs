module Iidy.Output.Spinner (
    SpinnerStyle (..),
    Spinner (..),
    newSpinner,
    spinnerTick,
    spinnerClear,
    spinnerFrame,
    spinnerSetMessage,
    spinnerRender,
    spinnerFinishAndClear,
    spinnerIntervalMs,
) where

import Control.Monad (when)
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.IO (Handle, hFlush)

-- | Spinner animation style
data SpinnerStyle
    = -- | Braille dots animation
      SpinnerDots
    | -- | Extended braille dots
      SpinnerDots12
    | -- | Line animation
      SpinnerLine
    | -- | Directional arrows
      SpinnerArrow
    | -- | Two-state pulse
      SpinnerPulse
    deriving stock (Show, Eq, Ord)

-- | A terminal spinner
data Spinner = Spinner
    { spStyle :: !SpinnerStyle
    , spFrameRef :: !(IORef Int)
    , spMessage :: !(IORef Text)
    , spActive :: !(IORef Bool)
    , spHandle :: !Handle
    }

-- | Create a new spinner with an initial message, writing to the given handle
newSpinner :: Handle -> SpinnerStyle -> IO Spinner
newSpinner h style = do
    frameRef <- newIORef 0
    msgRef <- newIORef ""
    activeRef <- newIORef False
    pure
        Spinner
            { spStyle = style
            , spFrameRef = frameRef
            , spMessage = msgRef
            , spActive = activeRef
            , spHandle = h
            }

-- | Safe cyclic indexing into a NonEmpty list
cycleIndex :: NonEmpty a -> Int -> a
cycleIndex ne i = go (i `mod` NE.length ne) (NE.toList ne)
  where
    go 0 (x : _) = x
    go n (_ : xs) = go (n - 1) xs
    go _ [] = NE.head ne -- unreachable due to mod, but total

-- | Advance the spinner to the next frame, returning the current frame character
spinnerTick :: Spinner -> IO Text
spinnerTick sp = do
    frame <- readIORef (spFrameRef sp)
    let frames = spinnerFrames (spStyle sp)
        current = cycleIndex frames frame
    atomicWriteIORef (spFrameRef sp) ((frame + 1) `mod` NE.length frames)
    atomicWriteIORef (spActive sp) True
    pure current

-- | Clear the spinner state
spinnerClear :: Spinner -> IO ()
spinnerClear sp = do
    atomicWriteIORef (spActive sp) False
    atomicWriteIORef (spFrameRef sp) 0

-- | Get the current frame without advancing
spinnerFrame :: Spinner -> IO Text
spinnerFrame sp = do
    frame <- readIORef (spFrameRef sp)
    let frames = spinnerFrames (spStyle sp)
    pure $ cycleIndex frames frame

-- | Set the spinner message
spinnerSetMessage :: Spinner -> Text -> IO ()
spinnerSetMessage sp = atomicWriteIORef (spMessage sp)

-- | Render the spinner to the configured handle (overwriting current line with \r)
spinnerRender :: Spinner -> Text -> IO ()
spinnerRender sp colorCode = do
    frame <- spinnerTick sp
    msg <- readIORef (spMessage sp)
    let line = "\r" <> colorCode <> frame <> "\ESC[0m " <> msg
    TIO.hPutStr (spHandle sp) line
    hFlush (spHandle sp)

-- | Clear the spinner line and reset state
spinnerFinishAndClear :: Spinner -> IO ()
spinnerFinishAndClear sp = do
    active <- readIORef (spActive sp)
    when active $ do
        -- Clear the current line
        TIO.hPutStr (spHandle sp) "\r\ESC[K"
        hFlush (spHandle sp)
        spinnerClear sp

-- | Get tick interval in milliseconds for a spinner style
spinnerIntervalMs :: SpinnerStyle -> Int
spinnerIntervalMs = \case
    SpinnerDots -> 100
    SpinnerDots12 -> 100
    SpinnerLine -> 100
    SpinnerArrow -> 200
    SpinnerPulse -> 200

-- | Get the frame characters for a spinner style
spinnerFrames :: SpinnerStyle -> NonEmpty Text
spinnerFrames = \case
    SpinnerDots -> "⠋" :| map T.singleton "⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    SpinnerDots12 -> "⠋" :| map T.singleton "⠙⠹⠸⠼⠴⠦⠧⠇⠏⠋⠙" -- intentional repeat for smoother loop (matches npm spinners)
    SpinnerLine -> "⠂" :| map T.singleton "⠄⠅⠇⡇⣇⣧⣷⣿⣸⣰⣠⣀"
    SpinnerArrow -> "←" :| map T.singleton "↖↑↗→↘↓↙"
    SpinnerPulse -> "⚫" :| ["⚪"]
