-- \$defs, handlebars interpolation, and custom tags before sending to CFN).

{- | CloudFormation template loading.

Handles loading templates from local files, S3 URLs, or inline content.
Supports the render: prefix for YAML preprocessing (resolves $imports,
-}
module Iidy.Cfn.TemplateLoader (
    TemplateResult (..),
    loadCfnTemplate,
    loadCfnTemplateWithLimit,
    TemplateSizeLimit (..),
    inlineTemplateLimit,
    approvalTemplateLimit,
    isTemplateUrl,
    templateMaxBytes,
    s3TemplateMaxBytes,
) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, (</>))

import Iidy.Yaml.Ast (SrcMeta (..), YamlAst (..))
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Engine (
    PreprocessResult (..),
 )
import Iidy.Yaml.Imports.ContentParsing (parseErrorMessage)
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig (..), preprocessWithConfig)
import Iidy.Yaml.Location (zeroPosition)
import Iidy.Yaml.Parser (parseYamlStrict)

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

-- | Maximum template body size for inline (51KB)
templateMaxBytes :: Int
templateMaxBytes = 51199

-- | Maximum template size for S3 (1MB)
s3TemplateMaxBytes :: Int
s3TemplateMaxBytes = 999999

-- | A template size limit and the advice its error ends with.
data TemplateSizeLimit = TemplateSizeLimit
    { tslMaxBytes :: !Int
    , tslAdvice :: !(Maybe Text)
    }
    deriving stock (Show, Eq)

-- | The limit for a template sent inline as the request body.
inlineTemplateLimit :: TemplateSizeLimit
inlineTemplateLimit =
    TemplateSizeLimit templateMaxBytes (Just "Upload to S3 and use the S3 URL instead.")

{- | The limit for a template on the approval path, deployed from the
approved S3 object (iidy-js @S3_TEMPLATE_MAX_BYTES@). URL templates are
refused on that path, so the error suggests no upload.
-}
approvalTemplateLimit :: TemplateSizeLimit
approvalTemplateLimit = TemplateSizeLimit s3TemplateMaxBytes Nothing

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

data TemplateResult = TemplateResult
    { trTemplateBody :: !(Maybe Text)
    , trTemplateUrl :: !(Maybe Text)
    }
    deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Loading
------------------------------------------------------------------------

{- | Load a CloudFormation template.
Handles: file paths, S3 URLs, HTTP URLs, render: prefix, inline content.
The 'ImportConfig' controls AWS credentials and remote import policy
for the render: path (resolves $imports with ssm:, cfn:, s3: schemes).

Returns 'Left' with a descriptive error message on failure, instead of
throwing via 'fail'.
-}
loadCfnTemplate :: Maybe Text -> Maybe FilePath -> Text -> ImportConfig -> IO (Either Text TemplateResult)
loadCfnTemplate = loadCfnTemplateWithLimit inlineTemplateLimit

-- | 'loadCfnTemplate' with a given size limit for the loaded body.
loadCfnTemplateWithLimit ::
    TemplateSizeLimit ->
    Maybe Text ->
    Maybe FilePath ->
    Text ->
    ImportConfig ->
    IO (Either Text TemplateResult)
loadCfnTemplateWithLimit _ Nothing _ _ _ = pure (Right (TemplateResult Nothing Nothing))
loadCfnTemplateWithLimit limit (Just tmplSpec) argsfilePath env importCfg
    -- S3 URL - use as template URL
    | isS3Url tmplSpec = pure (Right (TemplateResult Nothing (Just tmplSpec)))
    -- HTTP(S) URL - use as template URL
    | isHttpUrl tmplSpec = pure (Right (TemplateResult Nothing (Just tmplSpec)))
    -- render: prefix - preprocess YAML through full pipeline
    | Just renderPath <- T.stripPrefix "render:" tmplSpec = do
        let resolvedPath = resolveTemplatePath (T.unpack renderPath) argsfilePath
            baseLocation = T.pack resolvedPath
        rawContent <- BL.readFile resolvedPath
        case parseYamlStrict rawContent baseLocation of
            Left perr ->
                pure (Left ("Parse error in rendered template " <> baseLocation <> ": " <> parseErrorMessage perr))
            Right ast -> do
                -- Inject $envValues before preprocessing (matches Rust template_loader.rs:117-131)
                let astWithEnv = injectEnvValuesIntoAst ast env
                result <- preprocessWithConfig importCfg True astWithEnv baseLocation
                case result of
                    Left err ->
                        pure (Left ("Preprocess error in rendered template " <> baseLocation <> ": " <> T.pack (show err)))
                    Right (PreprocessResult val _manifest) -> do
                        let rendered = emitYaml val
                        case checkTemplateSize limit rendered of
                            Left sizeErr -> pure (Left sizeErr)
                            Right () -> pure (Right (TemplateResult (Just rendered) Nothing))
    -- Local file path
    | otherwise = do
        let resolvedPath = resolveTemplatePath (T.unpack tmplSpec) argsfilePath
        exists <- doesFileExist resolvedPath
        if exists
            then do
                bodyResult <- loadFileContent resolvedPath
                case bodyResult of
                    Left utf8Err -> pure (Left utf8Err)
                    Right body ->
                        -- Error if template uses $imports: without render: prefix
                        if hasImportsKey body
                            then
                                pure
                                    ( Left
                                        ( "Your cloudformation Template from "
                                            <> T.pack resolvedPath
                                            <> " appears to use iidy's yaml pre-processor syntax.\n"
                                            <> "You need to prefix the template location with \"render:\".\n"
                                            <> "e.g.   Template: \"render:"
                                            <> tmplSpec
                                            <> "\""
                                        )
                                    )
                            else case checkTemplateSize limit body of
                                Left sizeErr -> pure (Left sizeErr)
                                Right () -> pure (Right (TemplateResult (Just body) Nothing))
            else pure (loadInlineTemplate resolvedPath tmplSpec)

{- | A Template value that names no existing file: inline content when it
starts with @{@ or @[@ (after trimming) or contains a newline, otherwise
a missing path, reported with the resolved path.  Rust also treats a
short value without a slash as inline (template_loader.rs:57-61); that
accident is dropped here (see DIVERGENCES.md).
-}
loadInlineTemplate :: FilePath -> Text -> Either Text TemplateResult
loadInlineTemplate resolvedPath tmplSpec
    | not (isInlineContent tmplSpec) =
        Left ("Failed to load template from: " <> T.pack resolvedPath <> " (no such file)")
    | hasImportsKey tmplSpec =
        Left
            "Your inline cloudformation Template appears to use iidy's yaml pre-processor syntax.\n\
            \You need to prefix the template with \"render:\"."
    | otherwise = Right (TemplateResult (Just tmplSpec) Nothing)

-- | Text that cannot be a path: a JSON object or array, or multi-line.
isInlineContent :: Text -> Bool
isInlineContent spec =
    let trimmed = T.strip spec
     in "{" `T.isPrefixOf` trimmed || "[" `T.isPrefixOf` trimmed || T.any (== '\n') spec

------------------------------------------------------------------------

-- $envValues injection into AST

------------------------------------------------------------------------

{- | Inject $envValues mapping into the top-level YAML mapping before
preprocessing.  Matches Rust template_loader.rs:117-131 which injects
an 'environment' key so that handlebars templates can reference
{{$envValues.environment}}.
-}
injectEnvValuesIntoAst :: YamlAst -> Text -> YamlAst
injectEnvValuesIntoAst (AstMapping pairs meta) envName =
    let envValuesPairs =
            [
                ( AstPlainString "environment" dummyMeta
                , AstPlainString envName dummyMeta
                )
            ]
        envValuesNode = AstMapping envValuesPairs dummyMeta
        envValuesKey = AstPlainString "$envValues" dummyMeta
        -- Prepend the $envValues entry so it's available to the preprocessor
        pairs' = (envValuesKey, envValuesNode) : pairs
     in AstMapping pairs' meta
injectEnvValuesIntoAst ast _ = ast

-- | Dummy source metadata for injected AST nodes
dummyMeta :: SrcMeta
dummyMeta =
    SrcMeta
        { smInputUri = "<injected>"
        , smStart = zeroPosition
        , smEnd = zeroPosition
        }

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

isS3Url :: Text -> Bool
isS3Url t = T.isPrefixOf "s3://" t || T.isPrefixOf "https://s3" t

isHttpUrl :: Text -> Bool
isHttpUrl t = T.isPrefixOf "http://" t || T.isPrefixOf "https://" t

{- | True when a @Template@ value is an S3 or HTTP(S) URL, which
'loadCfnTemplate' passes on as a template URL instead of loading.
-}
isTemplateUrl :: Text -> Bool
isTemplateUrl t = isS3Url t || isHttpUrl t

-- | Resolve a template path relative to the argsfile directory
resolveTemplatePath :: FilePath -> Maybe FilePath -> FilePath
resolveTemplatePath path (Just argsfile) =
    let dir = takeDirectory argsfile
     in if isAbsolute path then path else dir </> path
resolveTemplatePath path Nothing = path

isAbsolute :: FilePath -> Bool
isAbsolute ('/' : _) = True
isAbsolute _ = False

{- | Read a file and decode its content as UTF-8.
Returns 'Left' with a descriptive error on invalid UTF-8.
-}
loadFileContent :: FilePath -> IO (Either Text Text)
loadFileContent path = do
    bytes <- BS.readFile path
    case TE.decodeUtf8' bytes of
        Right txt -> pure (Right txt)
        Left err -> pure (Left ("Invalid UTF-8 in template file " <> T.pack path <> ": " <> T.pack (show err)))

{- | Check a template body against a size limit, in UTF-8 bytes.
Returns 'Left' with a descriptive message if the body exceeds the limit.
-}
checkTemplateSize :: TemplateSizeLimit -> Text -> Either Text ()
checkTemplateSize limit body =
    let size = BS.length (TE.encodeUtf8 body)
     in if size > tslMaxBytes limit
            then
                Left
                    ( "Template body exceeds maximum size of "
                        <> T.pack (show (tslMaxBytes limit))
                        <> " bytes (got "
                        <> T.pack (show size)
                        <> " bytes)."
                        <> maybe "" (" " <>) (tslAdvice limit)
                    )
            else Right ()

-- | Check if text contains $imports: key (suggesting preprocessing is needed)
hasImportsKey :: Text -> Bool
hasImportsKey = T.isInfixOf "$imports:"
