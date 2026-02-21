module Iidy.Yaml.Imports.Loaders.Random
  ( loadRandomImport
  ) where

import Data.Aeson (Value(..))
import Data.Text (Text)
import qualified Data.Text as T
import System.Random (randomRIO)
import Iidy.Yaml.Imports.Types (ImportData(..), ImportType(..), ImportError(..))

-- | Load a random import.
-- Formats: random:dashed-name, random:name, random:int
loadRandomImport :: Text -> IO (Either ImportError ImportData)
loadRandomImport location = do
  let stripped = maybe location id (T.stripPrefix "random:" location)
  case stripped of
    "dashed-name" -> do
      adj <- randomElement adjectives
      noun <- randomElement nouns
      let val = adj <> "-" <> noun
      pure $ Right $ mkResult location val
    "name" -> do
      adj <- randomElement adjectives
      noun <- randomElement nouns
      let val = adj <> noun
      pure $ Right $ mkResult location val
    "int" -> do
      n <- randomRIO (1 :: Int, 999)
      let val = T.pack (show n)
      pure $ Right $ mkResult location val
    other ->
      pure $ Left $ ImportError $ "Unknown random type: " <> other

mkResult :: Text -> Text -> ImportData
mkResult loc val = ImportData
  { idType     = ImportRandom
  , idLocation = loc
  , idRawData  = val
  , idDoc      = String val
  }

randomElement :: [Text] -> IO Text
randomElement xs = do
  i <- randomRIO (0, Prelude.length xs - 1)
  pure (xs !! i)

adjectives :: [Text]
adjectives =
  [ "red", "blue", "green", "yellow", "purple", "orange"
  , "silver", "golden", "crystal", "cosmic", "electric"
  , "swift", "calm", "bold", "warm", "cool", "bright"
  , "dark", "light", "wild", "quiet", "loud", "sharp"
  , "smooth", "rough", "soft", "hard", "quick", "slow"
  ]

nouns :: [Text]
nouns =
  [ "cat", "dog", "fox", "wolf", "bear", "hawk"
  , "river", "mountain", "forest", "ocean", "cloud"
  , "star", "moon", "sun", "storm", "wind", "rain"
  , "tree", "stone", "flame", "wave", "leaf", "seed"
  , "bridge", "tower", "gate", "path", "road", "stream"
  ]
