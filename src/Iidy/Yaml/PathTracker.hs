module Iidy.Yaml.PathTracker
  ( PathTracker
  , emptyTracker
  , pushSegment
  , popSegment
  , currentPath
  , trackerLen
  , trackerIsEmpty
  , trackerSegments
  , clearTracker
  ) where

import Data.Foldable (toList)
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T

-- | Tracks the current path through a YAML document during processing
newtype PathTracker = PathTracker (Seq Text)
  deriving stock (Show, Eq)

emptyTracker :: PathTracker
emptyTracker = PathTracker Seq.empty

pushSegment :: Text -> PathTracker -> PathTracker
pushSegment seg (PathTracker segs) = PathTracker (segs |> seg)

popSegment :: PathTracker -> (Maybe Text, PathTracker)
popSegment (PathTracker segs) = case Seq.viewr segs of
  Seq.EmptyR     -> (Nothing, PathTracker Seq.empty)
  rest Seq.:> x  -> (Just x, PathTracker rest)

currentPath :: PathTracker -> Text
currentPath (PathTracker segs) = T.intercalate "." (toList segs)

trackerLen :: PathTracker -> Int
trackerLen (PathTracker segs) = Seq.length segs

trackerIsEmpty :: PathTracker -> Bool
trackerIsEmpty (PathTracker segs) = Seq.null segs

trackerSegments :: PathTracker -> [Text]
trackerSegments (PathTracker segs) = toList segs

clearTracker :: PathTracker
clearTracker = PathTracker Seq.empty
