{-# LANGUAGE OverloadedRecordDot #-}
-- | S3 import loader: fetch objects from Amazon S3.
module Iidy.Yaml.Imports.Loaders.S3
  ( loadS3Import
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Trans.Resource (runResourceT)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import qualified Amazonka
import qualified Amazonka.Data as AmazonkaData
import qualified Amazonka.S3 as S3
import qualified Amazonka.S3.GetObject as GO
import qualified Data.Conduit.List as CL

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

-- | Load an import from an S3 URI.
-- Accepts @s3://bucket/key@ (or with the @s3:@ prefix already stripped).
-- Returns the object content as UTF-8 text, or an error message.
loadS3Import :: Amazonka.Env -> Text -> IO (Either Text Text)
loadS3Import awsEnv location = do
  let uri = maybe location id (T.stripPrefix "s3:" location)
  case parseS3Uri uri of
    Left err -> pure (Left err)
    Right (bucket, key) -> do
      result <- try @SomeException (fetchS3Object awsEnv bucket key)
      case result of
        Left ex  -> pure $ Left $ "S3 fetch error for " <> uri <> ": " <> T.pack (show ex)
        Right bs -> case TE.decodeUtf8' bs of
          Left ex  -> pure $ Left $ "UTF-8 decode error for " <> uri <> ": " <> T.pack (show ex)
          Right t  -> pure (Right t)

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
-- URI parsing
------------------------------------------------------------------------

-- | Parse an S3 URI into (bucket, key).
-- Accepts @//bucket/key@ (after stripping @s3:@) or plain @bucket/key@.
parseS3Uri :: Text -> Either Text (S3.BucketName, S3.ObjectKey)
parseS3Uri uri =
  let withoutSlashes = maybe uri id (T.stripPrefix "//" uri)
  in parseBucketKey withoutSlashes

-- | Parse @bucket/key@ into its components.
parseBucketKey :: Text -> Either Text (S3.BucketName, S3.ObjectKey)
parseBucketKey text =
  case T.breakOn "/" text of
    (bucket, rest)
      | T.null bucket ->
          Left $ "S3 URI has empty bucket name: " <> text
      | T.null rest ->
          Left $ "S3 URI missing key (no '/' after bucket): " <> text
      | otherwise ->
          let key = T.drop 1 rest  -- drop the leading "/"
          in if T.null key
             then Left $ "S3 URI has empty key: " <> text
             else Right (S3.BucketName bucket, S3.ObjectKey key)
