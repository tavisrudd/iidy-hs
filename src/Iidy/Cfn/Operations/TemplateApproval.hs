-- | Template approval request and review workflows.
--
-- The request flow uploads a pending template to S3.
-- The review flow downloads, diffs, and optionally approves a pending template.
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Iidy.Cfn.Operations.TemplateApproval
  ( templateApprovalRequest
  , templateApprovalReview
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
import qualified Amazonka.S3.PutObject as PO
import qualified Amazonka.S3.HeadObject as HO
import qualified Amazonka.S3.DeleteObject as DO
import qualified Data.Conduit.List as CL

import Iidy.Confirm (requestConfirmation)
import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Cfn.TemplateHash (generateVersionedLocation, parseS3Url)
import Iidy.Cfn.TemplateLoader (loadCfnTemplate, TemplateResult(..))
import Iidy.Cfn.Types (StackArgs(..))
import Iidy.Output.Types

------------------------------------------------------------------------
-- Template Approval Request
------------------------------------------------------------------------

-- | Request approval for a template by uploading it as .pending to S3.
templateApprovalRequest
  :: CfnContext
  -> StackArgs
  -> Bool       -- ^ lint template
  -> Maybe FilePath -- ^ argsfile
  -> Text       -- ^ environment
  -> (OutputData -> IO ())  -- ^ emit callback
  -> IO (Either Text Int)
templateApprovalRequest ctx sa _lintTmpl argsfilePath env emit = do
  -- Validate required fields
  case saApprovedTemplateLocation sa of
    Nothing -> pure (Left "ApprovedTemplateLocation is required in stack-args.yaml")
    Just baseLocation -> do
      case saTemplate sa of
        Nothing -> pure (Left "Template is required in stack-args.yaml")
        Just _tmplSpec -> do
          -- Load template
          tmplResult <- loadCfnTemplate (saTemplate sa) (fmap id argsfilePath) env (Just (cfnEnv ctx))
          case trTemplateBody tmplResult of
            Nothing -> pure (Left "Failed to load template body")
            Just body -> do
              -- Generate versioned location
              let tmplPath = maybe "template.yaml" T.unpack (saTemplate sa)
              case generateVersionedLocation baseLocation body (T.pack tmplPath) of
                Left err -> pure (Left err)
                Right (bucket, key) -> do
                  let s3Loc = "s3://" <> bucket <> "/" <> key
                  -- Check if already approved
                  alreadyApproved <- s3ObjectExists (cfnEnv ctx) bucket key
                  if alreadyApproved
                    then do
                      emit $ OdApprovalRequestResult ApprovalRequestResult
                        { arrTemplateLocation = s3Loc
                        , arrPendingLocation  = s3Loc
                        , arrAlreadyApproved  = True
                        , arrNextSteps        = ["Template has already been approved"]
                        }
                      pure (Right 0)
                    else do
                      -- Upload pending template
                      let pendingKey = key <> ".pending"
                          pendingLoc = "s3://" <> bucket <> "/" <> pendingKey
                      uploadResult <- uploadToS3 (cfnEnv ctx) bucket pendingKey body
                      case uploadResult of
                        Left err -> pure (Left ("Failed to upload pending template: " <> err))
                        Right () -> do
                          emit $ OdApprovalRequestResult ApprovalRequestResult
                            { arrTemplateLocation = s3Loc
                            , arrPendingLocation  = pendingLoc
                            , arrAlreadyApproved  = False
                            , arrNextSteps        = ["Review with: iidy-hs template-approval review " <> pendingLoc]
                            }
                          pure (Right 0)

------------------------------------------------------------------------
-- Template Approval Review
------------------------------------------------------------------------

-- | Review a pending template approval.
templateApprovalReview
  :: CfnContext
  -> Text       -- ^ S3 URL of pending template
  -> Int        -- ^ context lines for diff
  -> (OutputData -> IO ())  -- ^ emit callback
  -> IO (Either Text Int)
templateApprovalReview ctx url contextLines emit = do
  -- Parse S3 URL
  case parseS3Url url of
    Left err -> pure (Left err)
    Right (bucket, pendingKey) -> do
      -- Validate .pending suffix
      if not (T.isSuffixOf ".pending" pendingKey)
        then pure (Left "URL must end with .pending suffix")
        else do
          let approvedKey = T.dropEnd 8 pendingKey  -- remove ".pending"
              -- Derive latest key from parent directory
              parentDir = case T.breakOnEnd "/" pendingKey of
                ("", _) -> ""
                (dir, _) -> T.dropEnd 1 dir
              latestKey = if T.null parentDir
                          then "latest"
                          else parentDir <> "/latest"
              approvedLoc = "s3://" <> bucket <> "/" <> approvedKey

          -- Check pending exists
          pendingExists <- s3ObjectExists (cfnEnv ctx) bucket pendingKey
          if not pendingExists
            then pure (Left ("Pending template not found at " <> url))
            else do
              -- Check if already approved
              alreadyApproved <- s3ObjectExists (cfnEnv ctx) bucket approvedKey

              -- Emit approval status
              emit $ OdApprovalStatus ApprovalStatus
                { apsPendingExists    = pendingExists
                , apsAlreadyApproved  = alreadyApproved
                , apsPendingLocation  = url
                , apsApprovedLocation = if alreadyApproved then Just approvedLoc else Nothing
                }

              if alreadyApproved
                then pure (Right 0)
                else do
                  -- Download templates
                  pendingTemplate <- downloadFromS3 (cfnEnv ctx) bucket pendingKey
                  latestTemplate <- downloadFromS3 (cfnEnv ctx) bucket latestKey

                  case pendingTemplate of
                    Left err -> pure (Left ("Failed to download pending template: " <> err))
                    Right pending -> do
                      let latest = either (const "") id latestTemplate

                      -- Generate and emit diff
                      let diffOutput = generateDiff latest pending
                          hasChanges = not (T.null diffOutput)
                      emit $ OdTemplateDiff TemplateDiff
                        { tdDiffOutput   = diffOutput
                        , tdContextLines = contextLines
                        , tdHasChanges   = hasChanges
                        }

                      if not hasChanges
                        then do
                          emit $ OdApprovalResult ApprovalResult
                            { arApproved         = True
                            , arApprovedLocation = Just approvedLoc
                            , arLatestLocation   = Just ("s3://" <> bucket <> "/" <> latestKey)
                            , arCleanupCompleted = False
                            }
                          pure (Right 0)
                        else do
                          -- Request confirmation
                          confirmed <- requestConfirmation "Would you like to approve these changes?"
                          if confirmed
                            then do
                              -- Approve: copy pending to approved and latest, delete pending
                              uploadApproved <- uploadToS3 (cfnEnv ctx) bucket approvedKey pending
                              case uploadApproved of
                                Left err -> pure (Left ("Failed to upload approved template: " <> err))
                                Right () -> do
                                  uploadLatest <- uploadToS3 (cfnEnv ctx) bucket latestKey pending
                                  case uploadLatest of
                                    Left err -> pure (Left ("Failed to upload latest template: " <> err))
                                    Right () -> do
                                      deleteResult <- deleteFromS3 (cfnEnv ctx) bucket pendingKey
                                      case deleteResult of
                                        Left err -> pure (Left ("Failed to delete pending template: " <> err))
                                        Right () -> do
                                          emit $ OdApprovalResult ApprovalResult
                                            { arApproved         = True
                                            , arApprovedLocation = Just approvedLoc
                                            , arLatestLocation   = Just ("s3://" <> bucket <> "/" <> latestKey)
                                            , arCleanupCompleted = True
                                            }
                                          pure (Right 0)
                            else do
                              emit $ OdApprovalResult ApprovalResult
                                { arApproved         = False
                                , arApprovedLocation = Nothing
                                , arLatestLocation   = Nothing
                                , arCleanupCompleted = False
                                }
                              pure (Right 1)

------------------------------------------------------------------------
-- S3 helpers
------------------------------------------------------------------------

-- | Check if an S3 object exists.
s3ObjectExists :: Amazonka.Env -> Text -> Text -> IO Bool
s3ObjectExists awsEnv bucket key = do
  let req = HO.newHeadObject (S3.BucketName bucket) (S3.ObjectKey key)
  result <- try @SomeException $ runResourceT $ Amazonka.send awsEnv req
  case result of
    Right _ -> pure True
    Left _  -> pure False

-- | Upload content to S3.
uploadToS3 :: Amazonka.Env -> Text -> Text -> Text -> IO (Either Text ())
uploadToS3 awsEnv bucket key content = do
  let body = Amazonka.toBody (TE.encodeUtf8 content)
      req = (PO.newPutObject (S3.BucketName bucket) (S3.ObjectKey key) body)
  result <- try @SomeException $ runResourceT $ Amazonka.send awsEnv req
  case result of
    Left ex  -> pure (Left (T.pack (show ex)))
    Right _  -> pure (Right ())

-- | Download content from S3.
downloadFromS3 :: Amazonka.Env -> Text -> Text -> IO (Either Text Text)
downloadFromS3 awsEnv bucket key = do
  let req = GO.newGetObject (S3.BucketName bucket) (S3.ObjectKey key)
  result <- try @SomeException $ runResourceT $ do
    resp <- Amazonka.send awsEnv req
    chunks <- AmazonkaData.sinkBody resp.body CL.consume
    pure (BS.concat chunks)
  case result of
    Left ex -> pure (Left (T.pack (show ex)))
    Right bs -> case TE.decodeUtf8' bs of
      Left ex  -> pure (Left (T.pack (show ex)))
      Right t  -> pure (Right t)

-- | Delete an S3 object.
deleteFromS3 :: Amazonka.Env -> Text -> Text -> IO (Either Text ())
deleteFromS3 awsEnv bucket key = do
  let req = DO.newDeleteObject (S3.BucketName bucket) (S3.ObjectKey key)
  result <- try @SomeException $ runResourceT $ Amazonka.send awsEnv req
  case result of
    Left ex  -> pure (Left (T.pack (show ex)))
    Right _  -> pure (Right ())

------------------------------------------------------------------------
-- Diff generation
------------------------------------------------------------------------

-- | Generate a simple line diff between old and new content.
generateDiff :: Text -> Text -> Text
generateDiff old new
  | old == new = ""
  | otherwise =
      let oldLines = T.lines old
          newLines = T.lines new
          -- Simple diff: show removed and added lines
          removed = filter (`notElem` newLines) oldLines
          added = filter (`notElem` oldLines) newLines
      in T.unlines $
           map (\l -> "- " <> l) removed ++
           map (\l -> "+ " <> l) added

