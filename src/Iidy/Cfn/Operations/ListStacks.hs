-- | List CloudFormation stacks with optional tag filtering.
--
-- Fetches all stacks via DescribeStacks (paginated to handle accounts
-- with >100 stacks), applies optional key=value tag filters, sorts by
-- creation time, and returns a StackListDisplay for rendering.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.ListStacks
  ( listStacks
  ) where

import Control.Monad.Trans.Resource (runResourceT)
import Data.Conduit (runConduit, (.|))
import qualified Data.Conduit.List as CL
import Data.List (sortBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T

import qualified Amazonka
import qualified Amazonka.CloudFormation.Types as CF
import qualified Amazonka.CloudFormation.DescribeStacks as DStacks

import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Cfn.Status (fromCfnStackStatus)
import Iidy.Output.Types
  ( OutputData(..)
  , StackListDisplay(..)
  , StackListEntry(..)
  , StackListColumn(..)
  )

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- | List CloudFormation stacks, optionally filtered by tags.
--
-- Tag filters are supplied as @["key=value", ...]@. A stack must match
-- ALL supplied filters to be included in the result.
--
-- Stacks are sorted by creation time (oldest first).
listStacks
  :: CfnContext
  -> Maybe [Text]           -- ^ Optional tag filters ("key=value")
  -> Bool                   -- ^ Show tags column
  -> Bool                   -- ^ Query mode (JMESPath query present)
  -> IO (Either Text [OutputData])
listStacks ctx mTagFilters showTags queryMode = do
  let req = DStacks.newDescribeStacks
  pages <- runResourceT $ runConduit $
    Amazonka.paginate (cfnEnv ctx) req .| CL.consume
  let stacks = concatMap (fromMaybe [] . (.stacks)) pages
      filters = fromMaybe [] mTagFilters
      parsed  = map parseTagFilter filters
      matched = filter (stackMatchesFilters parsed) stacks
      sorted  = sortBy (comparing (.creationTime)) matched
      entries = map convertStack sorted
      filterLabels = map (\f -> "tag:" <> f) filters
      display = StackListDisplay
        { sldStacks         = entries
        , sldShowTags       = showTags || not (null filters)
        , sldFiltersApplied = filterLabels
        , sldColumns        = defaultColumns filters showTags
        , sldQueryMode      = queryMode
        }
  pure (Right [OdStackList display])

------------------------------------------------------------------------
-- Tag filtering
------------------------------------------------------------------------

-- | Parse a "key=value" filter string into a (key, value) pair.
-- If there is no '=' the whole string is treated as the key and the
-- value is left empty — this is intentionally lenient.
parseTagFilter :: Text -> (Text, Text)
parseTagFilter kv =
  case T.breakOn "=" kv of
    (k, rest)
      | T.null rest -> (k, "")
      | otherwise   -> (k, T.drop 1 rest)

-- | Return True if the stack has a tag matching every filter.
stackMatchesFilters :: [(Text, Text)] -> CF.Stack -> Bool
stackMatchesFilters filters stack =
  let tagMap = stackTagMap stack
  in  all (\(k, v) -> Map.lookup k tagMap == Just v) filters

-- | Build a Map from the stack's tag list.
stackTagMap :: CF.Stack -> Map Text Text
stackTagMap stack =
  case stack.tags of
    Nothing   -> Map.empty
    Just tags -> Map.fromList [ (t.key, t.value) | t <- tags ]

------------------------------------------------------------------------
-- Conversion
------------------------------------------------------------------------

-- | Convert a CloudFormation Stack into a StackListEntry.
convertStack :: CF.Stack -> StackListEntry
convertStack s = StackListEntry
  { sleStackName             = s.stackName
  , sleStackStatus           = fromCfnStackStatus s.stackStatus
  , sleCreationTime          = Just (s.creationTime.fromTime)
  , sleLastUpdatedTime       = fmap (.fromTime) s.lastUpdatedTime
  , sleTags                  = stackTagMap s
  , sleStatusReason          = s.stackStatusReason
  , sleTerminationProtection = fromMaybe False s.enableTerminationProtection
  , sleEnvironmentType       = Map.lookup "iidy:environment" (stackTagMap s)
  }

------------------------------------------------------------------------
-- Column selection
------------------------------------------------------------------------

-- | Choose which columns to display.
-- When tag filters are active or --tags is requested, include the tags column.
defaultColumns :: [Text] -> Bool -> [StackListColumn]
defaultColumns filters showTags
  | showTags || not (null filters) =
    [ColName, ColStatus, ColTime, ColTags, ColStatusReason, ColTerminationProtection]
  | otherwise =
    [ColName, ColStatus, ColTime, ColStatusReason, ColTerminationProtection]
