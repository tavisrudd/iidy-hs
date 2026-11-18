{- | Running a stack-args file's @CommandsBefore@ (card C40, Option E of
@notes/C40/report--commands-before-design.org@).

Rust (@src/cfn/stack_args.rs:493-660@) and iidy-js
(@src/cfn/runCommandSet.ts:11-67@) run each entry through bash in the
argsfile's directory before any CloudFormation call. iidy-hs does the same
for the four operations that run them, with these rules:

* Entries are strings written in the argsfile (the loader refuses any
  other, "Iidy.Cfn.StackArgs.Credentials").
* Each is a Handlebars template over the iidy-js context: @iidy.*@, bare
  @region@ and @environment@, and every @$defs@ and @$imports@ name; every
  value it substitutes must pass "Iidy.Cfn.CommandsBefore.Expand".
* Every command is expanded once with the file hashes stubbed before the
  first one runs (the dry run), so a refused value runs nothing; then each
  is expanded again just before it runs, so @filehash@ sees what earlier
  commands built.
* Output is streamed; in json output mode the banners and the child's
  stdout go to stderr. Stdin is inherited only from a terminal.
-}
module Iidy.Cfn.CommandsBefore (
    -- * Settings from the command line
    CommandsBeforeSettings (..),
    CommandOutput (..),
    commandOutputOn,
    commandOutputFor,
    defaultCommandsBeforeSettings,

    -- * Running
    runsCommandsBefore,
    CommandsBeforeInput (..),
    runCommandsBefore,

    -- * Internal (exported for testing)
    commandEnvironment,
) where

import Control.Applicative ((<|>))
import Control.Exception (bracket)
import Control.Monad (forM, forM_, unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Bifunctor (first)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import GHC.IO.Handle (hDuplicate)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.IO (Handle, IOMode (..), hClose, hFlush, stderr, stdout, withFile)
import System.Process (CreateProcess (..), StdStream (..))

import Iidy.Cfn.CommandsBefore.Expand (CommandContext (..), HashMode (..), expandCommand)
import Iidy.Cfn.Types (CfnOperation (..), cfnOperationStr)
import Iidy.ShellRunner (bashProcess, exitDescription, runToExit)
import Iidy.Yaml.Ast (YamlAst (..))
import Iidy.Yaml.OValue (OValue, toValue)

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------

{- | Where the banners and the child's output go. Child stderr always goes
to 'coStderr'; banners and child stdout go to 'coStdout'.
-}
data CommandOutput = CommandOutput
    { coStdout :: !Handle
    , coStderr :: !Handle
    }

{- | The output for the given stdout and stderr handles: in json output
mode (third argument) 'coStdout' is the stderr handle, so stdout stays
valid JSON.
-}
commandOutputOn :: Handle -> Handle -> Bool -> CommandOutput
commandOutputOn out err json = CommandOutput{coStdout = if json then err else out, coStderr = err}

-- | 'commandOutputOn' the process's stdout and stderr.
commandOutputFor :: Bool -> CommandOutput
commandOutputFor = commandOutputOn stdout stderr

-- | What the command line decides about running the commands.
data CommandsBeforeSettings = CommandsBeforeSettings
    { cbsOutput :: !CommandOutput
    , cbsStackName :: !(Maybe Text)
    -- ^ the stack name given on the command line (@iidy.stackName@ prefers it)
    , cbsResolveRegion :: Maybe Text -> IO (Maybe Text)
    {- ^ the region the AWS environment is built with, from the merged
    stack-args region (iidy-js @getCurrentAWSRegion()@,
    @loadStackArgs.ts:124@)
    -}
    , cbsStdinIsTerminal :: !Bool
    -- ^ inherit stdin only when it is a terminal; otherwise @/dev/null@
    }

{- | Plain output on the process's handles, no stack name from the command
line, the merged region as is, stdin from @/dev/null@.
-}
defaultCommandsBeforeSettings :: CommandsBeforeSettings
defaultCommandsBeforeSettings =
    CommandsBeforeSettings
        { cbsOutput = commandOutputFor False
        , cbsStackName = Nothing
        , cbsResolveRegion = pure
        , cbsStdinIsTerminal = False
        }

-- | The operations Rust and iidy-js run @CommandsBefore@ for.
runsCommandsBefore :: CfnOperation -> Bool
runsCommandsBefore = \case
    OpCreateStack -> True
    OpUpdateStack -> True
    OpCreateChangeset -> True
    OpCreateOrUpdate -> True
    _other -> False

------------------------------------------------------------------------
-- Running
------------------------------------------------------------------------

-- | What the loader knows when the commands run.
data CommandsBeforeInput = CommandsBeforeInput
    { cbiArgsfile :: !FilePath
    , cbiRawAst :: !YamlAst
    -- ^ the argsfile as written, for naming @$defs@ and @$imports@
    , cbiCommands :: ![Text]
    -- ^ the entries as written
    , cbiOperation :: !CfnOperation
    , cbiEnvironment :: !Text
    , cbiProfile :: !(Maybe Text)
    -- ^ the merged profile
    , cbiRegion :: !(Maybe Text)
    -- ^ the merged region, before 'cbsResolveRegion'
    , cbiStackArgs :: !Value
    -- ^ the stack-args document preprocessed without @CommandsBefore@
    , cbiVariables :: !(Map Text OValue)
    -- ^ its @$defs@ and @$imports@ values
    }

{- | Check, dry-run, then run every command in order; the expanded text of
each, or why the load must stop. Nothing runs unless every command passes
the dry run.
-}
runCommandsBefore :: CommandsBeforeSettings -> CommandsBeforeInput -> IO (Either Text [Text])
runCommandsBefore settings input = runExceptT $ do
    case filter (`Map.member` cbiVariables input) builtinNames of
        [] -> pure ()
        name : _ -> throwE (inArgsfile (clashMessage name))
    region <- lift (cbsResolveRegion settings (cbiRegion input))
    let cc =
            CommandContext
                { ccArgsfile = cbiArgsfile input
                , ccValues = commandValues settings input region
                , ccSourceOf = describeSource (cbiRawAst input)
                }
        numbered = zip [0 ..] (cbiCommands input)
    forM_ numbered $ \(i, command) -> ExceptT (first inArgsfile <$> expandCommand cc StubHashes i command)
    inherited <- lift getEnvironment
    let envList = commandEnvironment inherited (cbiProfile input) (fromMaybe "" region) (cbiEnvironment input)
    banner ("== Executing CommandsBefore from argsfile " <> T.replicate 28 "=")
    expanded <- forM numbered $ \(i, command) -> do
        text <- ExceptT (first inArgsfile <$> expandCommand cc HashFiles i command)
        runOne envList i command text
        pure text
    banner ("\n== End CommandsBefore " <> T.replicate 48 "=" <> "\n")
    pure expanded
  where
    out = cbsOutput settings
    banner = lift . TIO.hPutStrLn (coStdout out)
    inArgsfile err = "In " <> T.pack (cbiArgsfile input) <> ", " <> err
    runOne envList i command text = do
        banner ("\n-- Command " <> T.pack (show (i + 1)) <> " " <> T.replicate 50 "-")
        if text /= command
            then
                mapM_
                    banner
                    [ "# raw command before processing handlebars variables:"
                    , command
                    , "# command after processing handlebars variables:"
                    , text
                    ]
            else banner command
        banner ("-- Command " <> T.pack (show (i + 1)) <> " Output " <> T.replicate 25 "-")
        code <- lift (runShell settings (takeDirectory (cbiArgsfile input)) envList text)
        unless (code == ExitSuccess) $
            throwE ("Error running command (" <> exitDescription code <> "):\n" <> command)

-- | Run one expanded command with the settings' streams.
runShell :: CommandsBeforeSettings -> FilePath -> [(String, String)] -> Text -> IO ExitCode
runShell settings dir envList text = do
    hFlush (coStdout out)
    hFlush (coStderr out)
    withStdin $ \stdinStream ->
        bracket (hDuplicate (coStdout out)) hClose $ \childOut ->
            bracket (hDuplicate (coStderr out)) hClose $ \childErr ->
                runToExit
                    (bashProcess text dir envList)
                        { std_in = stdinStream
                        , std_out = UseHandle childOut
                        , std_err = UseHandle childErr
                        }
  where
    out = cbsOutput settings
    withStdin act
        | cbsStdinIsTerminal settings = act Inherit
        | otherwise = withFile "/dev/null" ReadMode (act . UseHandle)

------------------------------------------------------------------------
-- Context
------------------------------------------------------------------------

-- | The names the context defines itself.
builtinNames :: [Text]
builtinNames = ["iidy", "region", "environment"]

clashMessage :: Text -> Text
clashMessage name =
    "the $defs or $imports name "
        <> name
        <> " clashes with the built-in CommandsBefore context name "
        <> name
        <> " (one of "
        <> T.intercalate ", " builtinNames
        <> "); rename it"

-- | The Handlebars context of the commands.
commandValues :: CommandsBeforeSettings -> CommandsBeforeInput -> Maybe Text -> Value
commandValues settings input region =
    Object (KM.union builtins (KM.fromList [(Key.fromText k, toValue v) | (k, v) <- Map.toList (cbiVariables input)]))
  where
    stackName = cbsStackName settings <|> fileStackName (cbiStackArgs input)
    optional key = maybe [] (\v -> [(key, String v)])
    iidy =
        KM.fromList $
            [ ("command", String (cfnOperationStr (cbiOperation input)))
            , ("environment", String (cbiEnvironment input))
            , ("stackArgs", cbiStackArgs input)
            ]
                <> optional "region" region
                <> optional "profile" (cbiProfile input)
                <> optional "stackName" stackName
    builtins =
        KM.fromList $
            [("iidy", Object iidy), ("environment", String (cbiEnvironment input))]
                <> optional "region" region

fileStackName :: Value -> Maybe Text
fileStackName = \case
    Object o | Just (String s) <- KM.lookup "StackName" o -> Just s
    _other -> Nothing

-- | Name a context name's source for refusal messages.
describeSource :: YamlAst -> Text -> Text
describeSource ast name
    | name `elem` sectionNames "$defs" = "the $defs name " <> name
    | name `elem` sectionNames "$imports" = "the $imports name " <> name
    | name == "iidy" = "the built-in iidy namespace"
    | name `elem` builtinNames = "the built-in name " <> name
    | otherwise = "the name " <> name <> ", which is not defined"
  where
    sectionNames section = case ast of
        AstMapping pairs _ ->
            concat [plainKeys v | (AstPlainString k _, v) <- pairs, k == section]
        _other -> []
    plainKeys = \case
        AstMapping pairs _ -> mapMaybe (plainKey . fst) pairs
        _other -> []
    plainKey = \case
        AstPlainString k _ -> Just k
        _other -> Nothing

------------------------------------------------------------------------
-- Environment
------------------------------------------------------------------------

{- | The command's environment: the inherited one with the @iidy_*@
variables and the three bash helper functions set over it (Rust order,
@stack_args.rs:613-634@, so an inherited @iidy_region@ cannot override the
real one). The helpers are Rust's, byte for byte.
-}
commandEnvironment :: [(String, String)] -> Maybe Text -> Text -> Text -> [(String, String)]
commandEnvironment inherited profile region environment =
    Map.toList (Map.union (Map.fromList ours) (Map.fromList inherited))
  where
    ours =
        [ ("iidy_profile", T.unpack (fromMaybe "" profile))
        , ("iidy_region", T.unpack region)
        , ("iidy_environment", T.unpack environment)
        , ("BASH_FUNC_iidy_filehash%%", "() {   shasum -p -a 256 \"$1\" | cut -f 1 -d ' '; }")
        , ("BASH_FUNC_iidy_filehash_base64%%", "() { shasum -p -a 256 \"$1\" | cut -f 1 -d ' ' | xxd -r -p | base64; }")
        , ("BASH_FUNC_iidy_s3_upload%%", s3UploadFunction)
        ]

s3UploadFunction :: String
s3UploadFunction =
    unlines
        [ "() {"
        , "  echo '>> NOTE: iidy_s3_upload is an experimental addition to iidy. It might be removed in future versions.'"
        , "  FILE=$1"
        , "  BUCKET=$2"
        , "  S3_KEY=$3"
        , "  aws --profile \"$iidy_profile\" --region \"$iidy_region\" s3api head-object --bucket \"$BUCKET\" --key \"$S3_KEY\" 2>&1 >/dev/null || \\"
        , "        aws --profile \"$iidy_profile\" --region \"$iidy_region\" s3 cp \"$FILE\" \"s3://$BUCKET/$S3_KEY\";"
        , ""
        ]
        <> " }"
