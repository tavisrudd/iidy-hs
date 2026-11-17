{- | Unknown-key validation for stack-args files: the valid top-level keys
and "did you mean?" suggestions for the others. Pure.
-}
module Iidy.Cfn.StackArgs.Validate (
    validTopLevelKeys,
    validateNoUnknownKeys,
    formatUnknownKey,
    findSuggestion,
) where

import Data.Aeson (Value)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.List qualified as List
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Text.EditDistance (defaultEditCosts, levenshteinDistance)

------------------------------------------------------------------------
-- Unknown key validation
------------------------------------------------------------------------

-- | Set of all valid top-level keys in stack-args YAML.
validTopLevelKeys :: Set Text
validTopLevelKeys =
    Set.fromList
        [ "StackName"
        , "Template"
        , "ApprovedTemplateLocation"
        , "Region"
        , "Profile"
        , "AssumeRoleARN"
        , "ServiceRoleARN"
        , "RoleARN"
        , "Capabilities"
        , "Tags"
        , "Parameters"
        , "NotificationARNs"
        , "TimeoutInMinutes"
        , "OnFailure"
        , "DisableRollback"
        , "EnableTerminationProtection"
        , "StackPolicy"
        , "ResourceTypes"
        , "UsePreviousTemplate"
        , "UsePreviousParameterValues"
        , "CommandsBefore"
        , "$envValues"
        ]

{- | Validate that a KeyMap contains no unknown top-level keys.
Returns Left with an error listing unknown keys (with "did you mean?" suggestions)
if any are found.
-}
validateNoUnknownKeys :: KM.KeyMap Value -> Either Text ()
validateNoUnknownKeys obj =
    let allKeys = map Key.toText (KM.keys obj)
        unknownKeys = filter (\k -> not (Set.member k validTopLevelKeys)) allKeys
     in case unknownKeys of
            [] -> Right ()
            _unknownKeys ->
                Left $
                    "Unknown keys in stack-args: "
                        <> T.intercalate ", " (map formatUnknownKey unknownKeys)

-- | Format an unknown key with an optional "did you mean?" suggestion.
formatUnknownKey :: Text -> Text
formatUnknownKey key =
    case findSuggestion key of
        Nothing -> key
        Just suggestion -> key <> " (did you mean " <> suggestion <> "?)"

{- | Find the closest valid key by edit distance.
Only suggests if distance <= min(3, len/2 + 1) and distance > 0.
Never suggests $envValues (internal key).
-}
findSuggestion :: Text -> Maybe Text
findSuggestion key =
    let keyStr = T.unpack key
        keyLen = T.length key
        maxDist = min 3 (keyLen `div` 2 + 1)
        -- Exclude $envValues from suggestions (internal key)
        suggestableKeys = Set.toList (Set.delete "$envValues" validTopLevelKeys)
        scored =
            [ (dist, candidate)
            | candidate <- suggestableKeys
            , let dist = levenshteinDistance defaultEditCosts keyStr (T.unpack candidate)
            , dist > 0
            , dist <= maxDist
            ]
     in case scored of
            [] -> Nothing
            _candidates -> Just $ snd $ List.minimumBy (\a b -> compare (fst a) (fst b)) scored
