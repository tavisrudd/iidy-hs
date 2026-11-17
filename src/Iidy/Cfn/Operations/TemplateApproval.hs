{-# LANGUAGE OverloadedStrings #-}

{- | Template approval request and review workflows.

The request flow uploads a pending template to S3.
The review flow downloads, diffs, and optionally approves a pending template.
-}
module Iidy.Cfn.Operations.TemplateApproval (
    templateApprovalRequest,
    templateApprovalReview,
) where

import Control.Monad (unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Either (fromRight)
import Data.Text (Text)
import Data.Text qualified as T

import Iidy.Cfn.ApprovedTemplate (
    ApprovalS3 (..),
    ApprovedTemplate (..),
    approvalObjectExists,
    approvalS3Env,
    approvedKeyFromPending,
    approvedTemplateFor,
    latestKeyFromPending,
    pendingKeyFor,
 )
import Iidy.Cfn.Context (CfnContext (..))
import Iidy.Cfn.Operations.LintTemplate (validateTemplateBody)
import Iidy.Cfn.S3Objects (ObjectAcl (..), deleteFromS3, downloadFromS3, uploadToS3)
import Iidy.Cfn.TemplateDiff (generateDiff)
import Iidy.Cfn.TemplateHash (parseS3Url)
import Iidy.Cfn.Types (StackArgs)
import Iidy.Confirm (ConfirmResult (..), requestConfirmation)
import Iidy.Output.Types

------------------------------------------------------------------------
-- Template Approval Request
------------------------------------------------------------------------

-- | Request approval for a template by uploading it as .pending to S3.
templateApprovalRequest ::
    CfnContext ->
    StackArgs ->
    -- | lint template
    Bool ->
    -- | argsfile
    Maybe FilePath ->
    IO (Either Text Int)
templateApprovalRequest ctx sa lintTmpl argsfilePath = do
    let emit = cfnEmit ctx
    runExceptT $ do
        -- Approved location and rendered body (refuses URL or missing Template)
        approved <- liftExceptT (approvedTemplateFor ctx sa argsfilePath)
        ApprovedTemplate bucket key body <-
            liftMaybe "ApprovedTemplateLocation is required in stack-args.yaml" approved

        let s3Loc = "s3://" <> bucket <> "/" <> key

        -- S3 calls go to the bucket's region; CloudFormation calls keep ctx
        s3 <- lift (approvalS3Env (cfnEnv ctx) bucket)
        let s3Ctx = ctx{cfnEnv = asEnv s3}

        -- Check if already approved
        alreadyApproved <- liftExceptT (approvalObjectExists s3 bucket key)
        if alreadyApproved
            then do
                lift $
                    emit $
                        OdApprovalRequestResult
                            ApprovalRequestResult
                                { arrTemplateLocation = s3Loc
                                , arrPendingLocation = s3Loc
                                , arrAlreadyApproved = True
                                , arrNextSteps = ["Template has already been approved"]
                                }
                pure 0
            else do
                -- Lint the rendered local body before upload (Rust
                -- template_approval_request.rs:79-89; iidy-js lints locally)
                lintFailed <- lift $ lintFails ctx lintTmpl body
                if lintFailed then pure 1 else uploadPending s3Ctx bucket key body

-- | Upload the pending template (with bucket-owner-full-control, as iidy-js).
uploadPending ::
    CfnContext ->
    -- | S3 bucket
    Text ->
    -- | approved object key
    Text ->
    -- | rendered template body
    Text ->
    ExceptT Text IO Int
uploadPending ctx bucket key body = do
    let s3Loc = "s3://" <> bucket <> "/" <> key
        pendingKey = pendingKeyFor key
        pendingLoc = "s3://" <> bucket <> "/" <> pendingKey
    liftExceptT (uploadToS3 (cfnEnv ctx) BucketOwnerFullControl bucket pendingKey body)
        `prefixError` "Failed to upload pending template: "
    lift $
        cfnEmit ctx $
            OdApprovalRequestResult
                ApprovalRequestResult
                    { arrTemplateLocation = s3Loc
                    , arrPendingLocation = pendingLoc
                    , arrAlreadyApproved = False
                    , arrNextSteps =
                        [ "Review with: iidy-hs template-approval review "
                            <> pendingLoc
                        ]
                    }
    pure 0

{- | With lint on, validate the body and emit the result; 'True' when the
validation found errors. With lint off, 'False' and no call.
-}
lintFails :: CfnContext -> Bool -> Text -> IO Bool
lintFails _ False _ = pure False
lintFails ctx True body = do
    validation <- validateTemplateBody ctx body
    cfnEmit ctx (OdTemplateValidation validation)
    pure (not (null (tvErrors validation)))

------------------------------------------------------------------------
-- Template Approval Review
------------------------------------------------------------------------

-- | Review a pending template approval.
templateApprovalReview ::
    CfnContext ->
    -- | S3 URL of pending template
    Text ->
    -- | context lines for diff
    Int ->
    IO (Either Text Int)
templateApprovalReview ctx url contextLines = do
    let emit = cfnEmit ctx
    runExceptT $ do
        -- Parse S3 URL
        (bucket, pendingKey) <- liftEitherT $ parseS3Url url

        -- Validate .pending suffix
        approvedKey <- liftEitherT (approvedKeyFromPending pendingKey)

        let latestKey = latestKeyFromPending pendingKey
            approvedLoc = "s3://" <> bucket <> "/" <> approvedKey

        -- Every call of the review is to S3, in the bucket's region
        s3 <- lift (approvalS3Env (cfnEnv ctx) bucket)
        let s3Ctx = ctx{cfnEnv = asEnv s3}

        -- Check pending exists
        pendingExists <- liftExceptT (approvalObjectExists s3 bucket pendingKey)
        unless pendingExists $
            throwE ("Pending template not found at " <> url)

        -- Check if already approved
        alreadyApproved <- liftExceptT (approvalObjectExists s3 bucket approvedKey)

        -- Emit approval status
        lift $
            emit $
                OdApprovalStatus
                    ApprovalStatus
                        { apsPendingExists = pendingExists
                        , apsAlreadyApproved = alreadyApproved
                        , apsPendingLocation = url
                        , apsApprovedLocation =
                            if alreadyApproved then Just approvedLoc else Nothing
                        }

        if alreadyApproved
            then pure 0
            else
                reviewPendingTemplate
                    s3Ctx
                    contextLines
                    bucket
                    pendingKey
                    approvedKey
                    latestKey
                    approvedLoc

-- | Inner logic for reviewing a non-yet-approved pending template.
reviewPendingTemplate ::
    CfnContext ->
    -- | context lines for diff
    Int ->
    -- | S3 bucket
    Text ->
    -- | pending object key
    Text ->
    -- | approved object key
    Text ->
    -- | latest object key
    Text ->
    -- | approved S3 location (for result output)
    Text ->
    ExceptT Text IO Int
reviewPendingTemplate ctx contextLines bucket pendingKey approvedKey latestKey approvedLoc = do
    let emit = cfnEmit ctx
    -- Download templates
    pending <-
        liftExceptT (downloadFromS3 (cfnEnv ctx) bucket pendingKey)
            `prefixError` "Failed to download pending template: "
    latest <- lift $ fromRight "" <$> downloadFromS3 (cfnEnv ctx) bucket latestKey

    -- Generate and emit diff
    let diffOutput = generateDiff contextLines latest pending
        hasChanges = not (T.null diffOutput)
    lift $
        emit $
            OdTemplateDiff
                TemplateDiff
                    { tdDiffOutput = diffOutput
                    , tdContextLines = contextLines
                    , tdHasChanges = hasChanges
                    }

    if not hasChanges
        then do
            lift $
                emit $
                    OdApprovalResult
                        ApprovalResult
                            { arApproved = True
                            , arApprovedLocation = Just approvedLoc
                            , arLatestLocation =
                                Just ("s3://" <> bucket <> "/" <> latestKey)
                            , arCleanupCompleted = False
                            }
            pure 0
        else do
            result <- lift $ requestConfirmation "Would you like to approve these changes?"
            if result == Confirmed
                then
                    approveTemplate
                        ctx
                        bucket
                        pendingKey
                        approvedKey
                        latestKey
                        approvedLoc
                        pending
                else do
                    lift $
                        emit $
                            OdApprovalResult
                                ApprovalResult
                                    { arApproved = False
                                    , arApprovedLocation = Nothing
                                    , arLatestLocation = Nothing
                                    , arCleanupCompleted = False
                                    }
                    pure 1

-- | Perform the actual S3 approval: copy pending to approved and latest, delete pending.
approveTemplate ::
    CfnContext ->
    -- | S3 bucket
    Text ->
    -- | pending object key
    Text ->
    -- | approved object key
    Text ->
    -- | latest object key
    Text ->
    -- | approved S3 location (for result output)
    Text ->
    -- | pending template body
    Text ->
    ExceptT Text IO Int
approveTemplate ctx bucket pendingKey approvedKey latestKey approvedLoc pending = do
    let emit = cfnEmit ctx
    liftExceptT (uploadToS3 (cfnEnv ctx) DefaultAcl bucket approvedKey pending)
        `prefixError` "Failed to upload approved template: "
    liftExceptT (uploadToS3 (cfnEnv ctx) DefaultAcl bucket latestKey pending)
        `prefixError` "Failed to upload latest template: "
    liftExceptT (deleteFromS3 (cfnEnv ctx) bucket pendingKey)
        `prefixError` "Failed to delete pending template: "
    lift $
        emit $
            OdApprovalResult
                ApprovalResult
                    { arApproved = True
                    , arApprovedLocation = Just approvedLoc
                    , arLatestLocation =
                        Just ("s3://" <> bucket <> "/" <> latestKey)
                    , arCleanupCompleted = True
                    }
    pure 0

------------------------------------------------------------------------
-- ExceptT helpers
------------------------------------------------------------------------

-- | Lift an IO (Either Text a) into ExceptT Text IO.
liftExceptT :: IO (Either Text a) -> ExceptT Text IO a
liftExceptT = ExceptT

-- | Lift a pure Either Text into ExceptT Text IO.
liftEitherT :: Either Text a -> ExceptT Text IO a
liftEitherT (Left e) = throwE e
liftEitherT (Right x) = pure x

-- | Lift a Maybe into ExceptT, failing with the given error on Nothing.
liftMaybe :: Text -> Maybe a -> ExceptT Text IO a
liftMaybe err Nothing = throwE err
liftMaybe _ (Just x) = pure x

-- | Prefix the error message of an ExceptT action.
prefixError :: ExceptT Text IO a -> Text -> ExceptT Text IO a
prefixError action prefix = ExceptT $ do
    result <- runExceptT action
    pure $ case result of
        Left err -> Left (prefix <> err)
        Right x -> Right x
