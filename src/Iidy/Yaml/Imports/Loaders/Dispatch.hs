-- | Full import dispatcher.
-- Routes all import types to the appropriate loader, with optional AWS env.
-- Uses 'parseImportType' as a security gate to enforce the trust model
-- (e.g. remote base templates cannot load local import types).
module Iidy.Yaml.Imports.Loaders.Dispatch
  ( mkFullDispatcher
  , ImportConfig(..)
  ) where

import qualified Amazonka

import Iidy.Yaml.Engine (LoadImportFn)
import Iidy.Yaml.Imports.Types
  ( ImportType(..), ImportData, ImportError(..), RemoteImports(..), parseImportType )
import Iidy.Yaml.Imports.Loaders.File (loadFileImport, loadFilehashImport)
import Iidy.Yaml.Imports.Loaders.Env (loadEnvImport)
import Iidy.Yaml.Imports.Loaders.Git (loadGitImport)
import Iidy.Yaml.Imports.Loaders.Http (loadHttpImport)
import Iidy.Yaml.Imports.Loaders.Random (loadRandomImport)
import Iidy.Yaml.Imports.Loaders.S3 (loadS3Import)
import Iidy.Yaml.Imports.Loaders.Ssm (loadSsmImport, loadSsmPathImport)
import Iidy.Yaml.Imports.Loaders.Cfn (loadCfnImport)

------------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------------

-- | Configuration for the import dispatcher.
data ImportConfig = ImportConfig
  { icAwsEnv        :: !(Maybe Amazonka.Env)
  , icRemoteImports :: !RemoteImports
  }

------------------------------------------------------------------------
-- Full dispatcher
------------------------------------------------------------------------

-- | Create a full import dispatcher.
-- First classifies the import via 'parseImportType' (enforcing the security
-- model: remote base templates cannot load local-only import types), then
-- dispatches to the appropriate loader.
-- When AWS env is 'Nothing', AWS import types return an error.
-- When 'icRemoteImports' is 'BlockRemoteImports', HTTP and S3 imports
-- are rejected.
mkFullDispatcher :: ImportConfig -> LoadImportFn
mkFullDispatcher cfg location baseLocation =
  case parseImportType location baseLocation of
    Left err -> pure (Left err)
    Right importType -> dispatch cfg importType location baseLocation

-- | Dispatch a classified import type to its loader.
dispatch
  :: ImportConfig
  -> ImportType
  -> LoadImportFn
dispatch cfg importType location baseLocation = case importType of
  ImportFile          -> loadFileImport location baseLocation
  ImportEnv           -> loadEnvImport location
  ImportGit           -> loadGitImport location baseLocation
  ImportRandom        -> loadRandomImport location
  ImportFilehash      -> loadFilehashImport location baseLocation False
  ImportFilehashBase64 -> loadFilehashImport location baseLocation True
  ImportHttp          -> withRemote cfg $ loadHttpImport location
  -- cfn/ssm/ssm-path are AWS API calls gated by credentials, not arbitrary
  -- fetches.  They are NOT blocked by --no-remote-imports because they go
  -- through the AWS SDK with IAM auth, not open HTTP.
  ImportCfn           -> withAwsEnv cfg $ \env -> loadCfnImport env location
  ImportSsm           -> withAwsEnv cfg $ \env -> loadSsmImport env location
  ImportSsmPath       -> withAwsEnv cfg $ \env -> loadSsmPathImport env location
  ImportS3            -> withRemote cfg $ withAwsEnv cfg $ \env -> loadS3Import env location

-- | Run an AWS loader if env is available, otherwise return an error.
withAwsEnv
  :: ImportConfig
  -> (Amazonka.Env -> IO (Either ImportError ImportData))
  -> IO (Either ImportError ImportData)
withAwsEnv cfg f = case icAwsEnv cfg of
  Nothing  -> pure $ Left $ ImportError
    "AWS import type requires credentials and is not available in this context"
  Just env -> f env

-- | Run a remote loader if remote imports are allowed, otherwise return an error.
withRemote
  :: ImportConfig
  -> IO (Either ImportError ImportData)
  -> IO (Either ImportError ImportData)
withRemote cfg action = case icRemoteImports cfg of
  AllowRemoteImports -> action
  BlockRemoteImports -> pure $ Left $ ImportError
    "Remote imports are disabled (--no-remote-imports)"
