module Iidy.Yaml.Resolution.Context
  ( TagContext(..)
  , TemplateInfo(..)
  , ParamDef(..)
  , emptyContext
  , withBindings
  , withVariable
  , withInputUri
  , getVariable
  , contextVariableNames
  , VariableSource(..)
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Iidy.Yaml.CustomResources.Params (TemplateInfo(..), ParamDef(..))
import Iidy.Yaml.OValue (OValue)

-- | Source of a variable binding (for error reporting)
data VariableSource
  = SourceLocalDefs
  | SourceImportedDocument !Text
  | SourceTagBinding !Text
  | SourceBuiltIn
  | SourceExternal
  deriving stock (Show, Eq)

-- | Context threaded through tag resolution
data TagContext = TagContext
  { tcVariables          :: !(Map Text OValue)
  , tcInputUri           :: !(Maybe Text)
  , tcCustomTemplateDefs :: !(Map Text TemplateInfo)
  } deriving stock (Show, Eq)

emptyContext :: TagContext
emptyContext = TagContext
  { tcVariables          = Map.empty
  , tcInputUri           = Nothing
  , tcCustomTemplateDefs = Map.empty
  }

withBindings :: Map Text OValue -> TagContext -> TagContext
withBindings bindings ctx = ctx
  { tcVariables = Map.union bindings (tcVariables ctx) }

withVariable :: Text -> OValue -> TagContext -> TagContext
withVariable name val ctx = ctx
  { tcVariables = Map.insert name val (tcVariables ctx) }

withInputUri :: Text -> TagContext -> TagContext
withInputUri uri ctx = ctx { tcInputUri = Just uri }

getVariable :: Text -> TagContext -> Maybe OValue
getVariable name = Map.lookup name . tcVariables

contextVariableNames :: TagContext -> [Text]
contextVariableNames = Map.keys . tcVariables
