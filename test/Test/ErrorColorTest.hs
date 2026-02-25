module Test.ErrorColorTest (errorColorTests) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Yaml.Errors.Display (formatError, defaultColors, noColors)
import Iidy.Yaml.Errors.Enhanced
import Iidy.Yaml.Errors.Ids (ErrorId(..))
import Iidy.Yaml.Location (SourceLocation(..))

-- | Shared test source and location
testSource :: Text
testSource = "line1: foo\nline2: !$ myvar\nline3: bar"

testLoc :: SourceLocation
testLoc = SourceLocation "test.yaml" 2 8 "<root>"

-- | A sample VariableNotFound error for color testing
sampleVarError :: EnhancedPreprocessingError
sampleVarError = VariableNotFoundError VariableNotFoundInfo
  { vnfErrorId       = VariableNotFound
  , vnfVariable      = "myvar"
  , vnfLocation      = testLoc
  , vnfAvailableVars = ["env", "region"]
  , vnfSuggestions   = []
  }

errorColorTests :: [TestTree]
errorColorTests =
  [ testCase "colored output contains ANSI escapes" $ do
      let output = formatError defaultColors testSource sampleVarError
      assertBool "bold red header" ("\ESC[1;31m" `T.isInfixOf` output)
      assertBool "cyan file location" ("\ESC[36m" `T.isInfixOf` output)
      assertBool "light blue guidance" ("\ESC[38;5;75m" `T.isInfixOf` output)
      assertBool "red carets" ("\ESC[31m" `T.isInfixOf` output)
      assertBool "dark grey line numbers" ("\ESC[90m" `T.isInfixOf` output)
      assertBool "reset codes present" ("\ESC[0m" `T.isInfixOf` output)

  , testCase "noColors output has no ANSI escapes" $ do
      let output = formatError noColors testSource sampleVarError
      assertBool "no ESC in output" (not $ "\ESC[" `T.isInfixOf` output)

  , testCase "footer uses light blue (not grey)" $ do
      let output = formatError defaultColors testSource sampleVarError
          footer = case reverse (T.lines output) of
                     (x:_) -> x
                     []    -> error "expected non-empty output"
      assertBool "footer has light blue" ("\ESC[38;5;75m" `T.isInfixOf` footer)
      assertBool "footer has no grey" (not $ "\ESC[38;5;245m" `T.isInfixOf` footer)

  , testCase "available variables line is fully colored" $ do
      let output = formatError defaultColors testSource sampleVarError
          avLine = case filter ("available variables" `T.isInfixOf`) (T.lines output) of
                     (x:_) -> x
                     []    -> error "expected 'available variables' line"
      assertBool "light blue before label" ("\ESC[38;5;75m" `T.isInfixOf` avLine)
      assertBool "reset after vars" ("\ESC[0m" `T.isInfixOf` avLine)
      let afterLabel = snd $ T.breakOn "available variables: " avLine
      let resetCount = length $ T.splitOn "\ESC[0m" afterLabel
      assertEqual "single reset at end of vars" 2 resetCount

  , testCase "type mismatch help is colored" $ do
      let err = TypeMismatchError TypeMismatchInfo
            { tmiErrorId  = TypeMismatchInOperation
            , tmiExpected = "array"
            , tmiFound    = "string"
            , tmiLocation = testLoc
            , tmiContext  = "test"
            , tmiHelp     = Just "try using !$split"
            }
          output = formatError defaultColors testSource err
          helpLines = filter ("try using" `T.isInfixOf`) (T.lines output)
      case helpLines of
        (hl:_) -> assertBool "help is colored" ("\ESC[38;5;75m" `T.isInfixOf` hl)
        []     -> assertFailure "expected help line"

  , testCase "syntax error fix hint is colored" $ do
      let err = YamlSyntaxError YamlSyntaxInfo
            { ysiErrorId      = InvalidYamlSyntax
            , ysiShortMessage = "bad syntax"
            , ysiGuidance     = "check your yaml"
            , ysiLocation     = testLoc
            , ysiFixHint      = Just "add a colon"
            , ysiExample      = Just "key: value"
            }
          output = formatError defaultColors testSource err
          fixLines = filter ("fix:" `T.isInfixOf`) (T.lines output)
          exLines = filter ("example:" `T.isInfixOf`) (T.lines output)
      case (fixLines, exLines) of
        (fl:_, el:_) -> do
          assertBool "fix is colored" ("\ESC[38;5;75m" `T.isInfixOf` fl)
          assertBool "example is colored" ("\ESC[38;5;75m" `T.isInfixOf` el)
        _ -> assertFailure "expected fix and example lines"

  , testCase "inline description on caret line is colored grey" $ do
      let output = formatError defaultColors testSource sampleVarError
          caretLines = filter ("^" `T.isInfixOf`) (T.lines output)
      case caretLines of
        (caretLine:_) ->
          assertBool "inline desc has grey" ("\ESC[38;5;245m" `T.isInfixOf` caretLine)
        [] -> assertFailure "expected caret line"
  ]
