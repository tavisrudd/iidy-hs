{- | Demo command: runs interactive demo scripts with playback and masking.

Supports shell commands, silent execution, sleep, environment variables,
and banner display. Optionally masks AWS account numbers in output.
-}
module Iidy.Demo (
    runDemo,
    DemoCommand (..),
    parseDemoScript,
    unpackFiles,
    maskAwsAccountNumbers,
    substituteIidyCommand,
    sleepMicros,
    typingDelayMicros,
) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (forM_, unless, when)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Scientific (Scientific, toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import System.Directory (
    canonicalizePath,
    createDirectoryIfMissing,
    findExecutable,
    getTemporaryDirectory,
    removeDirectoryRecursive,
 )
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (BufferMode (..), hFlush, hSetBuffering, stderr, stdout)
import System.Process (
    CreateProcess (..),
    StdStream (..),
    createProcess,
    waitForProcess,
 )
import Text.Regex.TDFA ((=~))

import Iidy.ShellRunner (bashProcess, runToExit)
import Iidy.Types (ColorChoice (..))
import Iidy.Yaml.Engine (PreprocessResult (..))
import Iidy.Yaml.Errors.Conversion (formatParseErrorEnhanced, formatPreprocessErrorEnhanced)
import Iidy.Yaml.Imports.Loaders.Dispatch (mkImportConfig, preprocessWithConfig)
import Iidy.Yaml.Imports.Types (ImportPolicy (..), RemoteImports (..), trustedSourceList, trustedSourceText)
import Iidy.Yaml.OValue (toValue)
import Iidy.Yaml.Parser (BoolSchema (..), ParseError (..), parseYamlStrictAs)

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

data DemoCommand
    = DemoShell !Text
    | DemoSilent !Text
    | DemoSleep !Double
    | DemoSetEnv !(Map Text Text)
    | DemoBanner !Text
    deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

-- | Run a demo script. Returns exit code.
runDemo :: Text -> Double -> Bool -> ImportPolicy -> IO Int
runDemo scriptPath timescaling maskSecrets policy = do
    let fp = T.unpack scriptPath
    content <- BL.readFile fp
    let baseLocation = scriptPath

    case parseYamlStrictAs Yaml11Bools content baseLocation of
        Left (ParseError pos msg) -> do
            let source = TE.decodeUtf8 (BL.toStrict content)
            formatted <- formatParseErrorEnhanced ColorAuto baseLocation source pos msg
            TIO.hPutStr stderr formatted
            pure 1
        Right ast -> do
            let importCfg = mkImportConfig Nothing policy
            result <- preprocessWithConfig importCfg True ast baseLocation
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
                            runWithTmpDir files commands timescaling maskSecrets policy

runWithTmpDir :: Map Text Text -> [DemoCommand] -> Double -> Bool -> ImportPolicy -> IO Int
runWithTmpDir files commands timescaling maskSecrets policy = do
    tmpDir <- getTemporaryDirectory
    let demoDir = tmpDir </> "iidy-demo"
    bracket
        (createDirectoryIfMissing True demoDir >> pure demoDir)
        removeDirectoryRecursive
        ( \d -> do
            unpackFiles files d
            baseEnv <- getEnvironment
            let envMap =
                    Map.fromList [(T.pack k, T.pack v) | (k, v) <- baseEnv]
                        `Map.union` Map.singleton "PKG_SKIP_EXECPATH_PATCH" "yes"
            iidyExe <- getIidyExe
            let envWithExe = case iidyExe of
                    Just exe -> Map.insert "IIDY_EXE" (T.pack exe) envMap
                    Nothing -> envMap
            runCommands commands d envWithExe iidyExe timescaling maskSecrets policy
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
            _noFiles -> Map.empty
    commands <- case KM.lookup "demo" obj of
        Just (Array arr) -> traverse parseCommand (V.toList arr)
        _missingDemo -> Left "demo script must have a 'demo' key with a sequence value"
    Right (files, commands)
parseDemoScript _ = Left "demo script must be a mapping"

extractText :: Value -> Text
extractText (String s) = s
extractText v = T.pack (show v)

parseCommand :: Value -> Either Text DemoCommand
parseCommand (String cmd) = Right (DemoShell cmd)
parseCommand (Object obj)
    | Just (String cmd) <- KM.lookup "silent" obj = Right (DemoSilent cmd)
    | Just (Number n) <- KM.lookup "sleep" obj
    , n < 0 =
        Left "demo sleep must not be negative"
    -- Compared as a Scientific, before any conversion to Double or Integer,
    -- so a huge exponent such as 1e1000000000 is never expanded.
    | Just (Number n) <- KM.lookup "sleep" obj
    , n > maxSleepSeconds =
        Left "demo sleep must not exceed 86400 seconds"
    | Just (Number n) <- KM.lookup "sleep" obj = Right (DemoSleep (toRealFloat n))
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

runCommands :: [DemoCommand] -> FilePath -> Map Text Text -> Maybe String -> Double -> Bool -> ImportPolicy -> IO ()
runCommands commands workDir envMap iidyExe timescaling maskSecrets policy =
    go commands envMap
  where
    go [] _ = pure ()
    go (cmd : rest) currentEnv = do
        newEnv <- runCommand cmd workDir currentEnv iidyExe timescaling maskSecrets policy
        go rest newEnv

runCommand :: DemoCommand -> FilePath -> Map Text Text -> Maybe String -> Double -> Bool -> ImportPolicy -> IO (Map Text Text)
runCommand cmd workDir envMap iidyExe timescaling maskSecrets policy = case cmd of
    DemoShell shellCmd -> do
        let substituted = substituteIidyCommand shellCmd iidyExe policy
        printCommand substituted timescaling
        execShell substituted workDir envMap maskSecrets
        pure envMap
    DemoSilent shellCmd -> do
        let substituted = substituteIidyCommand shellCmd iidyExe policy
        execShell substituted workDir envMap maskSecrets
        pure envMap
    DemoSleep secs -> do
        threadDelay (sleepMicros secs timescaling)
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
    exitCode <- runToExit (bashProcess cmd workDir envList)
    unless (exitCode == ExitSuccess) $
        ioError (userError $ "command failed: " ++ T.unpack cmd)

execWithMasking :: Text -> FilePath -> [(String, String)] -> IO ()
execWithMasking cmd workDir envList = do
    (_, Just hOut, Just hErr, ph) <-
        createProcess
            (bashProcess cmd workDir envList)
                { std_out = CreatePipe
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

-- | Longest accepted @sleep:@ value: one day. Keeps the microsecond count far inside 'Int'.
maxSleepSeconds :: Scientific
maxSleepSeconds = 86400

{- | Microseconds a @sleep:@ step waits: seconds scaled by the timescaling,
rounded to the nearest microsecond. Rust truncates to whole seconds
(demo.rs:134-136); iidy-js scales exactly (demo.ts:123).
-}
sleepMicros :: Double -> Double -> Int
sleepMicros secs timescaling = round (secs * timescaling * 1000000)

{- | Microseconds between typed characters: 50ms scaled by the timescaling,
rounded. Rust truncates to whole milliseconds (demo.rs:363-366).
-}
typingDelayMicros :: Double -> Int
typingDelayMicros = sleepMicros 0.05

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
        threadDelay (typingDelayMicros timescaling)
    putStrLn ""
    hSetBuffering stdout LineBuffering

-- | Display a banner with background color.
displayBanner :: Text -> IO ()
displayBanner text = do
    let cols = 80
    let line = T.replicate cols " "
    -- ANSI 256-color 236 background
    let bg = "\ESC[48;5;236m" :: Text
    let fg = "\ESC[1;33m" :: Text -- bold yellow
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
        (_, "", _) -> str
        (before, _, after) -> before ++ "************" ++ maskString after

------------------------------------------------------------------------
-- iidy command substitution
------------------------------------------------------------------------

{- | Replace 'iidy' command at command positions with the actual executable path.
When the current binary is the @iidy@ on @PATH@ ('Nothing'), the command is
left alone unless the policy adds flags; then the name is kept and the flags
follow it, so the policy is never dropped.
The import policy is passed on immediately after the executable:
@--no-remote-imports@ when remote imports are blocked, and one
@--trust-import-source@ per trusted prefix, shell-quoted.
-}
substituteIidyCommand :: Text -> Maybe String -> ImportPolicy -> Text
substituteIidyCommand cmd mexe policy
    | null flags && isNothing mexe = cmd
    | otherwise = T.pack $ substAll (T.unpack cmd) (exe ++ flags)
  where
    exe = fromMaybe "iidy" mexe
    flags = policyFlags policy

-- | The command-line flags that carry the import policy to a child iidy.
policyFlags :: ImportPolicy -> String
policyFlags policy =
    let remoteFlag = case ipRemoteImports policy of
            BlockRemoteImports -> " --no-remote-imports"
            AllowRemoteImports -> ""
        trustFlags =
            concat
                [ " --trust-import-source " ++ shellQuote (T.unpack (trustedSourceText p))
                | p <- trustedSourceList (ipTrustedSources policy)
                ]
     in remoteFlag ++ trustFlags

-- | Single-quote a word for the shell.
shellQuote :: String -> String
shellQuote w = "'" ++ concatMap (\c -> if c == '\'' then "'\\''" else [c]) w ++ "'"

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
    go ('i' : 'i' : 'd' : 'y' : rest) = exe ++ rest
    go (c : cs) = c : go cs

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
