module Iidy.Render (
    runRender,
    runRenderWith,
) where

import Amazonka qualified
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.IO (stderr)

import Iidy.Aws.Config (createAwsEnvFromSettings)
import Iidy.Aws.CredentialSource (AwsSettings)
import Iidy.Cli (GlobalOpts (..), RenderArgs (..), RenderFormat (..), importPolicyFromOpts)
import Iidy.Errors.JMESPath (formatJMESPathQueryError)
import Iidy.JsonPretty (prettyJsonText)
import Iidy.Output.Types (OutputData (..))
import Iidy.Types (YamlSpec (..))
import Iidy.Yaml.Ast (YamlAst)
import Iidy.Yaml.Detection (detectYamlSpec, shouldUseYaml11Compatibility)
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Engine (
    LoadImportFn,
    PreprocessError,
    PreprocessResult (..),
 )
import Iidy.Yaml.Errors.Conversion (formatParseErrorEnhanced, formatPreprocessErrorEnhanced)
import Iidy.Yaml.Imports.Loaders.Dispatch (preprocessWithPolicy)
import Iidy.Yaml.Imports.Loaders.LazyEnv (lazyAwsDispatcher)
import Iidy.Yaml.Imports.Types (ImportPolicy)
import Iidy.Yaml.JMESPath (JMESPathError, applyJmesPath)
import Iidy.Yaml.Location (Position)
import Iidy.Yaml.OValue (OValue, fromValue, toValue)
import Iidy.Yaml.Parser (ParseError (..), parseYamlStrict)

------------------------------------------------------------------------
-- Error type
------------------------------------------------------------------------

data RenderError
    = ParseFailed !Position !Text
    | PreprocessFailed !PreprocessError
    | InvalidQuery !Text !JMESPathError
    | OutputFileExists !Text

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

{- | Run the render command.  Returns 0 on success, 1 on error.
The emitter callback is used to send stdout output through the output pipeline.
-}
runRender :: (OutputData -> IO ()) -> RenderArgs -> GlobalOpts -> AwsSettings -> IO Int
runRender emit args gopts awsSettings =
    runRenderWith (fst <$> createAwsEnvFromSettings awsSettings) emit args gopts

{- | 'runRender' with an explicit AWS environment provider. The provider runs
at most once, at the first AWS-backed import the gate lets through, so a
template without AWS imports needs no credentials. Tests pass a mock here.
-}
runRenderWith :: IO Amazonka.Env -> (OutputData -> IO ()) -> RenderArgs -> GlobalOpts -> IO Int
runRenderWith mkEnv emit args gopts = do
    (content, baseLocation) <- readTemplate args
    let source = TE.decodeUtf8 (BL.toStrict content)
        policy = importPolicyFromOpts gopts
    loader <- lazyAwsDispatcher mkEnv policy
    result <- runExceptT $ do
        ast <- ExceptT . pure $ parseStep content baseLocation
        val <- ExceptT $ preprocessStep source policy loader ast
        outputVal <- ExceptT . pure $ queryStep val
        ExceptT $ writeStep outputVal
    either (reportError baseLocation source) pure result
  where
    parseStep :: BL.ByteString -> Text -> Either RenderError YamlAst
    parseStep content baseLocation =
        case parseYamlStrict content baseLocation of
            Left (ParseError pos msg) -> Left (ParseFailed pos msg)
            Right ast -> Right ast

    preprocessStep :: Text -> ImportPolicy -> LoadImportFn -> YamlAst -> IO (Either RenderError OValue)
    preprocessStep source policy loader ast = do
        let useYaml11 = case raYamlSpec args of
                YamlV11 -> True
                YamlV12 -> False
                YamlAuto -> shouldUseYaml11Compatibility (detectYamlSpec source)
        result <- preprocessWithPolicy policy loader useYaml11 ast (raTemplate args)
        pure $ case result of
            Left err -> Left (PreprocessFailed err)
            Right (PreprocessResult val _manifest) -> Right val

    queryStep :: OValue -> Either RenderError OValue
    queryStep val =
        case raQuery args of
            Nothing -> Right val
            Just query -> case applyJmesPath query (toValue val) of
                Left err -> Left (InvalidQuery query err)
                Right filt -> Right (fromValue filt)

    writeStep :: OValue -> IO (Either RenderError Int)
    writeStep outputVal = do
        let rendered = case raFormat args of
                RenderJson -> prettyJsonText (toValue outputVal)
                RenderYaml -> emitYaml outputVal
                RenderCfnYaml -> emitYaml outputVal
            outPath = raOutfile args
        if isStdoutTarget outPath
            then emit (OdRawOutput (rendered <> "\n")) >> pure (Right 0)
            else do
                exists <- doesFileExist (T.unpack outPath)
                if exists && not (raOverwrite args)
                    then pure (Left (OutputFileExists outPath))
                    else do
                        TIO.writeFile (T.unpack outPath) rendered
                        pure (Right 0)

    reportError :: Text -> Text -> RenderError -> IO Int
    reportError baseLocation source = \case
        ParseFailed pos msg -> do
            formatted <- formatParseErrorEnhanced (goColor gopts) baseLocation source pos msg
            TIO.hPutStr stderr formatted
            pure 1
        PreprocessFailed err -> do
            formatted <- formatPreprocessErrorEnhanced (goColor gopts) baseLocation source err
            TIO.hPutStr stderr formatted
            pure 1
        InvalidQuery query err -> do
            formatted <- formatJMESPathQueryError (goColor gopts) query err
            TIO.hPutStr stderr formatted
            pure 1
        OutputFileExists p ->
            TIO.hPutStrLn stderr ("Output file '" <> p <> "' exists. Use --overwrite to overwrite it.") >> pure 1

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

readTemplate :: RenderArgs -> IO (BL.ByteString, Text)
readTemplate args = do
    let path = raTemplate args
    content <- if path == "-" then BL.getContents else BL.readFile (T.unpack path)
    pure (content, path)

isStdoutTarget :: Text -> Bool
isStdoutTarget t = t == "-" || t == "stdout"
