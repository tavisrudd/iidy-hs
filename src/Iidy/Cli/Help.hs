module Iidy.Cli.Help
  ( shouldShowTopLevelHelp
  , renderTopLevelHelp
  , renderHelpForArgs
  , renderParserFailure
  , helpColorEnabled
  , headingLine
  , colorCommand
  , formatUsageLine
  , formatRowsForTest -- test-only helper
  , helpDescriptionForTest -- test-only helper
  ) where

import Control.Monad (when)
import qualified Data.Char as Char
import Data.List (dropWhileEnd, isInfixOf, isPrefixOf, stripPrefix)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe)
import qualified System.Console.ANSI as ANSI
import qualified System.Environment
import System.IO (stdout, stderr, hIsTerminalDevice, hPutStrLn)
import System.Console.Terminal.Size (Window(..), size)
import Options.Applicative.Help.Types (ParserHelp(..))
import Options.Applicative.Help.Chunk (Chunk(..))
import Prettyprinter (Doc, defaultLayoutOptions, layoutPretty)
import Prettyprinter.Render.String (renderString)

-- | Determine if we should short-circuit to the custom top-level help output.
shouldShowTopLevelHelp :: [String] -> Bool
shouldShowTopLevelHelp args =
  null args ||
  (any isHelpFlag args && not (any (`elem` allCommandNames) args))
  where
    isHelpFlag opt = opt == "--help" || opt == "-h"

renderTopLevelHelp :: IO ()
renderTopLevelHelp = do
  useColor <- helpColorEnabled
  wrapWidth <- detectHelpWidth
  putStrLn . unlines . concat $
    [ [ colorTitle useColor "CloudFormation with Confidence"
      , colorSubtitle useColor "An acronym for \"Is it done yet?\""
      , ""
      , headingLine useColor "Usage:" <> " iidy-hs [OPTIONS] <COMMAND>"
      , ""
      , headingLine useColor "Commands:"
      ]
    , formatRows wrapWidth (colorCommand useColor) visibleCommandHelpRows
    , [ ""
      , headingLine useColor "Options:"
      ]
    , formatRows wrapWidth (colorItem useColor) optionHelpRows
    , [ ""
      , headingLine useColor "Global Options:"
      ]
    , formatRows wrapWidth (colorItem useColor) globalOptionHelpRows
    , [ ""
      , headingLine useColor "AWS Options:"
      ]
    , formatRows wrapWidth (colorItem useColor) awsOptionHelpRows
    , [ ""
      , headingLine useColor "Status Codes:"
      ]
    , formatRows wrapWidth (colorItem useColor) statusCodeRows
    ]

renderHelpForArgs :: [String] -> String -> IO ()
renderHelpForArgs args defaultMsg = do
  let cmdPath = commandPathFromArgs args
  if null cmdPath
    then renderTopLevelHelp
    else do
      useColor <- helpColorEnabled
      wrapWidth <- detectHelpWidth
      case parseHelpMessage defaultMsg of
        Nothing -> putStrLn defaultMsg
        Just parsed -> do
          let sections = phSections parsed
              normalized = map normalizeSection sections
              existingTitles = map (map Char.toLower) (map fst normalized)
              extras =
                [ (title, rows)
                | (title, rows) <- [("Global Options", globalOptionHelpRows), ("AWS Options", awsOptionHelpRows)]
                , map Char.toLower title `notElem` existingTitles
                ]
              parsed' = parsed { phSections = normalized ++ extras }
              parsed'' = maybe parsed' (\desc -> parsed' { phDescription = [desc] }) (commandDescription cmdPath)
          renderParsedHelp useColor wrapWidth parsed''

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

helpColorEnabled :: IO Bool
helpColorEnabled = do
  isTty <- hIsTerminalDevice stdout
  supportsAnsi <- ANSI.hSupportsANSIColor stdout
  noColor <- System.Environment.lookupEnv "NO_COLOR"
  let disabledByEnv = maybe False (const True) noColor
  pure (isTty && supportsAnsi && not disabledByEnv)

headingLine :: Bool -> String -> String
headingLine useColor label = applyColor useColor headingColorCode label

colorTitle, colorSubtitle, colorCommand, colorItem :: Bool -> String -> String
colorTitle useColor = applyColor useColor titleColorCode
colorSubtitle useColor = applyColor useColor subtitleColorCode
colorCommand useColor = applyColor useColor commandColorCode
colorItem useColor = applyColor useColor itemColorCode

applyColor :: Bool -> String -> String -> String
applyColor True code txt = code <> txt <> resetCode
applyColor False _ txt = txt

headingColorCode, titleColorCode, subtitleColorCode, commandColorCode, itemColorCode, resetCode :: String
headingColorCode = ANSI.setSGRCode [ANSI.SetConsoleIntensity ANSI.BoldIntensity, ANSI.SetColor ANSI.Foreground ANSI.Vivid ANSI.Yellow]
titleColorCode = ANSI.setSGRCode [ANSI.SetConsoleIntensity ANSI.BoldIntensity, ANSI.SetColor ANSI.Foreground ANSI.Vivid ANSI.Cyan]
subtitleColorCode = ANSI.setSGRCode [ANSI.SetColor ANSI.Foreground ANSI.Dull ANSI.White]
commandColorCode = ANSI.setSGRCode [ANSI.SetColor ANSI.Foreground ANSI.Vivid ANSI.Cyan]
itemColorCode = ANSI.setSGRCode [ANSI.SetColor ANSI.Foreground ANSI.Vivid ANSI.Cyan]
resetCode = ANSI.setSGRCode [ANSI.Reset]

formatRows :: Int -> (String -> String) -> [(String, String)] -> [String]
formatRows wrapWidth stylize rows
  | null rows = []
  | otherwise = concatMap renderRow formatted
  where
    formatted = map (\(name, desc) -> (formatEntryName name, desc)) rows
    nameWidth = maximum (0 : [length name | (name, _) <- formatted, not (null name)])
    availableWidth = max 20 (wrapWidth - nameWidth - 4)
    renderRow ("", "") = [""]
    renderRow (name, desc) =
      let descLines = wrapDescription availableWidth desc
          paddedName =
            if null name
              then replicate nameWidth ' '
              else padRight nameWidth name
          firstLine =
            "  " <> stylize paddedName <> "  " <> head descLines
          rest =
            [ "  " <> replicate nameWidth ' ' <> "  " <> line
            | line <- tail descLines
            ]
      in firstLine : rest
    padRight w txt =
      let padding = replicate (max 0 (w - length txt)) ' '
      in txt <> padding

formatEntryName :: String -> String
formatEntryName =
  unwords . map formatToken . words
  where
    formatToken tok
      | null tok = tok
      | head tok == '<' = tok
      | "--" `isPrefixOf` tok = tok
      | isPlaceholderToken tok = "<" <> tok <> ">"
      | otherwise = tok
    isPlaceholderToken token =
      not (null token) && all isAllowed token
    isAllowed c = Char.isUpper c || Char.isDigit c || c == '_'

wrapDescription :: Int -> String -> [String]
wrapDescription limit desc
  | limit <= 10 = lines desc
  | otherwise =
      concatMap (wrapParagraph limit) (splitParagraphs desc)

splitParagraphs :: String -> [String]
splitParagraphs "" = [""]
splitParagraphs txt = lines txt

wrapParagraph :: Int -> String -> [String]
wrapParagraph _ "" = [""]
wrapParagraph limit paragraph = wrapWords [] (words paragraph)
  where
    wrapWords current [] =
      case current of
        [] -> []
        _  -> [unwords (reverse current)]
    wrapWords [] (w:ws)
      | length w >= limit = w : wrapWords [] ws
      | otherwise = wrapWords [w] ws
    wrapWords acc (w:ws)
      | length (unwords (reverse (w:acc))) <= limit =
          wrapWords (w:acc) ws
      | otherwise =
          unwords (reverse acc) : wrapWords [w] ws

detectHelpWidth :: IO Int
detectHelpWidth = do
  mWin <- size
  let fallback = 100
  pure $ maybe fallback (clampWidth . width) mWin
  where
    clampWidth w = max 60 (min 120 w)

-- Test helpers --------------------------------------------------------

formatRowsForTest :: Int -> [(String, String)] -> [String]
formatRowsForTest wrapWidth = formatRows wrapWidth id

helpDescriptionForTest :: [String] -> Maybe String
helpDescriptionForTest = commandDescription

visibleCommandHelpRows :: [(String, String)]
visibleCommandHelpRows =
  [ ("create-stack", "create a cfn stack based on stack-args.yaml")
  , ("update-stack", "update a cfn stack based on stack-args.yaml")
  , ("create-or-update", "create or update a cfn stack based on stack-args.yaml")
  , ("estimate-cost", "estimate aws costs based on stack-args.yaml")
  , ("", "")
  , ("create-changeset", "create a cfn changeset based on stack-args.yaml")
  , ("exec-changeset", "execute a cfn changeset based on stack-args.yaml")
  , ("", "")
  , ("describe-stack", "describe a stack")
  , ("watch-stack", "watch a stack that is already being created or updated")
  , ("describe-stack-drift", "describe stack drift")
  , ("delete-stack", "delete a stack (after confirmation)")
  , ("get-stack-template", "download the template of a live stack")
  , ("list-stacks", "list all stacks within a region")
  , ("", "")
  , ("param", "sub commands for working with AWS SSM Parameter Store")
  , ("", "")
  , ("template-approval", "sub commands for template approval")
  , ("", "")
  , ("render", "pre-process and render yaml template")
  , ("get-import", "retrieve and print an $import value directly")
  , ("demo", "run a demo script")
  , ("lint-template", "lint a CloudFormation template")
  , ("convert-stack-to-iidy", "create an iidy project directory from an existing CFN stack")
  , ("init-stack-args", "initialize stack-args.yaml and cfn-template.yaml")
  , ("", "")
  , ("completion", "generate shell completion script")
  , ("explain", "explain error codes")
  , ("help", "Print this message or the help of the given subcommand(s)")
  ]

paramCommandHelpRows :: [(String, String)]
paramCommandHelpRows =
  [ ("set", "set a parameter value")
  , ("review", "review a pending change")
  , ("get", "get a parameter value")
  , ("get-by-path", "get parameters by path")
  , ("get-history", "get a parameter's history")
  ]

approvalCommandHelpRows :: [(String, String)]
approvalCommandHelpRows =
  [ ("request", "request template approval")
  , ("review", "review pending template approval request")
  ]

optionHelpRows :: [(String, String)]
optionHelpRows =
  [ ("-h, --help", "Print help (see a summary with '-h')")
  , ("-V, --version", "Print version")
  ]

globalOptionHelpRows :: [(String, String)]
globalOptionHelpRows =
  [ ("-e, --environment <ENVIRONMENT>", "Used to load environment based settings: AWS Profile, Region, etc.\n[default: development]")
  , ("    --color <COLOR>", "Whether to color output using ANSI escape codes\n[default: auto]\n[possible values: auto, always, never]")
  , ("    --theme <THEME>", "Color theme to use for output\n[default: auto]\n[possible values: auto, light, dark, high-contrast]")
  , ("    --output-mode <OUTPUT_MODE>", "Output mode for console display\n\nPossible values:\n- plain:       Non-interactive text for CI/logs (no spinners)\n- interactive: Interactive text with spinners and colors (exact iidy-js match)\n- json:        Machine-readable JSON Lines format")
  , ("    --debug", "Log debug information to stderr.")
  , ("    --log-full-error", "Log full error information to stderr.")
  ]

awsOptionHelpRows :: [(String, String)]
awsOptionHelpRows =
  [ ("--region <REGION>", "AWS region. Can also be set via --environment & stack-args.yaml:Region.")
  , ("--profile <PROFILE>", "AWS profile. Can also be set via --environment & stack-args.yaml:Profile. Use --profile=no-profile to override stack-args.yaml and use AWS_* env vars.")
  , ("--assume-role-arn <ARN>", "AWS role ARN to assume. Can also be set via --environment & stack-args.yaml:AssumeRoleArn. Use --assume-role-arn=no-role to override stack-args.yaml and use AWS_* env vars.")
  , ("--client-request-token <TOKEN>", "A unique, case-sensitive string of up to 64 ASCII characters used to ensure idempotent retries.")
  ]

statusCodeRows :: [(String, String)]
statusCodeRows =
  [ ("Success (0)", "Command successfully completed")
  , ("Error (1)", "An error was encountered while executing command")
  , ("Cancelled (130)", "User responded 'No' to prompt or sent CTRL-C")
  ]

hiddenCommandNames :: [String]
hiddenCommandNames = ["get-stack-instances"]

allCommandNames :: [String]
allCommandNames = map fst visibleCommandHelpRows <> hiddenCommandNames

topLevelDescriptionMap :: Map String String
topLevelDescriptionMap = Map.fromList
  [ (name, desc)
  | (name, desc) <- visibleCommandHelpRows
  , not (null name)
  , not (null desc)
  ]

paramDescriptionMap :: Map String String
paramDescriptionMap = Map.fromList paramCommandHelpRows

approvalDescriptionMap :: Map String String
approvalDescriptionMap = Map.fromList approvalCommandHelpRows

commandDescription :: [String] -> Maybe String
commandDescription [] = Nothing
commandDescription [cmd] = Map.lookup cmd topLevelDescriptionMap
commandDescription [parent, sub] =
  case parent of
    "param" -> Map.lookup sub paramDescriptionMap
    "template-approval" -> Map.lookup sub approvalDescriptionMap
    _ -> Nothing
commandDescription _ = Nothing

------------------------------------------------------------------------
-- Subcommand help parsing / formatting
------------------------------------------------------------------------

renderParsedHelp :: Bool -> Int -> ParsedHelp -> IO ()
renderParsedHelp useColor wrapWidth (ParsedHelp usage desc sections) = do
  printParagraph desc
  putStrLn $ headingLine useColor "Usage:" <> " " <> formatUsageLine usage
  putStrLn ""
  let (argRowsRaw, optRowsRaw, otherSections) = classifySections sections
      (positionalRows, optionRows) = partitionRows optRowsRaw
      argRows =
        if null argRowsRaw
          then positionalRows
          else argRowsRaw ++ positionalRows
      optRows =
        if null argRowsRaw
          then optionRows
          else optRowsRaw
  when (not (null argRows)) $
    renderSection useColor wrapWidth ("Arguments", argRows)
  when (not (null optRows)) $
    renderSection useColor wrapWidth ("Options", optRows)
  mapM_ (renderSection useColor wrapWidth) otherSections

renderSection :: Bool -> Int -> (String, [(String, String)]) -> IO ()
renderSection _ _ (_, []) = pure ()
renderSection useColor wrapWidth (title, rows) = do
  putStrLn $ headingLine useColor (title <> ":")
  mapM_ putStrLn (formatRows wrapWidth (colorItem useColor) rows)
  putStrLn ""

normalizeSection :: (String, [(String, String)]) -> (String, [(String, String)])
normalizeSection (title, rows) =
  case map Char.toLower title of
    "available options"     -> ("Options", rows)
    "available commands"    -> ("Commands", rows)
    "available subcommands" -> ("Commands", rows)
    "arguments"             -> ("Arguments", rows)
    _                       -> (title, rows)

classifySections :: [(String, [(String, String)])] -> ([(String, String)], [(String, String)], [(String, [(String, String)])])
classifySections = foldr go ([], [], [])
  where
    go (title, rows) (args, opts, rest) =
      case map Char.toLower title of
        "arguments" -> (args ++ rows, opts, rest)
        "options"   -> (args, opts ++ rows, rest)
        _           -> (args, opts, (title, rows) : rest)

partitionRows :: [(String, String)] -> ([(String, String)], [(String, String)])
partitionRows = foldr go ([], [])
  where
    go row@(name, _) (posArgs, opts)
      | isPositional name = (row : posArgs, opts)
      | otherwise = (posArgs, row : opts)
    isPositional txt =
      let trimmed = dropWhile (== ' ') txt
      in not (null trimmed) && head trimmed /= '-'

------------------------------------------------------------------------
-- Parser failure rendering
------------------------------------------------------------------------

data ErrorDetail
  = MissingArgDetail String
  | RawErrorLine String

renderParserFailure :: ParserHelp -> IO ()
renderParserFailure parserHelp = do
  useColor <- errorColorEnabled
  let (primaryLine, detailLines) = formatErrorChunk (chunkLines (helpError parserHelp))
  case primaryLine of
    Nothing -> pure ()
    Just line -> do
      putStrLnErr (colorErrorLabel useColor ("error: " <> line))
      mapM_ (renderDetailLine useColor) detailLines
      putStrLnErr ""
  case listToMaybe (chunkLines (helpUsage parserHelp)) of
    Nothing -> pure ()
    Just usageLine -> do
      let formattedUsage = formatUsageLine usageLine
      putStrLnErr (headingLine useColor "Usage:" <> " " <> colorCommand useColor formattedUsage)
      putStrLnErr ""
  putStrLnErr "For more information, try '--help'."

renderDetailLine :: Bool -> ErrorDetail -> IO ()
renderDetailLine useColor detail =
  case detail of
    MissingArgDetail arg ->
      putStrLnErr ("  " <> colorCommand useColor arg)
    RawErrorLine line ->
      putStrLnErr ("  " <> line)

formatErrorChunk :: [String] -> (Maybe String, [ErrorDetail])
formatErrorChunk [] = (Nothing, [])
formatErrorChunk (line:rest) =
  case stripPrefix "Missing:" line of
    Just missing ->
      let headerLine = "the following required arguments were not provided:"
          missingArgs = map MissingArgDetail (formatMissingArgs (words missing))
      in (Just headerLine, missingArgs <> map RawErrorLine rest)
    Nothing -> (Just line, map RawErrorLine rest)

formatMissingArgs :: [String] -> [String]
formatMissingArgs =
  map (wrapToken . dropWhile Char.isSpace)
  where
    wrapToken tok
      | null tok = tok
      | all isPlaceholderChar tok = "<" <> tok <> ">"
      | otherwise = tok
    isPlaceholderChar c = Char.isUpper c || c == '_' || Char.isDigit c

chunkLines :: Chunk (Doc ann) -> [String]
chunkLines chunk =
  case unChunk chunk of
    Nothing -> []
    Just doc -> filter (not . null) (lines (renderDoc doc))

renderDoc :: Doc ann -> String
renderDoc doc =
  renderString (layoutPretty defaultLayoutOptions doc)

colorErrorLabel :: Bool -> String -> String
colorErrorLabel True txt = errorColorCode <> txt <> ansiResetCode
colorErrorLabel False txt = txt

errorColorCode :: String
errorColorCode = ANSI.setSGRCode [ANSI.SetConsoleIntensity ANSI.BoldIntensity, ANSI.SetColor ANSI.Foreground ANSI.Vivid ANSI.Red]

ansiResetCode :: String
ansiResetCode = ANSI.setSGRCode [ANSI.Reset]

errorColorEnabled :: IO Bool
errorColorEnabled = do
  isTty <- hIsTerminalDevice stderr
  supportsAnsi <- ANSI.hSupportsANSIColor stderr
  noColor <- System.Environment.lookupEnv "NO_COLOR"
  let disableColor = maybe False (const True) noColor
  pure (isTty && supportsAnsi && not disableColor)

putStrLnErr :: String -> IO ()
putStrLnErr = hPutStrLn stderr

formatUsageLine :: String -> String
formatUsageLine line =
  let trimmed = dropWhile Char.isSpace line
      prefix = "Usage:" :: String
      rest = dropWhile Char.isSpace (drop (length prefix) trimmed)
      (cleaned, hadOptions) = removeOptionalSegments rest
      tokens = words cleaned
      (cmdTokens, argTokens) = splitCommandArgs tokens
      optionsToken = if hadOptions then ["[OPTIONS]"] else []
      rebuilt = unwords (cmdTokens ++ optionsToken ++ argTokens)
  in rebuilt

removeOptionalSegments :: String -> (String, Bool)
removeOptionalSegments = go False
  where
    go hadOpt [] = ([], hadOpt)
    go hadOpt ('[':xs) =
      let (content, rest) = break (== ']') xs
      in case rest of
           [] -> let (tailStr, opt) = go hadOpt [] in ('[':content ++ tailStr, opt)
           (_:rest') ->
             if "--" `isInfixOf` content
               then go True rest'
               else
                 let (tailStr, opt) = go hadOpt rest'
                 in ('[':content ++ "]" ++ tailStr, opt)
    go hadOpt (x:xs) =
      let (tailStr, opt) = go hadOpt xs
      in (x : tailStr, opt)

splitCommandArgs :: [String] -> ([String], [String])
splitCommandArgs tokens =
  let (cmd, rest) = break isArgToken tokens
  in (cmd, rest)

isArgToken :: String -> Bool
isArgToken tok =
  case tok of
    [] -> False
    ('<':_) -> True
    _ ->
      let letters = filter Char.isAlpha tok
      in not (null letters) && all Char.isUpper letters

unlessNull :: [a] -> IO () -> IO ()
unlessNull xs ioAction =
  if null xs then pure () else ioAction

commandPathFromArgs :: [String] -> [String]
commandPathFromArgs args =
  case nextToken (takeWhile (not . isHelpFlag) args) of
    Nothing -> []
    Just (cmd, rest)
      | cmd `elem` topLevelCommands ->
          cmd : maybe [] (:[]) (findSubcommand cmd rest)
      | otherwise -> []
  where
    topLevelCommands = [name | (name, _) <- visibleCommandHelpRows, not (null name)] <> hiddenCommandNames
    isHelpFlag opt = opt == "-h" || opt == "--help"
    isOption tok = "-" `isPrefixOf` tok
    nextToken = go
      where
        go [] = Nothing
        go (tok:rest)
          | isOption tok = go rest
          | otherwise = Just (tok, rest)
    findSubcommand cmd tokens =
      case Map.lookup cmd subcommandMap of
        Nothing -> Nothing
        Just subOpts ->
          case nextToken tokens of
            Just (tok, _) | tok `elem` subOpts -> Just tok
            _ -> Nothing

subcommandMap :: Map String [String]
subcommandMap = Map.fromList
  [ ("param", ["set", "review", "get", "get-by-path", "get-history"])
  , ("template-approval", ["request", "review"])
  ]

parseHelpMessage :: String -> Maybe ParsedHelp
parseHelpMessage msg =
  case break isUsageLine (lines msg) of
    (_, []) -> Nothing
    (beforeUsage, usageLine:afterUsage) ->
      let (descLines, remainder) = spanDescription afterUsage
          before = dropWhile null beforeUsage
          desc = if null descLines then before else descLines
      in Just ParsedHelp
          { phUsage = usageLine
          , phDescription = map (dropWhile Char.isSpace) desc
          , phSections = parseSections remainder
          }

isUsageLine :: String -> Bool
isUsageLine line = "Usage:" `isPrefixOf` dropWhile Char.isSpace line

spanDescription :: [String] -> ([String], [String])
spanDescription = go [] . dropWhile null
  where
    go acc [] = (reverse acc, [])
    go acc (line:rest)
      | null line = (reverse acc, rest)
      | isSectionHeader line = (reverse acc, line:rest)
      | otherwise = go (line:acc) rest

parseSections :: [String] -> [(String, [(String, String)])]
parseSections = reverse . finalize [] Nothing . dropWhile null
  where
    finalize acc Nothing [] = acc
    finalize acc (Just section) [] = section : acc
    finalize acc current (line:rest)
      | isSectionHeader line =
          let newAcc = maybe acc (:acc) current
              title = trimColon (dropWhile Char.isSpace line)
          in finalize newAcc (Just (title, [])) rest
      | isRowLine line =
          case current of
            Nothing -> finalize acc current rest
            Just (title, rows) ->
              let entry = parseRow line
              in finalize acc (Just (title, rows ++ [entry])) rest
      | otherwise = finalize acc current rest

isSectionHeader :: String -> Bool
isSectionHeader line =
  let trimmed = dropWhile Char.isSpace line
  in not (null trimmed) && last trimmed == ':' && not (isRowLine line)

isRowLine :: String -> Bool
isRowLine line =
  "  " `isPrefixOf` line && any (not . Char.isSpace) (drop 2 line)

parseRow :: String -> (String, String)
parseRow line =
  let trimmed = dropWhile Char.isSpace line
      (namePart, rest) = span (not . Char.isSpace) trimmed
      desc = trim (dropWhile Char.isSpace rest)
  in (namePart, desc)

trim :: String -> String
trim = dropWhileEnd Char.isSpace . dropWhile Char.isSpace

trimColon :: String -> String
trimColon = trim . reverse . dropWhile (== ':') . reverse

data ParsedHelp = ParsedHelp
  { phUsage       :: !String
  , phDescription :: ![String]
  , phSections    :: ![(String, [(String, String)])]
  }

printParagraph :: [String] -> IO ()
printParagraph lines' =
  let cleaned = dropWhile null (dropWhileEnd null lines')
      filtered = filter (not . looksLikeWrappedUsage) cleaned
  in unlessNull filtered $ do
       mapM_ putStrLn filtered
       putStrLn ""

looksLikeWrappedUsage :: String -> Bool
looksLikeWrappedUsage line =
  case dropWhile Char.isSpace line of
    '[' : _ -> True
    _       -> False
