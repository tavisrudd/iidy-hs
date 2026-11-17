{-# LANGUAGE OverloadedStrings #-}

{- | Resource limits (card C20): alias expansion (node count and expanded
size), import depth and count, Handlebars helper output and the total time
of an HTTP import. Every test carries a 10 second timeout, so a limit that
is missing shows as a timeout rather than a hang.
-}
module Test.ResourceLimitsTest (resourceLimitsTests) where

import Control.Monad (forM)
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as BL
import Data.Either (isRight)
import Data.IORef (newIORef, readIORef)
import Data.List qualified as List
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import Test.Tasty (TestTree, localOption, mkTimeout, testGroup)
import Test.Tasty.HUnit

import Test.FakeHttp (FakeNetwork (..), Reply (..), fakeSeam, newFakeNet)
import Test.ImportFixtures (preprocessText, recordingLoader, stubDocsLoader, unknownLoader)

import Iidy.Constants (
    helperMaxOutputChars,
    importMaxDepth,
    importMaxTotal,
    yamlMaxAliasNodes,
    yamlMaxExpandedBytes,
 )
import Iidy.Yaml.Engine (PreprocessError (..), PreprocessResult)
import Iidy.Yaml.Handlebars.Engine (InterpolateError (..), defaultHelpers, interpolate)
import Iidy.Yaml.Imports.Loaders.Http (loadHttpImportWithin)
import Iidy.Yaml.Imports.Loaders.HttpGuard (HttpGuard (..), HttpSeam)
import Iidy.Yaml.Imports.Types (ImportError (..), RemoteImports (..), importPolicy)
import Iidy.Yaml.Parser (parseYaml, parseYamlFile)

resourceLimitsTests :: TestTree
resourceLimitsTests =
    localOption (mkTimeout 10000000) $
        testGroup
            "ResourceLimits"
            [ testGroup "Alias expansion" aliasTests
            , testGroup "Checked-in documents" corpusTests
            , testGroup "Import depth and count" importTests
            , testGroup "Helper output" helperTests
            , testGroup "HTTP total time" httpTests
            ]

------------------------------------------------------------------------
-- Alias expansion
------------------------------------------------------------------------

{- | A document of @levels + 1@ anchored sequences: level 0 is a scalar and
each later level holds ten aliases of the one before, so the last level
expands to @(10^(levels + 1) - 1) / 9@ nodes while the text stays tiny.
-}
bombDoc :: Int -> Text
bombDoc levels =
    T.unlines $
        "d0: &l0 x"
            : [ "d" <> n i <> ": &l" <> n i <> " [" <> T.intercalate ", " (replicate 10 ("*l" <> n (i - 1))) <> "]"
              | i <- [1 .. levels]
              ]
  where
    n :: Int -> Text
    n = T.pack . show

{- | The bomb in the C4 review: level 0 a list of ten scalars, then five levels
of ten aliases each, in a few hundred bytes (over a million nodes).
-}
classicBombDoc :: Text
classicBombDoc =
    T.unlines $
        "l0: &l0 [x, x, x, x, x, x, x, x, x, x]"
            : [ "l" <> tshow i <> ": &l" <> tshow i <> " [" <> T.intercalate ", " (replicate 10 ("*l" <> tshow (i - 1))) <> "]"
              | i <- [1 .. 5]
              ]

parseText :: Text -> Either String ()
parseText doc = either (Left . show) (const (Right ())) (parseYaml (BL.fromStrict (TE.encodeUtf8 doc)) "bomb.yaml")

{- | A sequence of @copies@ aliases of one anchored scalar of 64 KiB: few
nodes, many bytes.
-}
bigScalarDoc :: Int -> Text
bigScalarDoc copies =
    T.unlines $
        ("- &big \"" <> T.replicate 65536 "x" <> "\"") : replicate (copies - 1) "- *big"

assertRejected :: String -> Either String () -> IO ()
assertRejected needle result = case result of
    Left msg -> assertBool ("expected " <> show needle <> " in: " <> take 300 msg) (needle `isInfixOfS` msg)
    Right () -> assertFailure "expected the document to be rejected"
  where
    isInfixOfS a b = T.pack a `T.isInfixOf` T.pack b

aliasTests :: [TestTree]
aliasTests =
    [ testCase "a six-level alias bomb (over the node limit) is rejected quickly" $
        assertRejected ("exceeds " <> show yamlMaxAliasNodes <> " nodes in bomb.yaml") (parseText (bombDoc 6))
    , testCase "the C4 review's bomb (ten scalars, then five levels of ten aliases) is rejected" $
        assertRejected ("exceeds " <> show yamlMaxAliasNodes <> " nodes in bomb.yaml") (parseText classicBombDoc)
    , testCase "five levels over a single scalar (123,463 nodes, under the node limit) still loads and preprocesses" $ do
        let doc = bombDoc 5
        parseText doc @?= Right ()
        result <- preprocessText (importPolicy AllowRemoteImports) unknownLoader "root.yaml" doc
        assertBool "preprocesses" (isRight result)
    , testCase "scalar text expanded to exactly the size limit loads" $
        parseText (bigScalarDoc (yamlMaxExpandedBytes `div` 65536)) @?= Right ()
    , testCase "scalar text expanded one alias past the size limit is rejected" $
        assertRejected
            ("exceeds " <> show yamlMaxExpandedBytes <> " bytes of text in bomb.yaml")
            (parseText (bigScalarDoc (yamlMaxExpandedBytes `div` 65536 + 1)))
    ]

{- | Every checked-in YAML document stays far below the node limit (the
count is the number of source-metadata records in the expanded AST, one per
node). A document that fails to parse for another reason is skipped.
-}
corpusTests :: [TestTree]
corpusTests =
    [ testCase "no fixture or example template comes near the alias node limit" $ do
        files <- concat <$> mapM yamlFilesUnder ["test-fixtures", "fixtures"]
        sizes <- mapM nodesOf files
        case List.sortOn (Down . fst) (zip sizes files) of
            [] -> assertFailure "no YAML files found (wrong working directory?)"
            (biggest, file) : _ ->
                assertBool (file <> " has " <> show biggest <> " nodes") (biggest < yamlMaxAliasNodes `div` 10)
    ]
  where
    nodesOf :: FilePath -> IO Int
    nodesOf path = do
        parsed <- parseYamlFile path
        pure (either (const 0) (length . T.breakOnAll "SrcMeta" . T.pack . show) parsed)

yamlFilesUnder :: FilePath -> IO [FilePath]
yamlFilesUnder dir = do
    entries <- listDirectory dir
    fmap concat . forM entries $ \e -> do
        let path = dir </> e
        isDir <- doesDirectoryExist path
        if isDir
            then yamlFilesUnder path
            else pure [path | takeExtension path `elem` [".yaml", ".yml"]]

------------------------------------------------------------------------
-- Import depth and count
------------------------------------------------------------------------

-- | Documents @n1.yaml@ ... @nK.yaml@; each imports the next while @more i@.
chainDocs :: Int -> (Int -> Bool) -> [(Text, Text)]
chainDocs k more =
    [ ("n" <> tshow i <> ".yaml", if more i then "$imports:\n  next: n" <> tshow (i + 1) <> ".yaml\n" else "value: 1\n")
    | i <- [1 .. k]
    ]

tshow :: Int -> Text
tshow = T.pack . show

-- | Preprocess a root document that imports from the stub documents; the second result counts loader calls.
preprocessWith :: [(Text, Text)] -> Text -> IO (Either PreprocessError PreprocessResult, Int)
preprocessWith docs root = do
    calls <- newIORef []
    result <- preprocessText (importPolicy AllowRemoteImports) (recordingLoader calls (stubDocsLoader docs unknownLoader)) "root.yaml" root
    (,) result . length <$> readIORef calls

rootImports :: [Text] -> Text
rootImports locs = "$imports:\n" <> T.concat ["  k" <> T.pack (show i) <> ": " <> l <> "\n" | (i, l) <- zip [0 :: Int ..] locs]

importMessage :: Either PreprocessError PreprocessResult -> Either String Text
importMessage = \case
    Left (PeImportError (ImportError msg)) -> Right msg
    Left other -> Left ("unexpected error: " <> show other)
    Right _ -> Left "expected the import to be refused"

importTests :: [TestTree]
importTests =
    [ testCase "a chain exactly at the depth limit loads" $ do
        (result, calls) <- preprocessWith (chainDocs importMaxDepth (< importMaxDepth)) (rootImports ["n1.yaml"])
        assertBool ("loads: " <> either show (const "") result) (isRight result)
        calls @?= importMaxDepth
    , testCase "an endless import chain is refused one level past the limit, naming the chain" $ do
        (result, calls) <- preprocessWith (chainDocs (importMaxDepth + 8) (const True)) (rootImports ["n1.yaml"])
        case importMessage result of
            Right msg -> do
                assertBool ("names limit and value: " <> T.unpack msg) ("import depth 33 exceeds 32: root.yaml" `T.isPrefixOf` msg)
                assertBool "names the chain" ("n1.yaml \8594 n2.yaml" `T.isInfixOf` msg)
            Left err -> assertFailure err
        calls @?= importMaxDepth -- the 33rd is refused before it is fetched
    , testCase "as many imports as the total limit load" $ do
        (result, _) <- preprocessWith (chainDocs importMaxTotal (const False)) (rootImports (fanOut importMaxTotal))
        assertBool "loads" (isRight result)
    , testCase "one import past the total limit is refused" $ do
        (result, _) <- preprocessWith (chainDocs (importMaxTotal + 1) (const False)) (rootImports (fanOut (importMaxTotal + 1)))
        case importMessage result of
            Right msg -> assertBool ("names limit and value: " <> T.unpack msg) ("import count 1001 exceeds 1000" `T.isPrefixOf` msg)
            Left err -> assertFailure err
    ]
  where
    fanOut :: Int -> [Text]
    fanOut k = ["n" <> tshow i <> ".yaml" | i <- [1 .. k]]

------------------------------------------------------------------------
-- Helper output
------------------------------------------------------------------------

-- | Interpolate a template with no variables, as the error text on failure.
render :: Text -> Either Text Text
render template = first (\(InterpolateError msg) -> msg) (interpolate defaultHelpers (Object KM.empty) template)

padTo :: Int -> Either Text Text
padTo width = render ("{{pad \"ab\" " <> T.pack (show width) <> " \"-\"}}")

-- | Replace each of @n@ "a" with @len@ "b" characters.
replaceOf :: Int -> Int -> Either Text Text
replaceOf n len = render ("{{replace \"" <> T.replicate n "a" <> "\" \"a\" \"" <> T.replicate len "b" <> "\"}}")

{- | @toJson@ of level @n@ of a value in which each level holds ten references
to the one below (as aliases or @$defs@ do), level 0 being 600 characters
of JSON.
-}
toJsonOf :: Int -> Either Text Text
toJsonOf n =
    first (\(InterpolateError msg) -> msg) $
        interpolate defaultHelpers (Object (KM.fromList [("v", level)])) "{{toJson v}}"
  where
    level :: Value
    level = foldr (const (Array . V.fromList . replicate 10)) (Array (V.fromList (replicate 150 (String "x")))) [1 .. n]

helperTests :: [TestTree]
helperTests =
    [ testCase "pad to a small width is unchanged" $ padTo 5 @?= Right "ab---"
    , testCase "toJson of a value that shares its parts stays small under the limit" $
        assertBool "serializes" (either (const False) ((< helperMaxOutputChars) . T.length) (toJsonOf 1))
    , testCase "toJson of a shared value that serializes past the limit errors, naming the helper" $
        case toJsonOf 4 of
            Left msg -> assertBool (T.unpack msg) ("toJson would produce" `T.isInfixOf` msg && "over the helper output limit of 1048576" `T.isInfixOf` msg)
            Right _ -> assertFailure "expected an error"
    , testCase "pad to exactly the limit loads" $
        fmap T.length (padTo helperMaxOutputChars) @?= Right helperMaxOutputChars
    , testCase "pad one character past the limit errors, naming the limit" $
        case padTo (helperMaxOutputChars + 1) of
            Left msg -> assertBool (T.unpack msg) ("over the helper output limit of 1048576" `T.isInfixOf` msg)
            Right _ -> assertFailure "expected an error"
    , testCase "pad to a huge width errors without allocating it" $
        assertBool "errors" (either (const True) (const False) (padTo 50000000))
    , testCase "replace that stays under the limit is unchanged" $
        replaceOf 3 2 @?= Right (T.replicate 3 "bb")
    , testCase "replace that would pass the limit errors, naming the limit" $
        case replaceOf 2000 1000 of
            Left msg -> assertBool (T.unpack msg) ("over the helper output limit of 1048576" `T.isInfixOf` msg)
            Right _ -> assertFailure "expected an error"
    ]

------------------------------------------------------------------------
-- HTTP total time
------------------------------------------------------------------------

-- | A fake network whose only host serves a body that never finishes.
drippingSeam :: IO HttpSeam
drippingSeam = fakeSeam network <$> newFakeNet
  where
    network = FakeNetwork{fwHosts = [], fwReplies = [(("10.0.0.1", "*"), Drip)]}

httpTests :: [TestTree]
httpTests =
    [ testCase "an HTTP import whose body drips past the total time errors" $ do
        seam <- drippingSeam
        result <- loadHttpImportWithin 1000000 seam (HttpGuard False Nothing "root.yaml") "http://10.0.0.1/doc.yaml"
        case result of
            Left (ImportError msg) -> do
                assertBool (T.unpack msg) ("total time limit of 1 seconds exceeded" `T.isInfixOf` msg)
                assertBool "names the URL" ("http://10.0.0.1/doc.yaml" `T.isInfixOf` msg)
            Right _ -> assertFailure "expected the slow import to time out"
    ]
