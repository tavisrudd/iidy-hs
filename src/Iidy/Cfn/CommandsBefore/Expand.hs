{- | Expanding one @CommandsBefore@ entry: the iidy-js Handlebars expansion
(@src/cfn/runCommandSet.ts:16-20@) with every substituted value checked
against a safe character set (card C40, Option E of
@notes/C40/report--commands-before-design.org@).

The entry's literal text is the operator's and is used as written. Each
value a @{{ ... }}@ puts into the command, helper results included, must be
a non-empty string of letters, digits and @. _ / : \@ + = , % -@ that does
not start with @-@; any other value refuses the command, and is never
quoted or rewritten. So a value cannot end the command, start another, open
a substitution, glob, split into extra words, or pass itself as an option.
-}
module Iidy.Cfn.CommandsBefore.Expand (
    CommandContext (..),
    HashMode (..),
    expandCommand,
    valueProblem,
    safeValueRule,
) where

import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Data.Aeson (Value)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Iidy.Yaml.Handlebars.Engine (HelperCall (..), InterpolateError (..), OutputSite (..), defaultHelpers, helperCallArgs, interpolateChecked)
import Iidy.Yaml.Handlebars.Helpers (fileHashHelperNames, fileHashHelpers)
import Iidy.Yaml.Imports.Loaders.File (loadFilehashImport)
import Iidy.Yaml.Imports.Types (ImportData (..), ImportError (..))

-- | What a command expands against.
data CommandContext = CommandContext
    { ccArgsfile :: !FilePath
    -- ^ the stack-args file; @filehash@ paths are relative to its directory
    , ccValues :: !Value
    -- ^ the Handlebars context
    , ccSourceOf :: Text -> Text
    {- ^ describes a context name for messages, for example
    "the $imports name params"
    -}
    }

{- | 'StubHashes' for the dry run before any command runs (the files may
not exist yet); 'HashFiles' just before the command runs.
-}
data HashMode = StubHashes | HashFiles
    deriving stock (Show, Eq)

{- | Expand the entry with the given index (counted from 0, as in
@CommandsBefore[0]@), or say why it is refused.
-}
expandCommand :: CommandContext -> HashMode -> Int -> Text -> IO (Either Text Text)
expandCommand cc mode index command = runExceptT $ do
    paths <- either (throwE . inEntry) pure (literalHashPaths command)
    hashes <- Map.fromList <$> traverse hashOne paths
    let helpers = Map.union (fileHashHelpers (\name path -> Map.lookup (name, path) hashes)) defaultHelpers
    case interpolateChecked (checkValue cc) helpers (ccValues cc) command of
        Left (InterpolateError err) -> throwE (inEntry err)
        Right expanded -> pure expanded
  where
    inEntry err = entryName index <> ": " <> err
    hashOne key@(name, path) = case mode of
        StubHashes -> pure (key, stubHash name)
        HashFiles -> do
            loaded <- lift (loadFilehashImport ("filehash:" <> path) (T.pack (ccArgsfile cc)) (name /= "filehash"))
            case loaded of
                Left (ImportError err) -> throwE (inEntry ("{{" <> name <> "}}: " <> err))
                Right imported -> pure (key, idRawData imported)

-- | How messages name an entry.
entryName :: Int -> Text
entryName index = "CommandsBefore[" <> T.pack (show index) <> "]"

{- | The literal path of every file hash helper call, keyed by helper name.
A call must be the whole of a @{{ ... }}@ output with one literal path: as
a helper argument, sub-expression or block condition its result could make
the real expansion render something the dry run did not check, so it is
refused, as is a computed path.
-}
literalHashPaths :: Text -> Either Text [(Text, Text)]
literalHashPaths command = concat <$> traverse pathsOf fileHashHelperNames
  where
    pathsOf name = case helperCallArgs name command of
        Left (InterpolateError err) -> Left err
        Right calls -> traverse (literalPath name) calls
    literalPath name call
        | not (hcWholeOutput call) =
            Left $
                "{{"
                    <> name
                    <> "}} is allowed only as a whole output, as in "
                    <> example name
                    <> "; it is refused as a helper argument, sub-expression or block condition, where the dry run with stand-in hashes could render something else"
        | otherwise = case hcArgs call of
            [Just path] -> Right (name, path)
            _computed ->
                Left $
                    "{{"
                        <> name
                        <> "}} takes one literal path in quotes, for example "
                        <> example name
                        <> "; a computed path is refused"
    example name = "{{" <> name <> " \"dist/app.zip\"}}"

-- | A stand-in hash of the right form, for the dry run.
stubHash :: Text -> Text
stubHash = \case
    "filehash" -> T.replicate 64 "0"
    _base64 -> T.replicate 43 "A" <> "="

-- | The output check: refuse a value that is not safe in shell text.
checkValue :: CommandContext -> OutputSite -> Text -> Either Text ()
checkValue cc site value = case valueProblem value of
    Nothing -> Right ()
    Just problem ->
        Left $
            "the value of {{"
                <> osExpression site
                <> "}}"
                <> sources
                <> " "
                <> problem
                <> ". "
                <> safeValueRule
  where
    sources = case osRoots site of
        [] -> ""
        roots -> " (" <> T.intercalate ", " (map (ccSourceOf cc) roots) <> ")"

-- | The rule, with what to do instead, for refusal messages.
safeValueRule :: Text
safeValueRule =
    "A value substituted into a CommandsBefore command must be a non-empty string of letters, digits and . _ / : @ + = , % - that does not start with -; iidy-hs refuses any other value instead of quoting it. Have the command read such a value itself, for example from an environment variable or with the aws CLI."

{- | Why a value may not be substituted into a command, or 'Nothing' when
it may.
-}
valueProblem :: Text -> Maybe Text
valueProblem value
    | T.null value = Just "is empty"
    | T.isPrefixOf "-" value = Just "starts with -"
    | otherwise = describe <$> T.find (not . safeChar) value
  where
    describe = \case
        ' ' -> "contains a space"
        '\n' -> "contains a newline"
        '\t' -> "contains a tab"
        c -> "contains the character " <> T.pack (show c)

-- | The safe character set: ASCII letters and digits and @._/:\@+=,%-@.
safeChar :: Char -> Bool
safeChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("._/:@+=,%-" :: String)
