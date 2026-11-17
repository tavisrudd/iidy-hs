{- | Get-import command: retrieve and display data from any import location.

AWS-backed import types (@cfn:@, @ssm:@, @ssm-path:@, @s3:@) get an AWS
environment built from the global AWS options (profile, region,
assume-role), matching Rust @cfn/get_import.rs@. The environment is only
built when the location needs it: Rust's SDK resolves credentials lazily,
so a @file:@ or @env:@ import works there without any AWS configuration,
and so it does here.
-}
module Iidy.GetImport (
    runGetImport,
    runGetImportWith,
    needsAwsEnv,
) where

import Control.Exception (Handler (..), IOException, catches)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.IO (stderr)
import System.IO.Error (ioeGetErrorString)

import Amazonka qualified
import Amazonka.Auth.Exception qualified as AuthEx

import Iidy.Aws.Config (createAwsEnvFromSettings)
import Iidy.Aws.CredentialSource (AwsSettings)
import Iidy.Cli (GetImportArgs (..), GlobalOpts (..), RenderFormat (..))
import Iidy.Errors.JMESPath (formatJMESPathQueryError)
import Iidy.JsonPretty (prettyJsonText)
import Iidy.Output.Types (OutputData (..))
import Iidy.Yaml.Emitter (SeqStyle (..), emitYamlWith)
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig (..), mkFullDispatcher)
import Iidy.Yaml.Imports.Types (
    ImportData (..),
    ImportError (..),
    ImportType (..),
    RemoteImports (..),
    parseImportType,
 )
import Iidy.Yaml.JMESPath (applyJmesPath)
import Iidy.Yaml.OValue (OValue, fromValue)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

{- | Run the get-import command.
Builds the AWS environment from the CLI AWS settings when the import
location needs one, then loads and prints the import.
-}
runGetImport :: (OutputData -> IO ()) -> GetImportArgs -> GlobalOpts -> AwsSettings -> IO Int
runGetImport emit args gopts awsSettings =
    runGetImportWith (fst <$> createAwsEnvFromSettings awsSettings) emit args gopts

{- | Run the get-import command with an explicit AWS environment provider.
The provider runs at most once, and only when 'needsAwsEnv' holds for the
location. Tests pass a mock environment here.
-}
runGetImportWith :: IO Amazonka.Env -> (OutputData -> IO ()) -> GetImportArgs -> GlobalOpts -> IO Int
runGetImportWith mkEnv emit args gopts = do
    let location = giaImport args
        baseLocation = "."
        remoteImports = if goRemoteImports gopts then AllowRemoteImports else BlockRemoteImports
        wantsEnv = either (const False) (needsAwsEnv remoteImports) (parseImportType location baseLocation)

    envResult <-
        if wantsEnv
            then fmap Just <$> tryBuildEnv mkEnv
            else pure (Right Nothing)

    case envResult of
        Left err -> reportImportError err
        Right mEnv -> do
            let importCfg = ImportConfig{icAwsEnv = mEnv, icRemoteImports = remoteImports}
            result <- mkFullDispatcher importCfg location baseLocation
            case result of
                Left (ImportError err) -> reportImportError err
                Right importData -> emitDoc emit gopts args importData

{- | Whether loading an import of this type needs an AWS environment.
S3 imports are excluded when remote imports are blocked, so the user sees
the --no-remote-imports error rather than a credentials error.
-}
needsAwsEnv :: RemoteImports -> ImportType -> Bool
needsAwsEnv remoteImports = \case
    ImportCfn -> True
    ImportSsm -> True
    ImportSsmPath -> True
    ImportS3 -> remoteImports == AllowRemoteImports
    ImportFile -> False
    ImportEnv -> False
    ImportGit -> False
    ImportRandom -> False
    ImportFilehash -> False
    ImportFilehashBase64 -> False
    ImportHttp -> False

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

{- | Run the env provider, turning credential, region and STS failures into
an error message. Other exceptions propagate.
-}
tryBuildEnv :: IO Amazonka.Env -> IO (Either Text Amazonka.Env)
tryBuildEnv mkEnv =
    (Right <$> mkEnv)
        `catches` [ Handler $ \(e :: AuthEx.AuthError) ->
                        pure (Left ("AWS credentials not available: " <> T.pack (show e)))
                  , Handler $ \(e :: IOException) ->
                        pure (Left (T.strip (T.pack (ioeGetErrorString e))))
                  , Handler $ \(e :: Amazonka.Error) ->
                        pure (Left ("AWS configuration failed: " <> T.pack (show e)))
                  ]

-- | Print an import error to stderr in the Rust format and return exit code 1.
reportImportError :: Text -> IO Int
reportImportError err = do
    TIO.hPutStrLn stderr ("Import error: " <> err)
    pure 1

{- | Apply the optional @--query@ to the loaded document, then emit it in the
requested format (Rust @get_import.rs:45-64@). An invalid query prints the
error on stderr, writes nothing to stdout and returns 1.

Rust prints an unqueried YAML document in source key order and sorts the
others (JSON output and query results go through @serde_json@), so only that
case reads 'idOrdered'.
-}
emitDoc :: (OutputData -> IO ()) -> GlobalOpts -> GetImportArgs -> ImportData -> IO Int
emitDoc emit gopts args importData =
    case giaQuery args of
        Nothing -> emitFormat (giaFormat args) (fromMaybe (fromValue doc) (idOrdered importData)) doc
        Just q -> case applyJmesPath q doc of
            Left err -> do
                formatted <- formatJMESPathQueryError (goColor gopts) q err
                TIO.hPutStr stderr formatted
                pure 1
            Right queried -> emitFormat (giaFormat args) (fromValue queried) queried
  where
    doc = idDoc importData
    -- Exhaustive match, no wildcard
    emitFormat fmt ordered sorted = do
        case fmt of
            RenderJson -> emit (OdRawOutput (prettyJsonText sorted <> "\n"))
            RenderYaml -> emit (OdRawOutput (yamlWithNewline ordered))
            RenderCfnYaml -> emit (OdRawOutput (yamlWithNewline ordered))
        pure 0

-- | YAML text ending in exactly one newline (serde_yaml::to_string).
yamlWithNewline :: OValue -> Text
yamlWithNewline v = T.dropWhileEnd (== '\n') (emitYamlWith SeqFlush v) <> "\n"
