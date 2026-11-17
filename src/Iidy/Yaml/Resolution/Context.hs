module Iidy.Yaml.Resolution.Context (
    TagContext (..),
    TemplateInfo (..),
    ParamDef (..),
    emptyContext,
    withBindings,
    templateVariables,
    withVariable,
    getVariable,
    contextVariableNames,
) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Iidy.Yaml.CustomResources.Params (ParamDef (..), TemplateInfo (..))
import Iidy.Yaml.OValue (OValue)

-- | Context threaded through tag resolution
data TagContext = TagContext
    { tcVariables :: !(Map Text OValue)
    , tcInputUri :: !(Maybe Text)
    , tcCustomTemplateDefs :: !(Map Text TemplateInfo)
    , tcActiveExpansions :: !(Set Text)
    }
    deriving stock (Show, Eq)

emptyContext :: TagContext
emptyContext =
    TagContext
        { tcVariables = Map.empty
        , tcInputUri = Nothing
        , tcCustomTemplateDefs = Map.empty
        , tcActiveExpansions = Set.empty
        }

withBindings :: Map Text OValue -> TagContext -> TagContext
withBindings bindings ctx =
    ctx
        { tcVariables = Map.union bindings (tcVariables ctx)
        }

{- | The variables a custom template body resolves with: its parameters,
over the caller's variables only when the template inherits them
('tiInheritsParentVars'). Used by resource-type expansion and @!$expand@.
-}
templateVariables :: TemplateInfo -> Map Text OValue -> TagContext -> Map Text OValue
templateVariables tmpl params ctx
    | tiInheritsParentVars tmpl = Map.union params (tcVariables ctx)
    | otherwise = params

withVariable :: Text -> OValue -> TagContext -> TagContext
withVariable name val ctx =
    ctx
        { tcVariables = Map.insert name val (tcVariables ctx)
        }

getVariable :: Text -> TagContext -> Maybe OValue
getVariable name = Map.lookup name . tcVariables

contextVariableNames :: TagContext -> [Text]
contextVariableNames = Map.keys . tcVariables
