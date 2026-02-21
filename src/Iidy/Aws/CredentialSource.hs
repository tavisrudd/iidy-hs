module Iidy.Aws.CredentialSource
  ( CredentialSource(..)
  , ProfileInfo(..)
  , AssumeRoleInfo(..)
  , ProfileSource(..)
  , AssumeRoleSource(..)
  , CredentialSourceStack(..)
  , CredentialDetectionContext(..)
  , AwsSettings(..)
  ) where

import Data.Text (Text)

data ProfileSource
  = ProfileCliFlag
  | ProfileStackArgs
  | ProfileAwsProfileEnvVar
  | ProfileDefault
  deriving stock (Show, Eq)

data AssumeRoleSource
  = AssumeRoleCliFlag
  | AssumeRoleStackArgs
  deriving stock (Show, Eq)

data ProfileInfo = ProfileInfo
  { piName           :: !Text
  , piSource         :: !ProfileSource
  , piProfileRoleArn :: !(Maybe Text)
  } deriving stock (Show, Eq)

data AssumeRoleInfo = AssumeRoleInfo
  { ariBaseSource :: !CredentialSource
  , ariRoleArn    :: !Text
  , ariSource     :: !AssumeRoleSource
  } deriving stock (Show, Eq)

data CredentialSource
  = EnvironmentVariablesStatic
  | EnvironmentVariablesTemporary
  | ProfileCredential !ProfileInfo
  | AssumeRoleCredential !AssumeRoleInfo
  | ContainerCredentialsEcs
  | ContainerCredentialsGeneric
  | WebIdentityToken
  | InstanceMetadata
  | UnknownCredentialSource
  deriving stock (Show, Eq)

-- | Stack of credential sources, [0] = active (highest precedence)
newtype CredentialSourceStack = CredentialSourceStack
  { cssSources :: [CredentialSource]
  } deriving stock (Show, Eq)

data CredentialDetectionContext = CredentialDetectionContext
  { cdcCliProfile              :: !(Maybe Text)
  , cdcStackArgsProfile        :: !(Maybe Text)
  , cdcCliAssumeRoleArn        :: !(Maybe Text)
  , cdcStackArgsAssumeRoleArn  :: !(Maybe Text)
  } deriving stock (Show, Eq)

data AwsSettings = AwsSettings
  { awsProfile       :: !(Maybe Text)
  , awsRegion        :: !(Maybe Text)
  , awsAssumeRoleArn :: !(Maybe Text)
  } deriving stock (Show, Eq)
