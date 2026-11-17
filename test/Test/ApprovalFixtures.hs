{- | Shared fixtures for the template-approval tests: a local template, stack
args that turn approval on for it, its keys in the @approvals@ bucket, and
canned CloudFormation replies.
-}
module Test.ApprovalFixtures (
    simpleTemplate,
    approvalArgs,
    simpleApprovedKey,
    simplePendingKey,
    simpleRootKey,
    validationError,
) where

import Data.ByteString (ByteString)
import Data.Text (Text)

import Iidy.Cfn.Types (StackArgs (..), emptyStackArgs)

-- | A local template fixture.
simpleTemplate :: Text
simpleTemplate = "test-fixtures/template-loader/simple.yaml"

-- | Stack args with approval on (@s3://approvals/app@) and this Template.
approvalArgs :: Maybe Text -> StackArgs
approvalArgs template =
    emptyStackArgs
        { saTemplate = template
        , saApprovedTemplateLocation = Just "s3://approvals/app"
        }

-- | SHA256 of the 'simpleTemplate' file, with its extension.
simpleHashedName :: Text
simpleHashedName = "4e4e06e485ce06aabba82ff4af435f0e58425b8ea1ecdfee2f52709ea663c4fa.yaml"

-- | The fixture's approved key under @s3://approvals/app@.
simpleApprovedKey :: Text
simpleApprovedKey = "app/" <> simpleHashedName

-- | The fixture's pending key under @s3://approvals/app@.
simplePendingKey :: Text
simplePendingKey = simpleApprovedKey <> ".pending"

-- | The fixture's approved key at the bucket root.
simpleRootKey :: Text
simpleRootKey = simpleHashedName

-- | A CloudFormation query-protocol @ValidationError@ reply body.
validationError :: ByteString
validationError =
    "<ErrorResponse><Error><Type>Sender</Type><Code>ValidationError</Code>"
        <> "<Message>Template format error</Message></Error></ErrorResponse>"
