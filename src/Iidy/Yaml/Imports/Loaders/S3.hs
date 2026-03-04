{-# LANGUAGE OverloadedRecordDot #-}
-- | S3 import loader: fetch objects from Amazon S3.
module Iidy.Yaml.Imports.Loaders.S3
  ( loadS3Import
  , parseS3Uri
  ) where

import Control.Exception (Exception, catches, throwIO, Handler(..))
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Resource (ResourceT, runResourceT)
import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import qualified Amazonka
import qualified Amazonka.Data as AmazonkaData
import qualified Amazonka.S3 as S3
import qualified Amazonka.S3.GetObject as GO
import Data.Conduit (ConduitT, await)

import Iidy.Constants (httpMaxResponseBytes)
import Iidy.Yaml.Imports.ContentParsing (parseByExtensionStrict)
import Iidy.Yaml.Imports.Types (ImportData(..), ImportError(..), ImportType(..))

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

-- | Load an import from an S3 URI.
-- Accepts @s3://bucket/key@ (or with the @s3:@ prefix already stripped).
-- Content-type detection is based on the object key extension.
loadS3Import :: Amazonka.Env -> Text -> IO (Either ImportError ImportData)
loadS3Import awsEnv location = do
  let uri = fromMaybe location (T.stripPrefix "s3:" location)
  case parseS3Uri uri of
    Left err -> pure (Left err)
    Right (bucket, key) -> do
      let mkError :: Text -> IO (Either ImportError ImportData)
          mkError msg = pure $ Left $ ImportError $
            "S3 fetch error for " <> uri <> ": " <> msg
      (do bs <- fetchS3Object awsEnv bucket key
          case TE.decodeUtf8' bs of
            Left ex -> pure $ Left $ ImportError $
              "UTF-8 decode error for " <> uri <> ": " <> T.pack (show ex)
            Right content ->
              let S3.ObjectKey keyText = key
                  ext = T.unpack (extractExtension keyText)
              in case parseByExtensionStrict ext content bs of
                   Left err -> pure (Left err)
                   Right doc -> pure $ Right $ ImportData
                     { idType     = ImportS3
                     , idLocation = location
                     , idRawData  = content
                     , idDoc      = doc
                     }
        ) `catches`
          [ Handler $ \(e :: Amazonka.Error) -> mkError (T.pack (show e))
          , Handler $ \(e :: S3SizeLimitExceeded) -> mkError (T.pack (show e))
          ]

------------------------------------------------------------------------
-- S3 fetch
------------------------------------------------------------------------

-- | Thrown when the S3 response body exceeds the maximum allowed size.
data S3SizeLimitExceeded = S3SizeLimitExceeded Int
  deriving stock (Show)

instance Exception S3SizeLimitExceeded

-- | Maximum S3 import body size, matching the HTTP loader limit.
s3MaxResponseBytes :: Int
s3MaxResponseBytes = httpMaxResponseBytes

-- | Fetch an S3 object and return the raw bytes.
-- Enforces the same size limit as the HTTP loader ('httpMaxResponseBytes')
-- by checking accumulated bytes incrementally during streaming and throwing
-- 'S3SizeLimitExceeded' before the full body is buffered.
fetchS3Object :: Amazonka.Env -> S3.BucketName -> S3.ObjectKey -> IO BS.ByteString
fetchS3Object awsEnv bucket key = runResourceT $ do
  let req = GO.newGetObject bucket key
  resp <- Amazonka.send awsEnv req
  chunks <- AmazonkaData.sinkBody resp.body (limitedConsume s3MaxResponseBytes)
  pure (BS.concat chunks)

-- | Consume chunks from a conduit, aborting with 'S3SizeLimitExceeded'
-- as soon as accumulated bytes exceed the limit.
limitedConsume :: Int -> ConduitT BS.ByteString o (ResourceT IO) [BS.ByteString]
limitedConsume maxBytes = go 0 []
  where
    go :: Int -> [BS.ByteString] -> ConduitT BS.ByteString o (ResourceT IO) [BS.ByteString]
    go !acc chunks = do
      mChunk <- await
      case mChunk of
        Nothing -> pure (reverse chunks)
        Just chunk ->
          let newAcc = acc + BS.length chunk
          in if newAcc > maxBytes
             then liftIO $ throwIO (S3SizeLimitExceeded maxBytes)
             else go newAcc (chunk : chunks)

------------------------------------------------------------------------
-- URI parsing
------------------------------------------------------------------------

-- | Parse an S3 URI into (bucket, key).
-- Accepts @//bucket/key@ (after stripping @s3:@) or plain @bucket/key@.
parseS3Uri :: Text -> Either ImportError (S3.BucketName, S3.ObjectKey)
parseS3Uri uri =
  let withoutSlashes = fromMaybe uri (T.stripPrefix "//" uri)
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
