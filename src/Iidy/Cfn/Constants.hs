module Iidy.Cfn.Constants
  ( defaultPollIntervalSecs
  , defaultPollTimeoutSecs
  , defaultPreviousEventsCount
  , maxChangesetCreationTimeoutSecs
  , changesetPollIntervalSecs
  , createSuccessStates
  , updateSuccessStates
  , deleteSuccessStates
  ) where

import Data.Text (Text)

defaultPollIntervalSecs :: Int
defaultPollIntervalSecs = 2

defaultPollTimeoutSecs :: Int
defaultPollTimeoutSecs = 3600

defaultPreviousEventsCount :: Int
defaultPreviousEventsCount = 10

maxChangesetCreationTimeoutSecs :: Int
maxChangesetCreationTimeoutSecs = 300

changesetPollIntervalSecs :: Int
changesetPollIntervalSecs = 2

createSuccessStates :: [Text]
createSuccessStates = ["CREATE_COMPLETE"]

updateSuccessStates :: [Text]
updateSuccessStates = ["UPDATE_COMPLETE"]

deleteSuccessStates :: [Text]
deleteSuccessStates = ["DELETE_COMPLETE"]
