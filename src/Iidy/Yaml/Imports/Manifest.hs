module Iidy.Yaml.Imports.Manifest (
    ImportManifest,
    emptyManifest,
    addRecord,
    getRecords,
    ImportStack,
    emptyStack,
    pushImport,
    popImport,
) where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Iidy.Yaml.Imports.Types (ImportRecord)

------------------------------------------------------------------------
-- Import manifest (tracks all imports for auditing)
------------------------------------------------------------------------

newtype ImportManifest = ImportManifest [ImportRecord]
    deriving stock (Show)

emptyManifest :: ImportManifest
emptyManifest = ImportManifest []

addRecord :: ImportRecord -> ImportManifest -> ImportManifest
addRecord r (ImportManifest rs) = ImportManifest (r : rs)

getRecords :: ImportManifest -> [ImportRecord]
getRecords (ImportManifest rs) = reverse rs

------------------------------------------------------------------------
-- Import stack (cycle detection)
------------------------------------------------------------------------

data ImportStack = ImportStack
    { isActive :: !(Set Text)
    , isChain :: ![Text]
    }
    deriving stock (Show)

emptyStack :: ImportStack
emptyStack = ImportStack Set.empty []

pushImport :: Text -> ImportStack -> Either Text ImportStack
pushImport loc stack
    | Set.member loc (isActive stack) =
        Left $
            "Circular import detected: "
                <> T.intercalate " → " (reverse (loc : isChain stack))
    | otherwise =
        Right $
            ImportStack
                { isActive = Set.insert loc (isActive stack)
                , isChain = loc : isChain stack
                }

popImport :: ImportStack -> ImportStack
popImport stack = case isChain stack of
    [] -> stack
    (loc : rest) ->
        ImportStack
            { isActive = Set.delete loc (isActive stack)
            , isChain = rest
            }
