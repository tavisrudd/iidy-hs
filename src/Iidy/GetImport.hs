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
) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.IO (stderr)

import Amazonka qualified

import Iidy.Aws.Config (createAwsEnvFromSettings)
import Iidy.Aws.CredentialSource (AwsSettings)
import Iidy.Cli (GetImportArgs (..), GetImportFormat (..), GlobalOpts (..), importPolicyFromOpts)
import Iidy.Errors.JMESPath (formatJMESPathQueryError)
import Iidy.JsonPretty (prettyJsonText)
import Iidy.Output.Types (OutputData (..))
import Iidy.Yaml.Emitter (SeqStyle (..), emitYamlWith)
import Iidy.Yaml.Imports.Loaders.LazyEnv (lazyAwsDispatcher)
import Iidy.Yaml.Imports.Types (
    ImportData (..),
    ImportError (..),
    rootBase,
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
The provider runs at most once, and only when 'importNeedsAwsEnv' holds for the
location ('lazyAwsDispatcher'). Tests pass a mock environment here.
-}
runGetImportWith :: IO Amazonka.Env -> (OutputData -> IO ()) -> GetImportArgs -> GlobalOpts -> IO Int
runGetImportWith mkEnv emit args gopts = do
    let location = giaImport args
        base = rootBase "."
    loader <- lazyAwsDispatcher mkEnv (importPolicyFromOpts gopts)
    result <- loader location base
    case result of
        Left (ImportError err) -> reportImportError err
        Right importData -> emitDoc emit gopts args importData

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

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
            GetImportJson -> emit (OdRawOutput (prettyJsonText sorted <> "\n"))
            GetImportYaml -> emit (OdRawOutput (yamlWithNewline ordered))
        pure 0

-- | YAML text ending in exactly one newline (serde_yaml::to_string).
yamlWithNewline :: OValue -> Text
yamlWithNewline v = T.dropWhileEnd (== '\n') (emitYamlWith SeqFlush v) <> "\n"
