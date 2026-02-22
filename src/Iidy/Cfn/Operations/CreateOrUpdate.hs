-- | Create-or-update CloudFormation operation.
--
-- Checks whether a stack exists and dispatches to either createStack
-- or updateStack accordingly. The --changeset path is not yet implemented
-- (the Bool arg is reserved for future use).
module Iidy.Cfn.Operations.CreateOrUpdate
  ( createOrUpdate
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Cfn.StackOperations (stackExists)
import Iidy.Cfn.Types (StackArgs(..))
import Iidy.Cfn.Operations.CreateStack (createStack)
import Iidy.Cfn.Operations.UpdateStack (updateStack)

------------------------------------------------------------------------
-- Create-or-update operation
------------------------------------------------------------------------

-- | Create or update a CloudFormation stack, depending on whether it exists.
--
-- Steps:
--   1. Determine the stack name from StackArgs.
--   2. Check if the stack currently exists (excluding DELETE_COMPLETE).
--   3. If the stack exists, call updateStack.
--   4. If the stack does not exist, call createStack.
--
-- The @useChangeset@ parameter is reserved for future --changeset support;
-- the current implementation always uses the direct create/update path.
createOrUpdate
  :: CfnContext
  -> StackArgs
  -> Bool            -- ^ useChangeset flag (reserved; currently ignored)
  -> Maybe FilePath  -- ^ argsfile path for template resolution
  -> Text            -- ^ environment name
  -> IO (Either Text Int)
createOrUpdate ctx args _useChangeset argsfilePath env = do
  let stackName = fromMaybe "unnamed-stack" (saStackName args)

  -- Step 2: Check stack existence
  exists <- stackExists ctx stackName

  -- Step 3/4: Dispatch based on existence
  if exists
    then updateStack ctx args argsfilePath env
    else createStack ctx args argsfilePath env
