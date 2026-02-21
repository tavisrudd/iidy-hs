module Iidy.Yaml.Errors.Enhanced
  ( EnhancedPreprocessingError(..)
  , VariableNotFoundInfo(..)
  , TypeMismatchInfo(..)
  , CfnValidationInfo(..)
  , YamlSyntaxInfo(..)
  , TagParsingInfo(..)
  , LookupQueryInfo(..)
  ) where

import Data.Text (Text)
import Iidy.Yaml.Errors.Ids (ErrorId)
import Iidy.Yaml.Location (SourceLocation)

data VariableNotFoundInfo = VariableNotFoundInfo
  { vnfErrorId       :: !ErrorId
  , vnfVariable      :: !Text
  , vnfLocation      :: !SourceLocation
  , vnfAvailableVars :: ![Text]
  , vnfSuggestions   :: ![Text]
  } deriving stock (Show, Eq)

data TypeMismatchInfo = TypeMismatchInfo
  { tmiErrorId  :: !ErrorId
  , tmiExpected :: !Text
  , tmiFound    :: !Text
  , tmiLocation :: !SourceLocation
  , tmiContext  :: !Text
  , tmiHelp     :: !(Maybe Text)
  } deriving stock (Show, Eq)

data CfnValidationInfo = CfnValidationInfo
  { cviErrorId  :: !ErrorId
  , cviTagName  :: !Text
  , cviMessage  :: !Text
  , cviLocation :: !SourceLocation
  , cviHelpText :: !Text
  } deriving stock (Show, Eq)

data YamlSyntaxInfo = YamlSyntaxInfo
  { ysiErrorId      :: !ErrorId
  , ysiShortMessage :: !Text
  , ysiGuidance     :: !Text
  , ysiLocation     :: !SourceLocation
  , ysiFixHint      :: !(Maybe Text)
  , ysiExample      :: !(Maybe Text)
  } deriving stock (Show, Eq)

data TagParsingInfo = TagParsingInfo
  { tpiErrorId     :: !ErrorId
  , tpiTagName     :: !Text
  , tpiMessage     :: !Text
  , tpiLocation    :: !SourceLocation
  , tpiSuggestion  :: !(Maybe Text)
  , tpiCaretColumn :: !Int
  , tpiSpanLen     :: !Int
  } deriving stock (Show, Eq)

data LookupQueryInfo = LookupQueryInfo
  { lqiErrorId       :: !ErrorId
  , lqiVariablePath  :: !Text
  , lqiMessage       :: !Text
  , lqiLocation      :: !SourceLocation
  , lqiAvailableKeys :: ![Text]
  } deriving stock (Show, Eq)

data EnhancedPreprocessingError
  = VariableNotFoundError !VariableNotFoundInfo
  | TypeMismatchError !TypeMismatchInfo
  | CfnValidationError !CfnValidationInfo
  | YamlSyntaxError !YamlSyntaxInfo
  | TagParsingError !TagParsingInfo
  | LookupQueryError !LookupQueryInfo
  deriving stock (Show, Eq)
