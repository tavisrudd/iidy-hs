{-# LANGUAGE OverloadedRecordDot #-}

{- | S3 object operations used by template approval: existence check,
upload, download and delete of a single object.
-}
module Iidy.Cfn.S3Objects (
    s3ObjectExists,
    uploadToS3,
    downloadFromS3,
    deleteFromS3,
) where

import Control.Exception (try)
import Control.Monad.Trans.Resource (runResourceT)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Amazonka qualified
import Amazonka.Data qualified as AmazonkaData
import Amazonka.S3 qualified as S3
import Amazonka.S3.DeleteObject qualified as DO
import Amazonka.S3.GetObject qualified as GO
import Amazonka.S3.HeadObject qualified as HO
import Amazonka.S3.PutObject qualified as PO
import Data.Conduit.List qualified as CL

-- | Check if an S3 object exists.
s3ObjectExists :: Amazonka.Env -> Text -> Text -> IO Bool
s3ObjectExists awsEnv bucket key = do
    let req = HO.newHeadObject (S3.BucketName bucket) (S3.ObjectKey key)
    result <- try @Amazonka.Error $ runResourceT $ Amazonka.send awsEnv req
    case result of
        Right _ -> pure True
        Left _ -> pure False

-- | Upload content to S3.
uploadToS3 :: Amazonka.Env -> Text -> Text -> Text -> IO (Either Text ())
uploadToS3 awsEnv bucket key content = do
    let body = Amazonka.toBody (TE.encodeUtf8 content)
        req = PO.newPutObject (S3.BucketName bucket) (S3.ObjectKey key) body
    result <- try @Amazonka.Error $ runResourceT $ Amazonka.send awsEnv req
    case result of
        Left ex -> pure (Left (T.pack (show ex)))
        Right _ -> pure (Right ())

-- | Download content from S3.
downloadFromS3 :: Amazonka.Env -> Text -> Text -> IO (Either Text Text)
downloadFromS3 awsEnv bucket key = do
    let req = GO.newGetObject (S3.BucketName bucket) (S3.ObjectKey key)
    result <- try @Amazonka.Error $ runResourceT $ do
        resp <- Amazonka.send awsEnv req
        chunks <- AmazonkaData.sinkBody resp.body CL.consume
        pure (BS.concat chunks)
    case result of
        Left ex -> pure (Left (T.pack (show ex)))
        Right bs -> case TE.decodeUtf8' bs of
            Left ex -> pure (Left (T.pack (show ex)))
            Right t -> pure (Right t)

-- | Delete an S3 object.
deleteFromS3 :: Amazonka.Env -> Text -> Text -> IO (Either Text ())
deleteFromS3 awsEnv bucket key = do
    let req = DO.newDeleteObject (S3.BucketName bucket) (S3.ObjectKey key)
    result <- try @Amazonka.Error $ runResourceT $ Amazonka.send awsEnv req
    case result of
        Left ex -> pure (Left (T.pack (show ex)))
        Right _ -> pure (Right ())
