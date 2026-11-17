module Iidy.Yaml.Imports.Manifest (
    ImportManifest,
    emptyManifest,
    addRecord,
    getRecords,
    ImportStack,
    emptyStack,
    pushImport,
    PushError (..),
    popImport,
) where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Iidy.Constants (importMaxDepth, importMaxTotal)
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
    , isTotal :: !Int
    -- ^ imports pushed so far in this run (the root document excluded)
    }
    deriving stock (Show)

-- | Why an import cannot be entered.
data PushError
    = ImportCycle !Text
    | ImportLimit !Text
    deriving stock (Show)

emptyStack :: ImportStack
emptyStack = ImportStack Set.empty [] 0

{- | Enter an import. The first push (the root document) is exempt from the
'importMaxDepth' and 'importMaxTotal' limits and does not count towards them.
-}
pushImport :: Text -> ImportStack -> Either PushError ImportStack
pushImport loc stack
    | Set.member loc (isActive stack) =
        Left $
            ImportCycle $
                "Circular import detected: "
                    <> T.intercalate " → " (reverse (loc : isChain stack))
    | depth > importMaxDepth =
        Left $
            ImportLimit $
                "import depth " <> showT depth <> " exceeds " <> showT importMaxDepth <> ": " <> chainText
    | total > importMaxTotal =
        Left $
            ImportLimit $
                "import count " <> showT total <> " exceeds " <> showT importMaxTotal <> " in one run: " <> chainText
    | otherwise =
        Right $
            ImportStack
                { isActive = Set.insert loc (isActive stack)
                , isChain = loc : isChain stack
                , isTotal = total
                }
  where
    isRoot = null (isChain stack)
    -- the chain before this push holds the root plus the imports above it
    depth = length (isChain stack)
    total = isTotal stack + (if isRoot then 0 else 1)
    chainText = T.intercalate " → " (reverse (loc : isChain stack))
    showT :: Int -> Text
    showT = T.pack . show

popImport :: ImportStack -> ImportStack
popImport stack = case isChain stack of
    [] -> stack
    (loc : rest) ->
        stack
            { isActive = Set.delete loc (isActive stack)
            , isChain = rest
            }
