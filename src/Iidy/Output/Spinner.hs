module Iidy.Output.Spinner
  ( SpinnerStyle(..)
  , Spinner(..)
  , newSpinner
  , spinnerTick
  , spinnerClear
  , spinnerFrame
  , spinnerSetMessage
  , spinnerRender
  , spinnerFinishAndClear
  , spinnerIntervalMs
  ) where

import Control.Monad (when)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.IORef
import System.IO (Handle, hFlush)

-- | Spinner animation style
data SpinnerStyle
  = SpinnerDots       -- ^ Braille dots animation
  | SpinnerDots12     -- ^ Extended braille dots
  | SpinnerLine       -- ^ Line animation
  | SpinnerArrow      -- ^ Directional arrows
  | SpinnerPulse      -- ^ Two-state pulse
  deriving stock (Show, Eq, Ord)

-- | A terminal spinner
data Spinner = Spinner
  { spStyle     :: !SpinnerStyle
  , spFrameRef  :: !(IORef Int)
  , spMessage   :: !(IORef Text)
  , spActive    :: !(IORef Bool)
  , spHandle    :: !Handle
  }

-- | Create a new spinner with an initial message, writing to the given handle
newSpinner :: Handle -> SpinnerStyle -> IO Spinner
newSpinner h style = do
  frameRef <- newIORef 0
  msgRef <- newIORef ""
  activeRef <- newIORef False
  pure Spinner
    { spStyle    = style
    , spFrameRef = frameRef
    , spMessage  = msgRef
    , spActive   = activeRef
    , spHandle   = h
    }

-- | Safe cyclic indexing into a NonEmpty list
cycleIndex :: NonEmpty a -> Int -> a
cycleIndex ne i = go (i `mod` NE.length ne) (NE.toList ne)
  where
    go 0 (x:_)  = x
    go n (_:xs) = go (n - 1) xs
    go _ []     = NE.head ne  -- unreachable due to mod, but total

-- | Advance the spinner to the next frame, returning the current frame character
spinnerTick :: Spinner -> IO Text
spinnerTick sp = do
  frame <- readIORef (spFrameRef sp)
  let frames = spinnerFrames (spStyle sp)
      current = cycleIndex frames frame
  atomicWriteIORef (spFrameRef sp) (frame + 1)
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
spinnerSetMessage sp msg = writeIORef (spMessage sp) msg

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
  SpinnerDots   -> 100
  SpinnerDots12 -> 100
  SpinnerLine   -> 100
  SpinnerArrow  -> 200
  SpinnerPulse  -> 200

-- | Get the frame characters for a spinner style
spinnerFrames :: SpinnerStyle -> NonEmpty Text
spinnerFrames = \case
  SpinnerDots   -> "⠋" :| map T.singleton "⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  SpinnerDots12 -> "⠋" :| map T.singleton "⠙⠹⠸⠼⠴⠦⠧⠇⠏⠋⠙"
  SpinnerLine   -> "⠂" :| map T.singleton "⠄⠅⠇⡇⣇⣧⣷⣿⣸⣰⣠⣀"
  SpinnerArrow  -> "←" :| map T.singleton "↖↑↗→↘↓↙"
  SpinnerPulse  -> "⚫" :| ["⚪"]
