{- | CFN operation environment and monad.

CfnEnv bundles the read-only context that's uniform across all
CloudFormation operations dispatched from runCfnWithArgs: AWS context,
environment name, remote-import policy, and the output emitter.

CfnM is ReaderT CfnEnv IO — operations use 'asks' to access context
instead of threading 4 extra parameters through every call.
-}
module Iidy.Cfn.Env (
    CfnEnv (..),
    CfnM,
    runCfnM,
    askContext,
    askEnvName,
    askRemoteImports,
    askEmit,
    emitOutput,
    mkImportConfig,
) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader (ReaderT, asks, runReaderT)
import Data.Text (Text)

import Iidy.Cfn.Context (CfnContext (..))
import Iidy.Output.Types (OutputData)
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig (..))
import Iidy.Yaml.Imports.Types (RemoteImports)

-- | Read-only environment for CFN operations.
data CfnEnv = CfnEnv
    { ceContext :: !CfnContext
    , ceEnvironment :: !Text
    , ceRemoteImports :: !RemoteImports
    , ceEmit :: !(OutputData -> IO ())
    }

-- | Monad for CFN operations. Concrete ReaderT over IO.
type CfnM = ReaderT CfnEnv IO

-- | Run a CfnM action with the given environment.
runCfnM :: CfnEnv -> CfnM a -> IO a
runCfnM = flip runReaderT

-- | Get the CfnContext from the environment.
askContext :: CfnM CfnContext
askContext = asks ceContext

-- | Get the environment name (e.g. \"production\", \"staging\").
askEnvName :: CfnM Text
askEnvName = asks ceEnvironment

-- | Get the remote-import policy.
askRemoteImports :: CfnM RemoteImports
askRemoteImports = asks ceRemoteImports

-- | Get the raw emitter function (for passing to IO helpers).
askEmit :: CfnM (OutputData -> IO ())
askEmit = asks ceEmit

-- | Emit output data through the configured emitter.
emitOutput :: OutputData -> CfnM ()
emitOutput od = do
    f <- asks ceEmit
    liftIO (f od)

-- | Build an ImportConfig from the environment.
mkImportConfig :: CfnM ImportConfig
mkImportConfig = do
    ctx <- askContext
    ri <- askRemoteImports
    pure ImportConfig{icAwsEnv = Just (cfnEnv ctx), icRemoteImports = ri}
