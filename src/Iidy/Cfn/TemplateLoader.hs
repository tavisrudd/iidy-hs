-- | CloudFormation template loading.
--
-- Handles loading templates from local files, S3 URLs, or inline content.
-- Supports the render: prefix for YAML preprocessing.
module Iidy.Cfn.TemplateLoader
  ( TemplateResult(..)
  , loadCfnTemplate
  , templateMaxBytes
  , s3TemplateMaxBytes
  ) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, (</>))

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

-- | Maximum template body size for inline (51KB)
templateMaxBytes :: Int
templateMaxBytes = 51199

-- | Maximum template size for S3 (1MB)
s3TemplateMaxBytes :: Int
s3TemplateMaxBytes = 999999

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

data TemplateResult = TemplateResult
  { trTemplateBody :: !(Maybe Text)
  , trTemplateUrl  :: !(Maybe Text)
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Loading
------------------------------------------------------------------------

-- | Load a CloudFormation template.
-- Handles: file paths, S3 URLs, HTTP URLs, render: prefix, inline content.
loadCfnTemplate :: Maybe Text -> Maybe FilePath -> Text -> IO TemplateResult
loadCfnTemplate Nothing _ _ = pure (TemplateResult Nothing Nothing)
loadCfnTemplate (Just tmplSpec) argsfilePath _env
  -- S3 URL - use as template URL
  | isS3Url tmplSpec = pure (TemplateResult Nothing (Just tmplSpec))
  -- HTTP(S) URL - use as template URL
  | isHttpUrl tmplSpec = pure (TemplateResult Nothing (Just tmplSpec))
  -- render: prefix - preprocess YAML (future: integrate with YAML engine)
  | Just renderPath <- T.stripPrefix "render:" tmplSpec = do
      let resolvedPath = resolveTemplatePath (T.unpack renderPath) argsfilePath
      body <- loadFileContent resolvedPath
      pure (TemplateResult (Just body) Nothing)
  -- Local file path
  | otherwise = do
      let resolvedPath = resolveTemplatePath (T.unpack tmplSpec) argsfilePath
      exists <- doesFileExist resolvedPath
      if exists
        then do
          body <- loadFileContent resolvedPath
          checkTemplateSize body
          pure (TemplateResult (Just body) Nothing)
        else
          -- Might be inline content
          pure (TemplateResult (Just tmplSpec) Nothing)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

isS3Url :: Text -> Bool
isS3Url t = T.isPrefixOf "s3://" t || T.isPrefixOf "https://s3" t

isHttpUrl :: Text -> Bool
isHttpUrl t = T.isPrefixOf "http://" t || T.isPrefixOf "https://" t

-- | Resolve a template path relative to the argsfile directory
resolveTemplatePath :: FilePath -> Maybe FilePath -> FilePath
resolveTemplatePath path (Just argsfile) =
  let dir = takeDirectory argsfile
  in if isAbsolute path then path else dir </> path
resolveTemplatePath path Nothing = path

isAbsolute :: FilePath -> Bool
isAbsolute ('/':_) = True
isAbsolute _ = False

-- | Load file content as Text
loadFileContent :: FilePath -> IO Text
loadFileContent path = do
  bytes <- BS.readFile path
  pure (TE.decodeUtf8 bytes)

-- | Check template size limit for inline templates
checkTemplateSize :: Text -> IO ()
checkTemplateSize body = do
  let size = BS.length (TE.encodeUtf8 body)
  if size > templateMaxBytes
    then fail $ "Template body exceeds maximum size of "
             <> show templateMaxBytes <> " bytes (got " <> show size <> " bytes). "
             <> "Upload to S3 and use the S3 URL instead."
    else pure ()
