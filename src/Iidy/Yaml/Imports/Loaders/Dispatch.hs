-- | Full import dispatcher.
-- Routes all import types to the appropriate loader, with optional AWS env.
module Iidy.Yaml.Imports.Loaders.Dispatch
  ( mkFullDispatcher
  ) where

import qualified Data.Text as T

import qualified Amazonka

import Iidy.Yaml.Engine (LoadImportFn)
import Iidy.Yaml.Imports.Types (ImportData, ImportError(..))
import Iidy.Yaml.Imports.Loaders.File (loadFileImport, loadFilehashImport)
import Iidy.Yaml.Imports.Loaders.Env (loadEnvImport)
import Iidy.Yaml.Imports.Loaders.Git (loadGitImport)
import Iidy.Yaml.Imports.Loaders.Http (loadHttpImport)
import Iidy.Yaml.Imports.Loaders.Random (loadRandomImport)
import Iidy.Yaml.Imports.Loaders.S3 (loadS3Import)
import Iidy.Yaml.Imports.Loaders.Ssm (loadSsmImport)
import Iidy.Yaml.Imports.Loaders.SsmPath (loadSsmPathImport)
import Iidy.Yaml.Imports.Loaders.Cfn (loadCfnImport)

------------------------------------------------------------------------
-- Full dispatcher
------------------------------------------------------------------------

-- | Create a full import dispatcher.
-- When AWS env is 'Nothing', AWS import types return an error.
-- When AWS env is 'Just env', AWS imports are dispatched to their loaders.
mkFullDispatcher :: Maybe Amazonka.Env -> LoadImportFn
mkFullDispatcher mAwsEnv location baseLocation
  -- Local import types
  | "filehash-base64:" `T.isPrefixOf` location =
      loadFilehashImport location baseLocation True
  | "filehash:" `T.isPrefixOf` location =
      loadFilehashImport location baseLocation False
  | "env:" `T.isPrefixOf` location =
      loadEnvImport location
  | "git:" `T.isPrefixOf` location =
      loadGitImport location baseLocation
  | "random:" `T.isPrefixOf` location =
      loadRandomImport location
  | "http://" `T.isPrefixOf` location || "https://" `T.isPrefixOf` location =
      loadHttpImport location
  -- AWS import types
  | "cfn:" `T.isPrefixOf` location =
      withAwsEnv mAwsEnv $ \env -> loadCfnImport env location
  | "ssm-path:" `T.isPrefixOf` location =
      withAwsEnv mAwsEnv $ \env -> loadSsmPathImport env location
  | "ssm:" `T.isPrefixOf` location =
      withAwsEnv mAwsEnv $ \env -> loadSsmImport env location
  | "s3:" `T.isPrefixOf` location =
      withAwsEnv mAwsEnv $ \env -> loadS3Import env location
  -- Default: file import
  | otherwise =
      loadFileImport location baseLocation

-- | Run an AWS loader if env is available, otherwise return an error.
withAwsEnv
  :: Maybe Amazonka.Env
  -> (Amazonka.Env -> IO (Either ImportError ImportData))
  -> IO (Either ImportError ImportData)
withAwsEnv Nothing _ = pure $ Left $ ImportError
  "AWS import type requires credentials and is not available in this context"
withAwsEnv (Just env) f = f env
