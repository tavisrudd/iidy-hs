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
  , generateDiff
  ) where

import Control.Exception (try)
import Control.Monad.Trans.Resource (runResourceT)
import qualified Data.Array as Array
import qualified Data.ByteString as BS
import qualified Data.List as List
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

import Iidy.Confirm (ConfirmResult(..), requestConfirmation)
import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Cfn.TemplateHash (generateVersionedLocation, parseS3Url)
import Iidy.Cfn.TemplateLoader (loadCfnTemplate, TemplateResult(..))
import Iidy.Cfn.Types (StackArgs(..))
import Iidy.Output.Types
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig(..))
import Iidy.Yaml.Imports.Types (RemoteImports(..))

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
  -> RemoteImports  -- ^ whether HTTP/S3 imports are allowed
  -> IO (Either Text Int)
templateApprovalRequest ctx sa _lintTmpl argsfilePath env emit remoteImports = do
  -- Validate required fields
  case saApprovedTemplateLocation sa of
    Nothing -> pure (Left "ApprovedTemplateLocation is required in stack-args.yaml")
    Just baseLocation -> do
      case saTemplate sa of
        Nothing -> pure (Left "Template is required in stack-args.yaml")
        Just _tmplSpec -> do
          -- Load template
          tmplEither <- loadCfnTemplate (saTemplate sa) argsfilePath env (ImportConfig (Just (cfnEnv ctx)) remoteImports)
          case tmplEither of
            Left err -> pure (Left err)
            Right tmplResult -> case trTemplateBody tmplResult of
              Nothing -> pure (Left "Failed to load template body")
              Just body -> do
                -- Generate versioned location
                let tmplPath = maybe "template.yaml" T.unpack (saTemplate sa)
                case generateVersionedLocation baseLocation body (T.pack tmplPath) of
                  Left err' -> pure (Left err')
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
                          Left uploadErr -> pure (Left ("Failed to upload pending template: " <> uploadErr))
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
                      let diffOutput = generateDiff contextLines latest pending
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
                          result <- requestConfirmation "Would you like to approve these changes?"
                          if result == Confirmed
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
  result <- try @Amazonka.Error $ runResourceT $ Amazonka.send awsEnv req
  case result of
    Right _ -> pure True
    Left _  -> pure False

-- | Upload content to S3.
uploadToS3 :: Amazonka.Env -> Text -> Text -> Text -> IO (Either Text ())
uploadToS3 awsEnv bucket key content = do
  let body = Amazonka.toBody (TE.encodeUtf8 content)
      req = PO.newPutObject (S3.BucketName bucket) (S3.ObjectKey key) body
  result <- try @Amazonka.Error $ runResourceT $ Amazonka.send awsEnv req
  case result of
    Left ex  -> pure (Left (T.pack (show ex)))
    Right _  -> pure (Right ())

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
      Left ex  -> pure (Left (T.pack (show ex)))
      Right t  -> pure (Right t)

-- | Delete an S3 object.
deleteFromS3 :: Amazonka.Env -> Text -> Text -> IO (Either Text ())
deleteFromS3 awsEnv bucket key = do
  let req = DO.newDeleteObject (S3.BucketName bucket) (S3.ObjectKey key)
  result <- try @Amazonka.Error $ runResourceT $ Amazonka.send awsEnv req
  case result of
    Left ex  -> pure (Left (T.pack (show ex)))
    Right _  -> pure (Right ())

------------------------------------------------------------------------
-- Diff generation (LCS-based)
------------------------------------------------------------------------

-- | A single diff operation.
data DiffOp
  = Equal  !Text   -- ^ Line present in both old and new
  | Delete !Text   -- ^ Line removed from old
  | Insert !Text   -- ^ Line added in new

-- | Generate a unified-style line diff between old and new content.
-- Shows @contextLines@ lines of context around each change group.
-- Non-adjacent hunks are separated by @---@.
-- Returns empty text when the inputs are identical.
generateDiff :: Int -> Text -> Text -> Text
generateDiff contextLines old new
  | old == new = ""
  | otherwise =
      let oldLns = T.lines old
          newLns = T.lines new
          ops    = lcsOps oldLns newLns
          hunks  = buildHunks contextLines ops
      in formatHunks hunks

-- | Compute the LCS table via dynamic programming, then backtrack to
-- produce a list of 'DiffOp' values that transform old into new.
lcsOps :: [Text] -> [Text] -> [DiffOp]
lcsOps oldLns newLns =
  let m = length oldLns
      n = length newLns
      oldArr = Array.listArray (0, m - 1) oldLns
      newArr = Array.listArray (0, n - 1) newLns
      -- dp ! (i, j) = LCS length for oldLns[i..] vs newLns[j..]
      dp :: Array.Array (Int, Int) Int
      dp = Array.array ((0, 0), (m, n))
        [ ((i, j), val i j)
        | i <- [0..m]
        , j <- [0..n]
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

-- | Build hunks from a flat list of diff ops, using @ctx@ lines of
-- context around each change.
buildHunks :: Int -> [DiffOp] -> [Hunk]
buildHunks ctx ops =
  let indexed = zip [0 :: Int ..] ops
      -- Indices of non-Equal ops
      changeIdxs = [ i | (i, op) <- indexed, isChange op ]
  in case changeIdxs of
       [] -> []  -- no changes
       _  ->
         let -- Expand each change index into a range [lo..hi] with context
             ranges = map (\i -> (max 0 (i - ctx), min (totalLen - 1) (i + ctx)))
                          changeIdxs
             -- Merge overlapping/adjacent ranges
             merged = mergeRanges ranges
             -- Extract hunks from merged ranges
         in map (extractHunk indexed) merged
  where
    totalLen :: Int
    totalLen = length ops

    isChange :: DiffOp -> Bool
    isChange (Equal _) = False
    isChange _         = True

    mergeRanges :: [(Int, Int)] -> [(Int, Int)]
    mergeRanges [] = []
    mergeRanges (r:rs) = List.foldl' merge1 [r] rs

    merge1 :: [(Int, Int)] -> (Int, Int) -> [(Int, Int)]
    merge1 [] r = [r]
    merge1 acc (lo, hi) =
      let (prevLo, prevHi) = last acc
      in if lo <= prevHi + 1
         then init acc ++ [(prevLo, max prevHi hi)]
         else acc ++ [(lo, hi)]

    extractHunk :: [(Int, DiffOp)] -> (Int, Int) -> Hunk
    extractHunk indexed (lo, hi) =
      [ op | (i, op) <- indexed, i >= lo, i <= hi ]

-- | Format hunks into the final text output. Non-adjacent hunks are
-- separated by a @---@ line.
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
formatOp (Equal  l) = "  " <> l
formatOp (Delete l) = "- " <> l
formatOp (Insert l) = "+ " <> l

