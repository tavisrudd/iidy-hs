-- | Full import dispatcher.
-- Routes all import types to the appropriate loader, with optional AWS env.
-- Uses 'parseImportType' as a security gate to enforce the trust model
-- (e.g. remote base templates cannot load local import types).
module Iidy.Yaml.Imports.Loaders.Dispatch
  ( mkFullDispatcher
  ) where

import qualified Amazonka

import Iidy.Yaml.Engine (LoadImportFn)
import Iidy.Yaml.Imports.Types
  ( ImportType(..), ImportData, ImportError(..), parseImportType )
import Iidy.Yaml.Imports.Loaders.File (loadFileImport, loadFilehashImport)
import Iidy.Yaml.Imports.Loaders.Env (loadEnvImport)
import Iidy.Yaml.Imports.Loaders.Git (loadGitImport)
import Iidy.Yaml.Imports.Loaders.Http (loadHttpImport)
import Iidy.Yaml.Imports.Loaders.Random (loadRandomImport)
import Iidy.Yaml.Imports.Loaders.S3 (loadS3Import)
import Iidy.Yaml.Imports.Loaders.Ssm (loadSsmImport, loadSsmPathImport)
import Iidy.Yaml.Imports.Loaders.Cfn (loadCfnImport)

------------------------------------------------------------------------
-- Full dispatcher
------------------------------------------------------------------------

-- | Create a full import dispatcher.
-- First classifies the import via 'parseImportType' (enforcing the security
-- model: remote base templates cannot load local-only import types), then
-- dispatches to the appropriate loader.
-- When AWS env is 'Nothing', AWS import types return an error.
mkFullDispatcher :: Maybe Amazonka.Env -> LoadImportFn
mkFullDispatcher mAwsEnv location baseLocation =
  case parseImportType location baseLocation of
    Left err -> pure (Left err)
    Right importType -> dispatch mAwsEnv importType location baseLocation

-- | Dispatch a classified import type to its loader.
dispatch
  :: Maybe Amazonka.Env
  -> ImportType
  -> LoadImportFn
dispatch mAwsEnv importType location baseLocation = case importType of
  ImportFile          -> loadFileImport location baseLocation
  ImportEnv           -> loadEnvImport location
  ImportGit           -> loadGitImport location baseLocation
  ImportRandom        -> loadRandomImport location
  ImportFilehash      -> loadFilehashImport location baseLocation False
  ImportFilehashBase64 -> loadFilehashImport location baseLocation True
  ImportHttp          -> loadHttpImport location
  ImportCfn           -> withAwsEnv mAwsEnv $ \env -> loadCfnImport env location
  ImportSsm           -> withAwsEnv mAwsEnv $ \env -> loadSsmImport env location
  ImportSsmPath       -> withAwsEnv mAwsEnv $ \env -> loadSsmPathImport env location
  ImportS3            -> withAwsEnv mAwsEnv $ \env -> loadS3Import env location

-- | Run an AWS loader if env is available, otherwise return an error.
withAwsEnv
  :: Maybe Amazonka.Env
  -> (Amazonka.Env -> IO (Either ImportError ImportData))
  -> IO (Either ImportError ImportData)
withAwsEnv Nothing _ = pure $ Left $ ImportError
  "AWS import type requires credentials and is not available in this context"
withAwsEnv (Just env) f = f env
