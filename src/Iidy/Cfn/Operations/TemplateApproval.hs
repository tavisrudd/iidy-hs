{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Template approval request and review workflows.

The request flow uploads a pending template to S3.
The review flow downloads, diffs, and optionally approves a pending template.
-}
module Iidy.Cfn.Operations.TemplateApproval (
    templateApprovalRequest,
    templateApprovalReview,
    generateDiff,
) where

import Control.Exception (try)
import Control.Monad (unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Array qualified as Array
import Data.ByteString qualified as BS
import Data.Either (fromRight)
import Data.List qualified as List
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

import Iidy.Cfn.Context (CfnContext (..))
import Iidy.Cfn.TemplateHash (generateVersionedLocation, parseS3Url)
import Iidy.Cfn.TemplateLoader (TemplateResult (..), loadCfnTemplate)
import Iidy.Cfn.Types (StackArgs (..))
import Iidy.Confirm (ConfirmResult (..), requestConfirmation)
import Iidy.Output.Types
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig (..))
import Iidy.Yaml.Imports.Types (RemoteImports (..))

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
    -- | environment
    Text ->
    -- | emit callback
    (OutputData -> IO ()) ->
    -- | whether HTTP/S3 imports are allowed
    RemoteImports ->
    IO (Either Text Int)
templateApprovalRequest ctx sa _lintTmpl argsfilePath env emit remoteImports =
    runExceptT $ do
        -- Validate required fields
        baseLocation <-
            liftMaybe
                "ApprovedTemplateLocation is required in stack-args.yaml"
                (saApprovedTemplateLocation sa)
        _tmplSpec <-
            liftMaybe
                "Template is required in stack-args.yaml"
                (saTemplate sa)

        -- Load template
        tmplResult <-
            liftExceptT $
                loadCfnTemplate
                    (saTemplate sa)
                    argsfilePath
                    env
                    (ImportConfig (Just (cfnEnv ctx)) remoteImports)
        body <- liftMaybe "Failed to load template body" (trTemplateBody tmplResult)

        -- Generate versioned location
        let tmplPath = maybe "template.yaml" T.unpack (saTemplate sa)
        (bucket, key) <-
            liftEitherT $
                generateVersionedLocation baseLocation body (T.pack tmplPath)

        let s3Loc = "s3://" <> bucket <> "/" <> key

        -- Check if already approved
        alreadyApproved <- lift $ s3ObjectExists (cfnEnv ctx) bucket key
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
                -- Upload pending template
                let pendingKey = key <> ".pending"
                    pendingLoc = "s3://" <> bucket <> "/" <> pendingKey
                liftExceptT (uploadToS3 (cfnEnv ctx) bucket pendingKey body)
                    `prefixError` "Failed to upload pending template: "
                lift $
                    emit $
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
    -- | emit callback
    (OutputData -> IO ()) ->
    IO (Either Text Int)
templateApprovalReview ctx url contextLines emit =
    runExceptT $ do
        -- Parse S3 URL
        (bucket, pendingKey) <- liftEitherT $ parseS3Url url

        -- Validate .pending suffix
        unless (T.isSuffixOf ".pending" pendingKey) $
            throwE "URL must end with .pending suffix"

        let approvedKey = T.dropEnd 8 pendingKey -- remove ".pending"
            parentDir = case T.breakOnEnd "/" pendingKey of
                ("", _) -> ""
                (dir, _) -> T.dropEnd 1 dir
            latestKey =
                if T.null parentDir
                    then "latest"
                    else parentDir <> "/latest"
            approvedLoc = "s3://" <> bucket <> "/" <> approvedKey

        -- Check pending exists
        pendingExists <- lift $ s3ObjectExists (cfnEnv ctx) bucket pendingKey
        unless pendingExists $
            throwE ("Pending template not found at " <> url)

        -- Check if already approved
        alreadyApproved <- lift $ s3ObjectExists (cfnEnv ctx) bucket approvedKey

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
                    ctx
                    emit
                    contextLines
                    bucket
                    pendingKey
                    approvedKey
                    latestKey
                    approvedLoc

-- | Inner logic for reviewing a non-yet-approved pending template.
reviewPendingTemplate ::
    CfnContext ->
    (OutputData -> IO ()) ->
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
reviewPendingTemplate ctx emit contextLines bucket pendingKey approvedKey latestKey approvedLoc = do
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
                        emit
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
    (OutputData -> IO ()) ->
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
approveTemplate ctx emit bucket pendingKey approvedKey latestKey approvedLoc pending = do
    liftExceptT (uploadToS3 (cfnEnv ctx) bucket approvedKey pending)
        `prefixError` "Failed to upload approved template: "
    liftExceptT (uploadToS3 (cfnEnv ctx) bucket latestKey pending)
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

------------------------------------------------------------------------
-- S3 helpers
------------------------------------------------------------------------

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

------------------------------------------------------------------------
-- Diff generation (LCS-based)
------------------------------------------------------------------------

-- | A single diff operation.
data DiffOp
    = -- | Line present in both old and new
      Equal !Text
    | -- | Line removed from old
      Delete !Text
    | -- | Line added in new
      Insert !Text

{- | Generate a unified-style line diff between old and new content.
Shows @contextLines@ lines of context around each change group.
Non-adjacent hunks are separated by @---@.
Returns empty text when the inputs are identical.
-}
generateDiff :: Int -> Text -> Text -> Text
generateDiff contextLines old new
    | old == new = ""
    | otherwise =
        let oldLns = T.lines old
            newLns = T.lines new
            ops = lcsOps oldLns newLns
            hunks = buildHunks contextLines ops
         in formatHunks hunks

{- | Compute the LCS table via dynamic programming, then backtrack to
produce a list of 'DiffOp' values that transform old into new.
-}
lcsOps :: [Text] -> [Text] -> [DiffOp]
lcsOps oldLns newLns =
    let m = length oldLns
        n = length newLns
        oldArr = Array.listArray (0, m - 1) oldLns
        newArr = Array.listArray (0, n - 1) newLns
        -- dp ! (i, j) = LCS length for oldLns[i..] vs newLns[j..]
        dp :: Array.Array (Int, Int) Int
        dp =
            Array.array
                ((0, 0), (m, n))
                [ ((i, j), val i j)
                | i <- [0 .. m]
                , j <- [0 .. n]
                ]
        val :: Int -> Int -> Int
        val i j
            | i == m || j == n = 0
            | oldArr Array.! i == newArr Array.! j = 1 + dp Array.! (i + 1, j + 1)
            | otherwise = max (dp Array.! (i + 1, j)) (dp Array.! (i, j + 1))
        -- Backtrack to produce diff ops
        backtrack :: Int -> Int -> [DiffOp]
        backtrack i j
            | i == m && j == n = []
            | i == m = Insert (newArr Array.! j) : backtrack i (j + 1)
            | j == n = Delete (oldArr Array.! i) : backtrack (i + 1) j
            | oldArr Array.! i == newArr Array.! j =
                Equal (oldArr Array.! i) : backtrack (i + 1) (j + 1)
            | dp Array.! (i + 1, j) >= dp Array.! (i, j + 1) =
                Delete (oldArr Array.! i) : backtrack (i + 1) j
            | otherwise =
                Insert (newArr Array.! j) : backtrack i (j + 1)
     in backtrack 0 0

-- | A hunk is a contiguous group of diff lines to display.
type Hunk = [DiffOp]

{- | Build hunks from a flat list of diff ops, using @ctx@ lines of
context around each change.
-}
buildHunks :: Int -> [DiffOp] -> [Hunk]
buildHunks ctx ops =
    let indexed = zip [0 :: Int ..] ops
        -- Indices of non-Equal ops
        changeIdxs = [i | (i, op) <- indexed, isChange op]
     in case changeIdxs of
            [] -> [] -- no changes
            _ ->
                let
                    -- Expand each change index into a range [lo..hi] with context
                    ranges =
                        map
                            (\i -> (max 0 (i - ctx), min (totalLen - 1) (i + ctx)))
                            changeIdxs
                    -- Merge overlapping/adjacent ranges
                    merged = mergeRanges ranges
                 in
                    -- Extract hunks from merged ranges
                    map (extractHunk indexed) merged
  where
    totalLen :: Int
    totalLen = length ops

    isChange :: DiffOp -> Bool
    isChange (Equal _) = False
    isChange _ = True

    mergeRanges :: [(Int, Int)] -> [(Int, Int)]
    mergeRanges [] = []
    mergeRanges (r : rs) = List.foldl' merge1 [r] rs

    merge1 :: [(Int, Int)] -> (Int, Int) -> [(Int, Int)]
    merge1 [] r = [r]
    merge1 acc (lo, hi) =
        let (prevLo, prevHi) = last acc
         in if lo <= prevHi + 1
                then init acc ++ [(prevLo, max prevHi hi)]
                else acc ++ [(lo, hi)]

    extractHunk :: [(Int, DiffOp)] -> (Int, Int) -> Hunk
    extractHunk indexed (lo, hi) =
        [op | (i, op) <- indexed, i >= lo, i <= hi]

{- | Format hunks into the final text output. Non-adjacent hunks are
separated by a @---@ line.
-}
formatHunks :: [Hunk] -> Text
formatHunks [] = ""
formatHunks hunks =
    let formatted = map formatHunk hunks
     in T.intercalate "\n---\n" formatted

-- | Format a single hunk.
formatHunk :: Hunk -> Text
formatHunk ops = T.intercalate "\n" (map formatOp ops)

-- | Format a single diff operation.
formatOp :: DiffOp -> Text
formatOp (Equal l) = "  " <> l
formatOp (Delete l) = "- " <> l
formatOp (Insert l) = "+ " <> l
