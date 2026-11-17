{- | Where an approved template lives.

The one owner of the approved object's bucket and key (derived from
@ApprovedTemplateLocation@ and the hash of the rendered local template),
the pending key a request uploads to, and the approved and @latest@ keys a
review derives from that pending key, and of the approval bucket's region.
Template approval request and review use it, and the deploy builders get
their template from 'resolveDeployTemplate'; no other code builds or strips
these keys or picks that region.
-}
module Iidy.Cfn.ApprovedTemplate (
    ApprovedTemplate (..),
    approvedTemplateFor,
    pendingKeyFor,
    approvedKeyFromPending,
    latestKeyFromPending,
    generateVersionedLocation,
    approvalS3Env,
    resolveDeployTemplate,
) where

import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import System.FilePath (takeExtension)

import Amazonka qualified

import Iidy.Aws.CredentialSource (CredentialSource (..), CredentialSourceStack (..), ProfileInfo (..), ProfileSource (..))
import Iidy.Cfn.Context (CfnContext (..), cfnImportConfig)
import Iidy.Cfn.S3Objects (bucketRegion, presignGetObject, s3ObjectExists)
import Iidy.Cfn.TemplateHash (calculateTemplateHash, parseS3Url)
import Iidy.Cfn.TemplateLoader (TemplateResult (..), approvalTemplateLimit, isTemplateUrl, loadCfnTemplate, loadCfnTemplateWithLimit)
import Iidy.Cfn.Types (StackArgs (..))

-- | The approved object for a template, and the rendered body it hashes.
data ApprovedTemplate = ApprovedTemplate
    { atBucket :: !Text
    , atKey :: !Text
    -- ^ the approved object's key
    , atBody :: !Text
    -- ^ the rendered local template
    }
    deriving stock (Show, Eq)

{- | The approved object for the stack args' template: 'Nothing' when
@ApprovedTemplateLocation@ is unset. With it set, a @Template@ that is a
URL or is missing is refused before anything is loaded; otherwise the
template is rendered, up to the approval-path size limit, and the key built
from its hash.
-}
approvedTemplateFor ::
    CfnContext ->
    StackArgs ->
    -- | argsfile, for resolving the template path
    Maybe FilePath ->
    IO (Either Text (Maybe ApprovedTemplate))
approvedTemplateFor ctx sa argsfilePath = case saApprovedTemplateLocation sa of
    Nothing -> pure (Right Nothing)
    Just baseLocation -> case saTemplate sa of
        Nothing ->
            pure
                ( Left
                    ( "Template is required in stack-args.yaml when ApprovedTemplateLocation is set: "
                        <> hashesLocalTemplate
                    )
                )
        Just spec
            | isTemplateUrl spec ->
                pure
                    ( Left
                        ( "Template must be a local file when ApprovedTemplateLocation is set, not a URL ("
                            <> spec
                            <> "): "
                            <> hashesLocalTemplate
                        )
                    )
            | otherwise -> do
                loaded <-
                    loadCfnTemplateWithLimit
                        approvalTemplateLimit
                        (Just spec)
                        argsfilePath
                        (cfnEnvironment ctx)
                        (cfnImportConfig ctx)
                pure $ do
                    tmpl <- loaded
                    body <- maybe (Left "Failed to load template body") Right (trTemplateBody tmpl)
                    (bucket, key) <- generateVersionedLocation baseLocation body spec
                    Right (Just (ApprovedTemplate bucket key body))
  where
    hashesLocalTemplate = "template approval hashes the rendered local template"

{- | Generate a versioned S3 location for a template.
Returns (bucket, versioned_key) where key = basePath/hash.extension, or
hash.extension when the base location names only the bucket
(@s3://bucket@ or @s3://bucket/@), as iidy-js (@path.join@).
-}
generateVersionedLocation ::
    -- | base S3 location (e.g., s3://bucket/templates/)
    Text ->
    -- | template content (for hashing)
    Text ->
    -- | template file path (for extension)
    Text ->
    Either Text (Text, Text)
generateVersionedLocation baseLocation content templatePath = do
    -- A bucket-only location has no key for parseS3Url; give it an empty one.
    let withKey =
            if T.any (== '/') (T.drop 5 baseLocation)
                then baseLocation
                else baseLocation <> "/"
    (bucket, baseKey) <- parseS3Url withKey
    let hash = calculateTemplateHash content
        ext = T.pack (takeExtension (T.unpack templatePath))
        -- Ensure trailing slash is handled
        basePath =
            if T.isSuffixOf "/" baseKey
                then T.dropEnd 1 baseKey
                else baseKey
        fileName = hash <> ext
        versionedKey =
            if T.null basePath
                then fileName
                else basePath <> "/" <> fileName
    Right (bucket, versionedKey)

{- | The env for the approval bucket's S3 calls: the given env with its
region set to the bucket's own region. That region comes from
@GetBucketLocation@, asked of us-east-1 (which answers for any bucket);
when that call fails (for example without @s3:GetBucketLocation@), the
given env's region (the stack's) is kept.
-}
approvalS3Env :: Amazonka.Env -> Text -> IO Amazonka.Env
approvalS3Env env bucket = do
    located <- bucketRegion env{Amazonka.region = Amazonka.NorthVirginia} bucket
    pure $ case located of
        Right region -> env{Amazonka.region = region}
        Left _ -> env

{- | The template a deploy request (create-stack, update-stack,
create-changeset) sends. With no @ApprovedTemplateLocation@ it is the local
template as loaded today. With one, the approved object must exist: the
result is a presigned URL for it (signed for the bucket's region) and no
body; otherwise a refusal, before any CloudFormation call. Not approved
(404) suggests the @template-approval request@ command with this deploy's
region, environment and profile, as iidy-js
(@AbstractCloudFormationStackCommand.ts:218-230@).
-}
resolveDeployTemplate :: CfnContext -> StackArgs -> Maybe FilePath -> IO (Either Text TemplateResult)
resolveDeployTemplate ctx sa argsfilePath = do
    approved <- approvedTemplateFor ctx sa argsfilePath
    case approved of
        Left err -> pure (Left err)
        Right Nothing ->
            loadCfnTemplate (saTemplate sa) argsfilePath (cfnEnvironment ctx) (cfnImportConfig ctx)
        Right (Just (ApprovedTemplate bucket key _body)) -> do
            s3Env <- approvalS3Env (cfnEnv ctx) bucket
            exists <- s3ObjectExists s3Env bucket key
            case exists of
                Left err -> pure (Left err)
                Right False -> pure (Left (notApprovedMessage ctx argsfilePath))
                Right True -> do
                    now <- getCurrentTime
                    url <- presignGetObject s3Env now bucket key
                    pure (Right (TemplateResult Nothing (Just url)))

{- | The refusal for a template with no approved object. The suggested
command puts the global options first, where the CLI parser takes them.
-}
notApprovedMessage :: CfnContext -> Maybe FilePath -> Text
notApprovedMessage ctx argsfilePath =
    "Template version has not been approved or the current IAM principal does not have permission to access it. Run:\n"
        <> "  iidy-hs --region "
        <> Amazonka.fromRegion (Amazonka.region (cfnEnv ctx))
        <> " --environment "
        <> cfnEnvironment ctx
        <> maybe "" (" --profile " <>) (namedProfile (cfnCredentialSources ctx))
        <> " template-approval request "
        <> maybe "<argsfile>" T.pack argsfilePath
        <> "\nto begin the approval process."

-- | The profile named by @--profile@ or stack-args, if credentials use one.
namedProfile :: CredentialSourceStack -> Maybe Text
namedProfile (CredentialSourceStack sources) =
    listToMaybe
        [ piName info
        | ProfileCredential info <- sources
        , piSource info `elem` [ProfileCliFlag, ProfileStackArgs]
        ]

-- | Suffix of a pending object's key.
pendingSuffix :: Text
pendingSuffix = ".pending"

-- | The key a request uploads the pending template to.
pendingKeyFor :: Text -> Text
pendingKeyFor approvedKey = approvedKey <> pendingSuffix

-- | The approved key for a pending key; fails without the pending suffix.
approvedKeyFromPending :: Text -> Either Text Text
approvedKeyFromPending pendingKey =
    maybe
        (Left "URL must end with .pending suffix")
        Right
        (T.stripSuffix pendingSuffix pendingKey)

{- | The @latest@ key beside a pending key: @latest@ in the pending
object's directory (iidy-js @${bucketDir}/latest@).
-}
latestKeyFromPending :: Text -> Text
latestKeyFromPending pendingKey
    | T.null parentDir = "latest"
    | otherwise = parentDir <> "/latest"
  where
    parentDir = case T.breakOnEnd "/" pendingKey of
        ("", _) -> ""
        (dir, _) -> T.dropEnd 1 dir
