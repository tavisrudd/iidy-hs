{-# LANGUAGE OverloadedRecordDot #-}

{- | S3 object operations used by template approval: existence check,
upload, download and delete of a single object.
-}
module Iidy.Cfn.S3Objects (
    HeadResult (..),
    headObject,
    bucketRegion,
    presignGetObject,
    presignExpiry,
    s3ObjectExists,
    ObjectAcl (..),
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
import Data.Time (UTCTime)
import Network.HTTP.Types.Status (statusCode)

import Amazonka qualified
import Amazonka.Data qualified as AmazonkaData
import Amazonka.S3 qualified as S3
import Amazonka.S3.DeleteObject qualified as DO
import Amazonka.S3.GetBucketLocation qualified as GBL
import Amazonka.S3.GetObject qualified as GO
import Amazonka.S3.HeadObject qualified as HO
import Amazonka.S3.PutObject qualified as PO
import Data.Conduit.List qualified as CL

import Iidy.Aws.Errors (formatAwsError)

-- | The outcome of a @HeadObject@ request.
data HeadResult
    = ObjectPresent
    | -- | 404
      ObjectMissing
    | -- | 403
      ObjectAccessDenied
    | -- | any other error, with its text
      ObjectHeadFailed !Text
    deriving stock (Show, Eq)

-- | Send @HeadObject@ for an object and classify the outcome.
headObject :: Amazonka.Env -> Text -> Text -> IO HeadResult
headObject awsEnv bucket key = do
    let req = HO.newHeadObject (S3.BucketName bucket) (S3.ObjectKey key)
    result <- try @Amazonka.Error $ runResourceT $ Amazonka.send awsEnv req
    pure $ case result of
        Right _ -> ObjectPresent
        Left (Amazonka.ServiceError se)
            | statusCode se.status == 404 -> ObjectMissing
            | statusCode se.status == 403 -> ObjectAccessDenied
        Left ex -> ObjectHeadFailed (formatAwsError ex)

{- | Whether an object exists: 'True' when present, 'False' when missing
(404), and an error naming the object for access denied (403) or any other
failure (which also names the env's region).
-}
s3ObjectExists :: Amazonka.Env -> Text -> Text -> IO (Either Text Bool)
s3ObjectExists awsEnv bucket key =
    headObject awsEnv bucket key >>= \case
        ObjectPresent -> pure (Right True)
        ObjectMissing -> pure (Right False)
        ObjectAccessDenied ->
            pure
                ( Left
                    ( "Access denied (403) checking "
                        <> location
                        <> ": the current credentials cannot read the template approval bucket"
                        <> " (S3 also answers 403 for a missing object when s3:ListBucket is not granted)"
                    )
                )
        ObjectHeadFailed err ->
            pure
                ( Left
                    ( "Failed to check "
                        <> location
                        <> " in region "
                        <> Amazonka.fromRegion (Amazonka.region awsEnv)
                        <> ": "
                        <> err
                    )
                )
  where
    location = "s3://" <> bucket <> "/" <> key

-- | The canned ACL an upload carries.
data ObjectAcl
    = -- | none: the bucket's default
      DefaultAcl
    | -- | @bucket-owner-full-control@
      BucketOwnerFullControl
    deriving stock (Show, Eq)

{- | A bucket's region from @GetBucketLocation@, sent through the given env
(amazonka maps the empty answer to us-east-1 and @EU@ to eu-west-1).
-}
bucketRegion :: Amazonka.Env -> Text -> IO (Either Text Amazonka.Region)
bucketRegion awsEnv bucket = do
    let req = GBL.newGetBucketLocation (S3.BucketName bucket)
    result <- try @Amazonka.Error $ runResourceT $ Amazonka.send awsEnv req
    pure $ case result of
        Left (Amazonka.ServiceError se) ->
            let Amazonka.ErrorCode code = se.code
             in Left (T.pack (show (statusCode se.status)) <> " " <> code)
        Left ex -> Left (formatAwsError ex)
        Right resp -> Right (S3.constraintRegion resp.locationConstraint)

{- | How long a presigned URL stays valid: 900 seconds, the aws-sdk v2
@getSignedUrl@ default iidy-js relied on.
-}
presignExpiry :: Amazonka.Seconds
presignExpiry = 900

{- | A presigned HTTPS @GetObject@ URL for an object, signed with the env's
current credentials for the env's region at the given time. Makes no HTTP
call.
-}
presignGetObject :: Amazonka.Env -> UTCTime -> Text -> Text -> IO Text
presignGetObject awsEnv signingTime bucket key = do
    let req = GO.newGetObject (S3.BucketName bucket) (S3.ObjectKey key)
    TE.decodeUtf8Lenient <$> Amazonka.presignURL awsEnv signingTime presignExpiry req

-- | Upload content to S3 with the given ACL.
uploadToS3 :: Amazonka.Env -> ObjectAcl -> Text -> Text -> Text -> IO (Either Text ())
uploadToS3 awsEnv acl bucket key content = do
    let body = Amazonka.toBody (TE.encodeUtf8 content)
        cannedAcl = case acl of
            DefaultAcl -> Nothing
            BucketOwnerFullControl -> Just S3.ObjectCannedACL_Bucket_owner_full_control
        req = (PO.newPutObject (S3.BucketName bucket) (S3.ObjectKey key) body){PO.acl = cannedAcl}
    result <- try @Amazonka.Error $ runResourceT $ Amazonka.send awsEnv req
    case result of
        Left ex -> pure (Left (formatAwsError ex))
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
        Left ex -> pure (Left (formatAwsError ex))
        Right bs -> case TE.decodeUtf8' bs of
            Left ex -> pure (Left (T.pack (show ex)))
            Right t -> pure (Right t)

-- | Delete an S3 object.
deleteFromS3 :: Amazonka.Env -> Text -> Text -> IO (Either Text ())
deleteFromS3 awsEnv bucket key = do
    let req = DO.newDeleteObject (S3.BucketName bucket) (S3.ObjectKey key)
    result <- try @Amazonka.Error $ runResourceT $ Amazonka.send awsEnv req
    case result of
        Left ex -> pure (Left (formatAwsError ex))
        Right _ -> pure (Right ())
