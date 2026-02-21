module Iidy.Output.Spinner
  ( SpinnerStyle(..)
  , Spinner(..)
  , newSpinner
  , spinnerTick
  , spinnerClear
  , spinnerFrame
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.IORef

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
  }

-- | Create a new spinner
newSpinner :: SpinnerStyle -> IO Spinner
newSpinner style = do
  frameRef <- newIORef 0
  msgRef <- newIORef ""
  activeRef <- newIORef False
  pure Spinner
    { spStyle    = style
    , spFrameRef = frameRef
    , spMessage  = msgRef
    , spActive   = activeRef
    }

-- | Advance the spinner to the next frame, returning the current frame character
spinnerTick :: Spinner -> IO Text
spinnerTick sp = do
  frame <- readIORef (spFrameRef sp)
  let frames = spinnerFrames (spStyle sp)
      current = frames !! (frame `mod` length frames)
  writeIORef (spFrameRef sp) (frame + 1)
  writeIORef (spActive sp) True
  pure current

-- | Clear the spinner
spinnerClear :: Spinner -> IO ()
spinnerClear sp = do
  writeIORef (spActive sp) False
  writeIORef (spFrameRef sp) 0

-- | Get the current frame without advancing
spinnerFrame :: Spinner -> IO Text
spinnerFrame sp = do
  frame <- readIORef (spFrameRef sp)
  let frames = spinnerFrames (spStyle sp)
  pure $ frames !! (frame `mod` length frames)

-- | Get the frame characters for a spinner style
spinnerFrames :: SpinnerStyle -> [Text]
spinnerFrames = \case
  SpinnerDots   -> map T.singleton "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  SpinnerDots12 -> map T.singleton "⠁⠂⠄⡀⢀⠠⠐⠈"
  SpinnerLine   -> map T.singleton "⠂⠒⠐⠰⠤⠆"
  SpinnerArrow  -> map T.singleton "←↖↑↗→↘↓↙"
  SpinnerPulse  -> ["⚫", "⚪"]
