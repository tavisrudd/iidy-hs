{- | CommandsBefore: the value check and the per-command expansion
("Iidy.Cfn.CommandsBefore.Expand").
-}
module Test.CommandsBeforeTest (commandsBeforeTests) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Cfn.CommandsBefore (commandEnvironment)
import Iidy.Cfn.CommandsBefore.Expand (
    CommandContext (..),
    HashMode (..),
    expandCommand,
    valueProblem,
 )

commandsBeforeTests :: [TestTree]
commandsBeforeTests =
    [ testGroup "value check" valueCheckTests
    , testGroup "expandCommand" expandTests
    , testCase "the iidy_* variables and helpers are set over the inherited environment" $ do
        let env = commandEnvironment [("iidy_region", "inherited"), ("PATH", "/bin"), ("iidy_profile", "p0")] Nothing "us-east-1" "dev"
        lookup "iidy_region" env @?= Just "us-east-1"
        lookup "iidy_environment" env @?= Just "dev"
        lookup "iidy_profile" env @?= Just ""
        lookup "PATH" env @?= Just "/bin"
        length [() | ("iidy_region", _) <- env] @?= 1
        assertBool "helpers defined" (all (\k -> isJust (lookup k env)) ["BASH_FUNC_iidy_filehash%%", "BASH_FUNC_iidy_filehash_base64%%", "BASH_FUNC_iidy_s3_upload%%"])
    ]

valueCheckTests :: [TestTree]
valueCheckTests =
    [ testCase "hashes, names, ARNs and paths pass" $
        mapM_
            (\v -> valueProblem v @?= Nothing)
            [ "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            , "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ="
            , "my-bucket.example"
            , "arn:aws:iam::123456789012:role/deploy"
            , "us-east-1"
            , "dist/app_v1.zip"
            , "user@example.com"
            , "a=b,c=d"
            , "50%"
            , "x-"
            ]
    , testCase "each shell metacharacter class is refused" $
        mapM_
            (\v -> assertBool ("refused: " <> show v) (isJust (valueProblem v)))
            [ "a b"
            , "a'b"
            , "a\"b"
            , "a$b"
            , "a`b`"
            , "a;b"
            , "a|b"
            , "a&b"
            , "a<b"
            , "a>b"
            , "a\nb"
            , "a\tb"
            , "a*"
            , "a?"
            , "a[b]"
            , "a{b}"
            , "a(b)"
            , "a\\b"
            , "a~b"
            , "a#b"
            , "a!b"
            , "caf\233"
            ]
    , testCase "a value starting with - is refused" $
        valueProblem "-rf" @?= Just "starts with -"
    , testCase "an empty value is refused" $
        valueProblem "" @?= Just "is empty"
    , testCase "the problem names the character" $ do
        valueProblem "a b" @?= Just "contains a space"
        valueProblem "a\nb" @?= Just "contains a newline"
        valueProblem "a;b" @?= Just "contains the character ';'"
    ]

expandTests :: [TestTree]
expandTests =
    [ testCase "a def, an import by name and iidy.region expand" $
        withContext $ \cc -> do
            r <- expandCommand cc HashFiles 0 "aws s3 cp out.zip s3://{{ params.bucket }}/{{iidy.region}}/{{ name }}"
            r @?= Right "aws s3 cp out.zip s3://my-bucket/us-east-1/svc"
    , testCase "literal text is the operator's and is not checked" $
        withContext $ \cc -> do
            r <- expandCommand cc HashFiles 0 "echo 'a b' | tr a-z A-Z; ls *"
            r @?= Right "echo 'a b' | tr a-z A-Z; ls *"
    , testCase "an unsafe value is refused, naming entry, expression and source" $
        withContext $ \cc -> do
            r <- expandCommand cc HashFiles 1 "echo {{params.spaced}}"
            case r of
                Right t -> assertFailure ("expected a refusal, got " <> T.unpack t)
                Left err -> do
                    let mentions t = assertBool ("mentions " <> T.unpack t <> ": " <> T.unpack err) (t `T.isInfixOf` err)
                    mentions "CommandsBefore[1]"
                    mentions "{{params.spaced}}"
                    mentions "the $imports name params"
                    mentions "contains a space"
    , testCase "a helper result is checked too" $
        withContext $ \cc -> do
            r <- expandCommand cc HashFiles 0 "echo {{concat 'a ' name}}"
            assertRefused "contains a space" r
    , testCase "filehash hashes the file relative to the argsfile" $
        withContext $ \cc -> do
            writeFile (takeDir cc </> "app.zip") "hello"
            r <- expandCommand cc HashFiles 0 "up app-{{filehash 'app.zip'}}.zip {{filehashBase64 \"app.zip\"}}"
            r @?= Right ("up app-" <> helloHex <> ".zip " <> helloB64)
    , testCase "the dry run stubs filehash and needs no file" $
        withContext $ \cc -> do
            r <- expandCommand cc StubHashes 0 "up {{filehash 'missing.zip'}} {{filehashBase64 'missing.zip'}}"
            r @?= Right ("up " <> T.replicate 64 "0" <> " " <> T.replicate 43 "A" <> "=")
    , testCase "filehash of a missing file fails" $
        withContext $ \cc -> do
            r <- expandCommand cc HashFiles 0 "up {{filehash 'missing.zip'}}"
            assertRefused "missing.zip" r
    , testCase "filehash with a non-literal path is refused, in the dry run too" $
        withContext $ \cc ->
            mapM_
                ( \mode -> do
                    r <- expandCommand cc mode 2 "up {{filehash params.bucket}}"
                    assertRefused "CommandsBefore[2]" r
                    assertRefused "literal" r
                )
                [StubHashes, HashFiles]
    , testCase "filehash only as a whole output: an argument or block condition is refused" $
        withContext $ \cc ->
            mapM_
                ( \command -> do
                    r <- expandCommand cc StubHashes 0 command
                    assertRefused "whole output" r
                )
                [ "echo {{#unless (eq (filehash 'f') '0000')}}{{params.spaced}}{{/unless}}"
                , "echo {{concat 'a-' (filehash 'f')}}"
                , "echo {{#if (filehashBase64 'f')}}x{{/if}}"
                ]
    , testCase "a template error names the entry" $
        withContext $ \cc -> do
            r <- expandCommand cc StubHashes 3 "echo {{unknownHelper x y}}"
            assertRefused "CommandsBefore[3]" r
    ]
  where
    helloHex :: Text
    helloHex = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    helloB64 :: Text
    helloB64 = "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ="
    takeDir :: CommandContext -> FilePath
    takeDir = takeDirectory . ccArgsfile

assertRefused :: Text -> Either Text Text -> Assertion
assertRefused needle = \case
    Right t -> assertFailure ("expected a refusal mentioning " <> T.unpack needle <> ", got " <> T.unpack t)
    Left err -> assertBool ("mentions " <> T.unpack needle <> ": " <> T.unpack err) (needle `T.isInfixOf` err)

-- | A context like the loader's, with an argsfile in a fresh directory.
withContext :: (CommandContext -> IO a) -> IO a
withContext act = withSystemTempDirectory "iidy-commands-before" $ \dir ->
    act
        CommandContext
            { ccArgsfile = dir </> "stack-args.yaml"
            , ccValues = values
            , ccSourceOf = \case
                "params" -> "the $imports name params"
                "name" -> "the $defs name name"
                other -> other
            }
  where
    values :: Value
    values =
        Object $
            KM.fromList
                [ ("params", Object (KM.fromList [("bucket", String "my-bucket"), ("spaced", String "a b")]))
                , ("name", String "svc")
                , ("iidy", Object (KM.fromList [("region", String "us-east-1")]))
                ]
