{-# LANGUAGE OverloadedRecordDot #-}
-- | S3 import loader: fetch objects from Amazon S3.
module Iidy.Yaml.Imports.Loaders.S3
  ( loadS3Import
  , parseS3Uri
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import qualified Amazonka
import qualified Amazonka.Data as AmazonkaData
import qualified Amazonka.S3 as S3
import qualified Amazonka.S3.GetObject as GO
import qualified Data.Conduit.List as CL

import Iidy.Yaml.Imports.Types (ImportData(..), ImportError(..), ImportType(..))
import Iidy.Yaml.Parser (parseYaml)
import Iidy.Yaml.Resolution.Resolver (astToValueRaw)

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

-- | Load an import from an S3 URI.
-- Accepts @s3://bucket/key@ (or with the @s3:@ prefix already stripped).
-- Content-type detection is based on the object key extension.
loadS3Import :: Amazonka.Env -> Text -> IO (Either ImportError ImportData)
loadS3Import awsEnv location = do
  let uri = maybe location id (T.stripPrefix "s3:" location)
  case parseS3Uri uri of
    Left err -> pure (Left err)
    Right (bucket, key) -> do
      result <- try @SomeException (fetchS3Object awsEnv bucket key)
      case result of
        Left ex -> pure $ Left $ ImportError $
          "S3 fetch error for " <> uri <> ": " <> T.pack (show ex)
        Right bs -> case TE.decodeUtf8' bs of
          Left ex -> pure $ Left $ ImportError $
            "UTF-8 decode error for " <> uri <> ": " <> T.pack (show ex)
          Right content ->
            let S3.ObjectKey keyText = key
                ext = T.unpack (extractExtension keyText)
            in case parseByExtension ext content bs of
                 Left err -> pure (Left err)
                 Right doc -> pure $ Right $ ImportData
                   { idType     = ImportS3
                   , idLocation = location
                   , idRawData  = content
                   , idDoc      = doc
                   }

------------------------------------------------------------------------
-- S3 fetch
------------------------------------------------------------------------

-- | Fetch an S3 object and return the raw bytes.
fetchS3Object :: Amazonka.Env -> S3.BucketName -> S3.ObjectKey -> IO BS.ByteString
fetchS3Object awsEnv bucket key = runResourceT $ do
  let req = GO.newGetObject bucket key
  resp <- Amazonka.send awsEnv req
  chunks <- AmazonkaData.sinkBody resp.body CL.consume
  pure (BS.concat chunks)

------------------------------------------------------------------------
-- Content parsing
------------------------------------------------------------------------

-- | Parse content based on file extension.
-- Matches JS behavior: throws on parse failure for yaml/json extensions.
parseByExtension :: String -> Text -> BS.ByteString -> Either ImportError Value
parseByExtension ext content rawBytes
  | ext `elem` [".yaml", ".yml"] = parseYamlStrict content
  | ext == ".json"               = parseJsonStrict rawBytes
  | otherwise                    = Right (String content)

parseYamlStrict :: Text -> Either ImportError Value
parseYamlStrict content =
  case parseYaml (BL.fromStrict (TE.encodeUtf8 content)) "<s3-import>" of
    Right ast -> Right (astToValueRaw ast)
    Left err  -> Left $ ImportError $
      "Failed to parse YAML from S3 object: " <> T.pack (show err)

parseJsonStrict :: BS.ByteString -> Either ImportError Value
parseJsonStrict rawBytes =
  case Aeson.eitherDecodeStrict' rawBytes of
    Right v -> Right v
    Left err -> Left $ ImportError $
      "Failed to parse JSON from S3 object: " <> T.pack err

------------------------------------------------------------------------
-- URI parsing
------------------------------------------------------------------------

-- | Parse an S3 URI into (bucket, key).
-- Accepts @//bucket/key@ (after stripping @s3:@) or plain @bucket/key@.
parseS3Uri :: Text -> Either ImportError (S3.BucketName, S3.ObjectKey)
parseS3Uri uri =
  let withoutSlashes = maybe uri id (T.stripPrefix "//" uri)
  in parseBucketKey withoutSlashes

-- | Parse @bucket/key@ into its components.
parseBucketKey :: Text -> Either ImportError (S3.BucketName, S3.ObjectKey)
parseBucketKey text =
  case T.breakOn "/" text of
    (bucket, rest)
      | T.null bucket ->
          Left $ ImportError $ "S3 URI has empty bucket name: " <> text
      | T.null rest ->
          Left $ ImportError $ "S3 URI missing key (no '/' after bucket): " <> text
      | otherwise ->
          let key = T.drop 1 rest  -- drop the leading "/"
          in if T.null key
             then Left $ ImportError $ "S3 URI has empty key: " <> text
             else Right (S3.BucketName bucket, S3.ObjectKey key)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Extract file extension from a path (e.g., "path/to/file.yaml" -> ".yaml").
extractExtension :: Text -> Text
extractExtension path =
  let filename = snd (T.breakOnEnd "/" path)
      name = if T.null filename then path else filename
  in case T.breakOnEnd "." name of
       (_, ext) | T.null ext -> ""
       (prefix, _ext) | T.null prefix -> ""  -- no dot found
       (_, ext) -> "." <> ext
