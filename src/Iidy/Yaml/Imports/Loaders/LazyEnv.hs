{- | The import dispatcher with a lazily built AWS environment.

Commands that discover their imports while resolving a document (@render@,
@get-import@) cannot tell up front whether they need AWS credentials, and
Rust's SDK resolves them only at the first AWS call. 'lazyAwsDispatcher'
runs the environment provider at most once, at the first import that passes
the gate and is AWS-backed ('importNeedsAwsEnv'), and reports a failed build
as an 'ImportError' on that import. An import the gate refuses never builds
the environment.
-}
module Iidy.Yaml.Imports.Loaders.LazyEnv (
    lazyAwsDispatcher,
    tryBuildEnv,
) where

import Control.Concurrent.MVar (modifyMVar, newMVar)
import Control.Exception (Handler (..), IOException, catches)
import Data.Text (Text)
import Data.Text qualified as T
import System.IO.Error (ioeGetErrorString)

import Amazonka qualified
import Amazonka.Auth.Exception qualified as AuthEx

import Iidy.Aws.Errors (formatAuthError, formatAwsError)
import Iidy.Yaml.Engine (LoadImportFn)
import Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher, mkImportConfig)
import Iidy.Yaml.Imports.Types (ImportError (..), ImportPolicy, importNeedsAwsEnv)

{- | A dispatcher over the given policy whose AWS environment comes from the
provider, built on first use and shared by every later import (a failed build
is remembered too, so the provider never runs twice).
-}
lazyAwsDispatcher :: IO Amazonka.Env -> ImportPolicy -> IO LoadImportFn
lazyAwsDispatcher mkEnv policy = do
    cache <- newMVar Nothing
    let envOnce = modifyMVar cache $ \known -> case known of
            Just result -> pure (known, result)
            Nothing -> do
                result <- tryBuildEnv mkEnv
                pure (Just result, result)
    pure $ \location base ->
        if importNeedsAwsEnv policy location base
            then do
                built <- envOnce
                case built of
                    Left err -> pure (Left (ImportError err))
                    Right env -> mkFullDispatcher (mkImportConfig (Just env) policy) location base
            else mkFullDispatcher (mkImportConfig Nothing policy) location base

{- | Run the env provider, turning credential, region and STS failures into
an error message. Other exceptions propagate.
-}
tryBuildEnv :: IO Amazonka.Env -> IO (Either Text Amazonka.Env)
tryBuildEnv mkEnv =
    (Right <$> mkEnv)
        `catches` [ Handler $ \(e :: AuthEx.AuthError) ->
                        pure (Left ("AWS credentials not available: " <> formatAuthError e))
                  , Handler $ \(e :: IOException) ->
                        pure (Left (T.strip (T.pack (ioeGetErrorString e))))
                  , Handler $ \(e :: Amazonka.Error) ->
                        pure (Left ("AWS configuration failed: " <> formatAwsError e))
                  ]
