{- | Where an approved template lives.

The one owner of the approved object's bucket and key (derived from
@ApprovedTemplateLocation@ and the hash of the rendered local template),
the pending key a request uploads to, and the approved and @latest@ keys a
review derives from that pending key. Template approval request and review use
it; no other code builds or strips these keys.
-}
module Iidy.Cfn.ApprovedTemplate (
    ApprovedTemplate (..),
    approvedTemplateFor,
    pendingKeyFor,
    approvedKeyFromPending,
    latestKeyFromPending,
) where

import Data.Text (Text)
import Data.Text qualified as T

import Iidy.Cfn.Context (CfnContext (..))
import Iidy.Cfn.TemplateHash (generateVersionedLocation)
import Iidy.Cfn.TemplateLoader (TemplateResult (..), isTemplateUrl, loadCfnTemplate)
import Iidy.Cfn.Types (StackArgs (..))
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig (..))

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
template is rendered and the key built from its hash.
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
                    loadCfnTemplate
                        (Just spec)
                        argsfilePath
                        (cfnEnvironment ctx)
                        (ImportConfig (Just (cfnEnv ctx)) (cfnRemoteImports ctx))
                pure $ do
                    tmpl <- loaded
                    body <- maybe (Left "Failed to load template body") Right (trTemplateBody tmpl)
                    (bucket, key) <- generateVersionedLocation baseLocation body spec
                    Right (Just (ApprovedTemplate bucket key body))
  where
    hashesLocalTemplate = "template approval hashes the rendered local template"

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
