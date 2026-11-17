{- | Full import dispatcher.
Routes all import types to the appropriate loader, with optional AWS env.
Uses 'checkImport' as a security gate to enforce the trust model
(remote base templates cannot load local-only import types, and untrusted
ones cannot load AWS-backed import types).
-}
module Iidy.Yaml.Imports.Loaders.Dispatch (
    mkFullDispatcher,
    ImportConfig (..),
    mkImportConfig,
    preprocessWithConfig,
    preprocessWithPolicy,
) where

import Amazonka qualified
import Data.Text (Text)

import Iidy.Yaml.Ast (YamlAst)
import Iidy.Yaml.Engine (LoadImportFn, PreprocessError, PreprocessResult, preprocessYamlWith)
import Iidy.Yaml.Imports.Loaders.Cfn (loadCfnImport)
import Iidy.Yaml.Imports.Loaders.Env (loadEnvImport)
import Iidy.Yaml.Imports.Loaders.File (loadFileImport, loadFilehashImport)
import Iidy.Yaml.Imports.Loaders.Git (loadGitImport)
import Iidy.Yaml.Imports.Loaders.Http (loadHttpImport)
import Iidy.Yaml.Imports.Loaders.HttpGuard (HttpSeam, httpGuardFor, realHttpSeam)
import Iidy.Yaml.Imports.Loaders.Random (loadRandomImport)
import Iidy.Yaml.Imports.Loaders.S3 (loadS3Import)
import Iidy.Yaml.Imports.Loaders.Ssm (loadSsmImport, loadSsmPathImport)
import Iidy.Yaml.Imports.Types (
    ImportBase (..),
    ImportData,
    ImportError (..),
    ImportPolicy (..),
    ImportType (..),
    RemoteImports (..),
    checkImport,
 )

------------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------------

-- | Configuration for the import dispatcher. Build it with 'mkImportConfig'.
data ImportConfig = ImportConfig
    { icAwsEnv :: !(Maybe Amazonka.Env)
    , icPolicy :: !ImportPolicy
    , icHttpSeam :: !HttpSeam
    -- ^ name resolution and plain connections for HTTP imports
    }

-- | The one 'ImportConfig' constructor; fields added later get defaults here.
mkImportConfig :: Maybe Amazonka.Env -> ImportPolicy -> ImportConfig
mkImportConfig mEnv policy = ImportConfig{icAwsEnv = mEnv, icPolicy = policy, icHttpSeam = realHttpSeam}

------------------------------------------------------------------------
-- Preprocessing with one policy
------------------------------------------------------------------------

{- | Preprocess a template (@True@: YAML 1.1 compatibility) with the
dispatcher built from this config, giving the engine the same trusted
sources, so the dispatcher's gate and the engine's custom-template
decision use one policy.
-}
preprocessWithConfig :: ImportConfig -> Bool -> YamlAst -> Text -> IO (Either PreprocessError PreprocessResult)
preprocessWithConfig cfg = preprocessWithPolicy (icPolicy cfg) (mkFullDispatcher cfg)

{- | 'preprocessWithConfig' for a loader that wraps 'mkFullDispatcher'
built from this policy (the stack-args bootstrap, which picks the AWS
environment per import).
-}
preprocessWithPolicy ::
    ImportPolicy -> LoadImportFn -> Bool -> YamlAst -> Text -> IO (Either PreprocessError PreprocessResult)
preprocessWithPolicy policy loader yaml11Compat = preprocessYamlWith (ipTrustedSources policy) yaml11Compat loader

------------------------------------------------------------------------
-- Full dispatcher
------------------------------------------------------------------------

{- | Create a full import dispatcher.
First classifies the import via 'checkImport' (enforcing the security
model: remote base templates cannot load local-only import types, and
documents outside the trusted sources cannot load AWS-backed ones), then
dispatches to the appropriate loader. The gate runs before any loader, so
a refused AWS-backed import never reaches 'withAwsEnv'.
When AWS env is 'Nothing', AWS import types return an error.
When the policy's 'ipRemoteImports' is 'BlockRemoteImports', HTTP and S3 imports
are rejected.
-}
mkFullDispatcher :: ImportConfig -> LoadImportFn
mkFullDispatcher cfg location base =
    case checkImport (ipTrustedSources (icPolicy cfg)) location base of
        Left err -> pure (Left err)
        Right importType -> dispatch cfg importType location base

-- | Dispatch a classified import type to its loader.
dispatch ::
    ImportConfig ->
    ImportType ->
    LoadImportFn
dispatch cfg importType location base = case importType of
    ImportFile -> loadFileImport location (ibLocation base)
    ImportEnv -> loadEnvImport location
    ImportGit -> loadGitImport location (ibLocation base)
    ImportRandom -> loadRandomImport location
    ImportFilehash -> loadFilehashImport location (ibLocation base) False
    ImportFilehashBase64 -> loadFilehashImport location (ibLocation base) True
    ImportHttp ->
        withRemote cfg $
            loadHttpImport (icHttpSeam cfg) (httpGuardFor (ipTrustedSources (icPolicy cfg)) location base) location
    -- cfn/ssm/ssm-path are AWS API calls made with the user's credentials.
    -- They are NOT blocked by --no-remote-imports (they are not open HTTP),
    -- but 'checkImport' refuses them, and s3:, from untrusted documents.
    ImportCfn -> withAwsEnv cfg $ \env -> loadCfnImport env location
    ImportSsm -> withAwsEnv cfg $ \env -> loadSsmImport env location
    ImportSsmPath -> withAwsEnv cfg $ \env -> loadSsmPathImport env location
    ImportS3 -> withRemote cfg $ withAwsEnv cfg $ \env -> loadS3Import env location

-- | Run an AWS loader if env is available, otherwise return an error.
withAwsEnv ::
    ImportConfig ->
    (Amazonka.Env -> IO (Either ImportError ImportData)) ->
    IO (Either ImportError ImportData)
withAwsEnv cfg f = case icAwsEnv cfg of
    Nothing ->
        pure $
            Left $
                ImportError
                    "AWS import type requires credentials and is not available in this context"
    Just env -> f env

-- | Run a remote loader if remote imports are allowed, otherwise return an error.
withRemote ::
    ImportConfig ->
    IO (Either ImportError ImportData) ->
    IO (Either ImportError ImportData)
withRemote cfg action = case ipRemoteImports (icPolicy cfg) of
    AllowRemoteImports -> action
    BlockRemoteImports ->
        pure $
            Left $
                ImportError
                    "Remote imports are disabled (--no-remote-imports)"
