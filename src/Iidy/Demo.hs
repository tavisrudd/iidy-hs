-- | Demo command: runs interactive demo scripts with playback and masking.
--
-- Supports shell commands, silent execution, sleep, environment variables,
-- and banner display. Optionally masks AWS account numbers in output.
module Iidy.Demo
  ( runDemo
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (forM_, unless, when)
import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import qualified Data.Vector as V
import System.Directory (createDirectoryIfMissing, canonicalizePath,
                         getTemporaryDirectory, removeDirectoryRecursive,
                         findExecutable)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)
import System.IO (hFlush, stdout, stderr, hSetBuffering, BufferMode(..))
import System.Process (createProcess, proc, waitForProcess,
                       CreateProcess(..), StdStream(..))
import Text.Regex.Posix ((=~))

import Iidy.Types (ColorChoice(..))
import Iidy.Yaml.Engine (preprocessYaml11, PreprocessResult(..))
import Iidy.Yaml.Errors.Conversion (formatPreprocessErrorEnhanced, formatParseErrorEnhanced)
import Iidy.Yaml.Imports.Loaders.File (dispatchLocalImport)
import Iidy.Yaml.OValue (toValue)
import Iidy.Yaml.Parser (parseYaml, ParseError(..))

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

data DemoCommand
  = DemoShell !Text
  | DemoSilent !Text
  | DemoSleep !Int
  | DemoSetEnv !(Map Text Text)
  | DemoBanner !Text
  deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

-- | Run a demo script. Returns exit code.
runDemo :: Text -> Double -> Bool -> IO Int
runDemo scriptPath timescaling maskSecrets = do
  let fp = T.unpack scriptPath
  content <- BL.readFile fp
  let baseLocation = scriptPath

  case parseYaml content baseLocation of
    Left (ParseError pos msg) -> do
      let source = TE.decodeUtf8 (BL.toStrict content)
      formatted <- formatParseErrorEnhanced ColorAuto baseLocation source pos msg
      TIO.hPutStr stderr formatted
      pure 1

    Right ast -> do
      result <- preprocessYaml11 dispatchLocalImport ast baseLocation
      case result of
        Left err -> do
          let source = TE.decodeUtf8 (BL.toStrict content)
          formatted <- formatPreprocessErrorEnhanced ColorAuto baseLocation source err
          TIO.hPutStr stderr formatted
          pure 1

        Right (PreprocessResult oval _manifest) -> do
          let processed = toValue oval
          case parseDemoScript processed of
            Left err -> do
              TIO.hPutStrLn stderr $ "Failed to parse demo script: " <> err
              pure 1
            Right (files, commands) ->
              runWithTmpDir files commands timescaling maskSecrets

runWithTmpDir :: Map Text Text -> [DemoCommand] -> Double -> Bool -> IO Int
runWithTmpDir files commands timescaling maskSecrets = do
  tmpDir <- getTemporaryDirectory
  let demoDir = tmpDir </> "iidy-demo"
  bracket
    (createDirectoryIfMissing True demoDir >> pure demoDir)
    removeDirectoryRecursive
    (\d -> do
      unpackFiles files d
      baseEnv <- getEnvironment
      let envMap = Map.fromList [(T.pack k, T.pack v) | (k, v) <- baseEnv]
                     `Map.union` Map.singleton "PKG_SKIP_EXECPATH_PATCH" "yes"
      iidyExe <- getIidyExe
      let envWithExe = case iidyExe of
            Just exe -> Map.insert "IIDY_EXE" (T.pack exe) envMap
            Nothing  -> envMap
      runCommands commands d envWithExe iidyExe timescaling maskSecrets
      pure 0
    )

------------------------------------------------------------------------
-- Script parsing
------------------------------------------------------------------------

parseDemoScript :: Value -> Either Text (Map Text Text, [DemoCommand])
parseDemoScript (Object obj) = do
  let files = case KM.lookup "files" obj of
        Just (Object fobj) ->
          Map.fromList [(Key.toText k, extractText v) | (k, v) <- KM.toList fobj]
        _ -> Map.empty
  commands <- case KM.lookup "demo" obj of
    Just (Array arr) -> traverse parseCommand (V.toList arr)
    _ -> Left "demo script must have a 'demo' key with a sequence value"
  Right (files, commands)
parseDemoScript _ = Left "demo script must be a mapping"

extractText :: Value -> Text
extractText (String s) = s
extractText v = T.pack (show v)

parseCommand :: Value -> Either Text DemoCommand
parseCommand (String cmd) = Right (DemoShell cmd)
parseCommand (Object obj)
  | Just (String cmd) <- KM.lookup "silent" obj = Right (DemoSilent cmd)
  | Just (Number n)   <- KM.lookup "sleep" obj  = Right (DemoSleep (truncate n))
  | Just (String txt) <- KM.lookup "banner" obj = Right (DemoBanner txt)
  | Just (Object env') <- KM.lookup "setenv" obj =
      Right (DemoSetEnv (Map.fromList [(Key.toText k, extractText v) | (k, v) <- KM.toList env']))
  | otherwise = Left "unknown demo command format"
parseCommand _ = Left "demo command must be a string or mapping"

------------------------------------------------------------------------
-- File unpacking
------------------------------------------------------------------------

unpackFiles :: Map Text Text -> FilePath -> IO ()
unpackFiles files tmpDir =
  forM_ (Map.toList files) $ \(path, contents) -> do
    let pathStr = T.unpack path
    when (take 1 pathStr == "/") $
      ioError (userError $ "Illegal path " ++ pathStr ++ ". Must be relative.")
    when (".." `T.isInfixOf` path) $
      ioError (userError $ "Illegal path " ++ pathStr ++ ". Cannot contain parent directory references.")
    let fullPath = tmpDir </> pathStr
    createDirectoryIfMissing True (takeDirectory fullPath)
    TIO.writeFile fullPath contents

------------------------------------------------------------------------
-- Command execution
------------------------------------------------------------------------

runCommands :: [DemoCommand] -> FilePath -> Map Text Text -> Maybe String -> Double -> Bool -> IO ()
runCommands commands workDir envMap iidyExe timescaling maskSecrets =
  go commands envMap
  where
    go [] _ = pure ()
    go (cmd:rest) currentEnv = do
      newEnv <- runCommand cmd workDir currentEnv iidyExe timescaling maskSecrets
      go rest newEnv

runCommand :: DemoCommand -> FilePath -> Map Text Text -> Maybe String -> Double -> Bool -> IO (Map Text Text)
runCommand cmd workDir envMap iidyExe timescaling maskSecrets = case cmd of
  DemoShell shellCmd -> do
    let substituted = substituteIidyCommand shellCmd iidyExe
    printCommand substituted timescaling
    execShell substituted workDir envMap maskSecrets
    pure envMap

  DemoSilent shellCmd -> do
    let substituted = substituteIidyCommand shellCmd iidyExe
    execShell substituted workDir envMap maskSecrets
    pure envMap

  DemoSleep secs -> do
    let scaledUs = round (fromIntegral secs * timescaling * 1000000 :: Double) :: Int
    threadDelay scaledUs
    pure envMap

  DemoSetEnv newVars ->
    pure (Map.union newVars envMap)

  DemoBanner text -> do
    displayBanner text
    pure envMap

-- | Execute a shell command, optionally masking AWS account numbers.
execShell :: Text -> FilePath -> Map Text Text -> Bool -> IO ()
execShell cmd workDir envMap maskSecrets = do
  let envList = [(T.unpack k, T.unpack v) | (k, v) <- Map.toList envMap]
  if maskSecrets
    then execWithMasking cmd workDir envList
    else execDirect cmd workDir envList

execDirect :: Text -> FilePath -> [(String, String)] -> IO ()
execDirect cmd workDir envList = do
  (_, _, _, ph) <- createProcess (proc "/usr/bin/env" ["bash", "-c", T.unpack cmd])
    { cwd = Just workDir
    , env = Just envList
    }
  exitCode <- waitForProcess ph
  unless (exitCode == ExitSuccess) $
    ioError (userError $ "command failed: " ++ T.unpack cmd)

execWithMasking :: Text -> FilePath -> [(String, String)] -> IO ()
execWithMasking cmd workDir envList = do
  (_, Just hOut, Just hErr, ph) <- createProcess (proc "/usr/bin/env" ["bash", "-c", T.unpack cmd])
    { cwd = Just workDir
    , env = Just envList
    , std_out = CreatePipe
    , std_err = CreatePipe
    }
  -- Read output, mask, and write
  output <- TIO.hGetContents hOut
  errOutput <- TIO.hGetContents hErr
  TIO.putStr (maskAwsAccountNumbers output)
  unless (T.null errOutput) $
    TIO.hPutStr stderr (maskAwsAccountNumbers errOutput)
  hFlush stdout
  exitCode <- waitForProcess ph
  unless (exitCode == ExitSuccess) $
    ioError (userError $ "command failed: " ++ T.unpack cmd)

------------------------------------------------------------------------
-- Display
------------------------------------------------------------------------

-- | Print a command character by character to simulate typing.
printCommand :: Text -> Double -> IO ()
printCommand cmd timescaling = do
  hSetBuffering stdout NoBuffering
  -- Red "Shell Prompt > "
  TIO.putStr "\ESC[31mShell Prompt >\ESC[0m "
  -- White text, one char at a time
  forM_ (T.unpack cmd) $ \ch -> do
    putChar ch
    hFlush stdout
    let delayUs = round (50.0 * timescaling * 1000 :: Double) :: Int
    threadDelay delayUs
  putStrLn ""
  hSetBuffering stdout LineBuffering

-- | Display a banner with background color.
displayBanner :: Text -> IO ()
displayBanner text = do
  let cols = 80
  let line = T.replicate cols " "
  -- ANSI 256-color 236 background
  let bg = "\ESC[48;5;236m" :: Text
  let fg = "\ESC[1;33m" :: Text  -- bold yellow
  let reset = "\ESC[0m" :: Text
  putStrLn ""
  TIO.putStrLn $ bg <> line <> reset
  forM_ (T.splitOn "\n" text) $ \ln -> do
    let padding = max 0 (cols - T.length ln - 2)
    TIO.putStrLn $ bg <> fg <> "  " <> ln <> T.replicate padding " " <> reset
  TIO.putStrLn $ bg <> line <> reset
  putStrLn ""

------------------------------------------------------------------------
-- Masking
------------------------------------------------------------------------

-- | Mask AWS account numbers (12-digit sequences) in text.
maskAwsAccountNumbers :: Text -> Text
maskAwsAccountNumbers = T.pack . maskString . T.unpack

maskString :: String -> String
maskString [] = []
maskString str =
  case str =~ ("\\b[0-9]{12}\\b" :: String) :: (String, String, String) of
    (_, "", _)         -> str
    (before, _, after) -> before ++ "************" ++ maskString after

------------------------------------------------------------------------
-- iidy command substitution
------------------------------------------------------------------------

-- | Replace 'iidy' command at command positions with the actual executable path.
substituteIidyCommand :: Text -> Maybe String -> Text
substituteIidyCommand cmd Nothing = cmd
substituteIidyCommand cmd (Just exe) =
  T.pack $ substAll (T.unpack cmd) (T.unpack (T.pack exe))

substAll :: String -> String -> String
substAll [] _ = []
substAll str exe =
  case str =~ ("(^|[|;&({])( *)(iidy)\\b" :: String) :: (String, String, String) of
    (_, "", _) -> str
    (before, match', after) ->
      let replaced = replaceIidyInMatch match' exe
      in before ++ replaced ++ substAll after exe

replaceIidyInMatch :: String -> String -> String
replaceIidyInMatch match' exe = go match'
  where
    go [] = []
    go ('i':'i':'d':'y':rest) = exe ++ rest
    go (c:cs) = c : go cs

-- | Determine the iidy executable path, checking if substitution is needed.
getIidyExe :: IO (Maybe String)
getIidyExe = do
  currentExe <- getExecutablePath
  mWhichIidy <- findExecutable "iidy"
  case mWhichIidy of
    Nothing -> pure (Just currentExe)
    Just whichPath -> do
      currentCanon <- canonicalizePath currentExe
      whichCanon <- canonicalizePath whichPath
      if currentCanon == whichCanon
        then pure Nothing
        else pure (Just currentExe)
