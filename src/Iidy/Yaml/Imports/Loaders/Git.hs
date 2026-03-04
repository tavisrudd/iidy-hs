{- | Git import loader: query the local git repository for metadata.

Supported formats:

  * @git:branch@   — current branch name (@git rev-parse --abbrev-ref HEAD@)
  * @git:describe@ — human-readable description (@git describe --always --dirty --tags@)
  * @git:sha@      — full commit SHA (@git rev-parse HEAD@)
-}
module Iidy.Yaml.Imports.Loaders.Git (
    loadGitImport,
) where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

import Iidy.Yaml.Imports.Types (ImportData (..), ImportError (..), ImportType (..))

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

{- | Load a git metadata import.
The @location@ parameter must be one of:
  @git:branch@, @git:describe@, or @git:sha@.
The @baseLocation@ parameter is unused (git queries are always local).
-}
loadGitImport :: Text -> Text -> IO (Either ImportError ImportData)
loadGitImport location _baseLocation = do
    let stripped = fromMaybe location (T.stripPrefix "git:" location)
    case gitCommand stripped of
        Left err -> pure (Left err)
        Right (prog, args) -> runGit location prog args

------------------------------------------------------------------------
-- Command mapping
------------------------------------------------------------------------

-- | Map a git sub-command name to the corresponding @git@ invocation.
gitCommand :: Text -> Either ImportError (String, [String])
gitCommand cmd = case cmd of
    "branch" -> Right ("git", ["rev-parse", "--abbrev-ref", "HEAD"])
    "describe" -> Right ("git", ["describe", "--always", "--dirty", "--tags"])
    "sha" -> Right ("git", ["rev-parse", "HEAD"])
    other ->
        Left $
            ImportError $
                "Invalid git command: "
                    <> other
                    <> ". Expected: branch|describe|sha"

------------------------------------------------------------------------
-- Process execution
------------------------------------------------------------------------

-- | Run a git sub-process and return its trimmed stdout as an import.
runGit :: Text -> String -> [String] -> IO (Either ImportError ImportData)
runGit location prog args = do
    result <- try @IOException (readProcessWithExitCode prog args "")
    case result of
        Left ex ->
            pure $
                Left $
                    ImportError $
                        "Failed to run git for " <> location <> ": " <> T.pack (show ex)
        Right (ExitSuccess, stdout, _stderr) ->
            let value = T.strip (T.pack stdout)
             in pure $
                    Right $
                        ImportData
                            { idType = ImportGit
                            , idLocation = location
                            , idRawData = value
                            , idDoc = String value
                            }
        Right (ExitFailure code, _stdout, stderr) ->
            pure $
                Left $
                    ImportError $
                        "Git command failed (exit "
                            <> T.pack (show code)
                            <> ") for "
                            <> location
                            <> ": "
                            <> T.strip (T.pack stderr)
