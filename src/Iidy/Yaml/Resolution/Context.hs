module Iidy.Yaml.Resolution.Context
  ( TagContext(..)
  , emptyContext
  , withBindings
  , withVariable
  , withInputUri
  , getVariable
  , contextVariableNames
  , VariableSource(..)
  , isTruthy
  , valuesEqual
  ) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.KeyMap as KM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Vector as V

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
  { tcVariables          :: !(Map Text Value)
  , tcInputUri           :: !(Maybe Text)
  , tcCustomTemplateDefs :: !(Map Text Value)
  } deriving stock (Show, Eq)

emptyContext :: TagContext
emptyContext = TagContext
  { tcVariables          = Map.empty
  , tcInputUri           = Nothing
  , tcCustomTemplateDefs = Map.empty
  }

withBindings :: Map Text Value -> TagContext -> TagContext
withBindings bindings ctx = ctx
  { tcVariables = Map.union bindings (tcVariables ctx) }

withVariable :: Text -> Value -> TagContext -> TagContext
withVariable name val ctx = ctx
  { tcVariables = Map.insert name val (tcVariables ctx) }

withInputUri :: Text -> TagContext -> TagContext
withInputUri uri ctx = ctx { tcInputUri = Just uri }

getVariable :: Text -> TagContext -> Maybe Value
getVariable name = Map.lookup name . tcVariables

contextVariableNames :: TagContext -> [Text]
contextVariableNames = Map.keys . tcVariables

------------------------------------------------------------------------
-- Value predicates
------------------------------------------------------------------------

isTruthy :: Value -> Bool
isTruthy = \case
  Null       -> False
  Bool b     -> b
  String s   -> s /= ""
  Number _   -> True
  Array a    -> not (V.null a)
  Object o   -> not (KM.null o)

valuesEqual :: Value -> Value -> Bool
valuesEqual (Number a) (Number b) = a == b
valuesEqual a b = a == b
