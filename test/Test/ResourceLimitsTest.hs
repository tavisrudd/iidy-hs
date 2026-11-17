{-# LANGUAGE OverloadedStrings #-}

{- | Resource limits (card C20): alias expansion (node count and expanded
size), import depth and count, Handlebars helper output and the total time
of an HTTP import. Every test carries a 10 second timeout, so a limit that
is missing shows as a timeout rather than a hang.
-}
module Test.ResourceLimitsTest (resourceLimitsTests) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM)
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Bifunctor (first)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Either (isRight)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.Socket qualified as NS
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import Test.Tasty (TestTree, localOption, mkTimeout, testGroup)
import Test.Tasty.HUnit

import Iidy.Constants (
    helperMaxOutputChars,
    importMaxDepth,
    importMaxTotal,
    yamlMaxAliasNodes,
    yamlMaxExpandedBytes,
 )
import Iidy.Yaml.Engine (LoadImportFn, PreprocessError (..), PreprocessResult, preprocessYaml)
import Iidy.Yaml.Handlebars.Engine (InterpolateError (..), defaultHelpers, interpolate)
import Iidy.Yaml.Imports.Loaders.Http (loadHttpImportWithin)
import Iidy.Yaml.Imports.Loaders.HttpGuard (HttpGuard (..), HttpSeam (..), RawIO (..), resolveHostWith)
import Iidy.Yaml.Imports.Types (ImportData (..), ImportError (..), ImportType (..))
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
    , testCase "a five-level alias bomb (under the node limit) still loads and preprocesses" $ do
        let doc = bombDoc 5
        parseText doc @?= Right ()
        result <- preprocessText (\_ _ -> pure (Left (ImportError "none"))) doc
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
        let (biggest, file) = maximum (zip sizes files)
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

preprocessText :: LoadImportFn -> Text -> IO (Either PreprocessError PreprocessResult)
preprocessText loader doc = case parseYaml (BL.fromStrict (TE.encodeUtf8 doc)) "root.yaml" of
    Left err -> assertFailure ("did not parse: " <> show err)
    Right ast -> preprocessYaml loader ast "root.yaml"

------------------------------------------------------------------------
-- Import depth and count
------------------------------------------------------------------------

-- | A loader serving @nI.yaml@ for every I: each imports @n(I+1).yaml@ while @more I@.
chainLoader :: IORef Int -> (Int -> Bool) -> LoadImportFn
chainLoader calls more loc _base = do
    modifyIORef' calls (+ 1)
    let i = read (T.unpack (T.dropEnd 5 (T.drop 1 loc))) :: Int
        raw
            | more i = "$imports:\n  next: n" <> T.pack (show (i + 1)) <> ".yaml\n"
            | otherwise = "value: 1\n"
    pure $
        Right
            ImportData
                { idType = ImportFile
                , idLocation = loc
                , idRawData = raw
                , idOrdered = Nothing
                , idDoc = Object (if more i then KM.fromList [("$imports", Object KM.empty)] else KM.fromList [("value", Number 1)])
                }

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
        calls <- newIORef 0
        result <- preprocessText (chainLoader calls (< importMaxDepth)) (rootImports ["n1.yaml"])
        assertBool ("loads: " <> show (either show (const "") result)) (isRight result)
        readIORef calls >>= (@?= importMaxDepth)
    , testCase "an endless import chain is refused one level past the limit, naming the chain" $ do
        calls <- newIORef 0
        result <- preprocessText (chainLoader calls (const True)) (rootImports ["n1.yaml"])
        case importMessage result of
            Right msg -> do
                assertBool ("names limit and value: " <> T.unpack msg) ("import depth 33 exceeds 32: root.yaml" `T.isPrefixOf` msg)
                assertBool "names the chain" ("n1.yaml \8594 n2.yaml" `T.isInfixOf` msg)
            Left err -> assertFailure err
        readIORef calls >>= (@?= importMaxDepth) -- the 33rd is refused before it is fetched
    , testCase "as many imports as the total limit load" $ do
        calls <- newIORef 0
        result <- preprocessText (chainLoader calls (const False)) (rootImports (fanOut importMaxTotal))
        assertBool "loads" (isRight result)
    , testCase "one import past the total limit is refused" $ do
        calls <- newIORef 0
        result <- preprocessText (chainLoader calls (const False)) (rootImports (fanOut (importMaxTotal + 1)))
        case importMessage result of
            Right msg -> assertBool ("names limit and value: " <> T.unpack msg) ("import count 1001 exceeds 1000" `T.isPrefixOf` msg)
            Left err -> assertFailure err
    ]
  where
    fanOut :: Int -> [Text]
    fanOut k = ["n" <> T.pack (show i) <> ".yaml" | i <- [1 .. k]]

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

helperTests :: [TestTree]
helperTests =
    [ testCase "pad to a small width is unchanged" $ padTo 5 @?= Right "ab---"
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

{- | A server that sends the headers at once and then drips the body one
byte every 50 ms, never finishing (no socket, no network).
-}
drippingSeam :: HttpSeam
drippingSeam = HttpSeam{hsResolve = resolveHostWith [NS.AI_NUMERICHOST], hsConnect = const connectDrip}
  where
    connectDrip = do
        sent <- newIORef False
        let readChunk = do
                headersSent <- readIORef sent
                if headersSent
                    then threadDelay 50000 >> pure "x"
                    else modifyIORef' sent (const True) >> pure (BC.pack "HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n")
        pure RawIO{rioRead = readChunk, rioWrite = \_ -> pure (), rioClose = pure ()}

httpTests :: [TestTree]
httpTests =
    [ testCase "an HTTP import whose body drips past the total time errors" $ do
        result <- loadHttpImportWithin 1000000 drippingSeam (HttpGuard False Nothing "root.yaml") "http://10.0.0.1/doc.yaml"
        case result of
            Left (ImportError msg) -> do
                assertBool (T.unpack msg) ("total time limit of 1 seconds exceeded" `T.isInfixOf` msg)
                assertBool "names the URL" ("http://10.0.0.1/doc.yaml" `T.isInfixOf` msg)
            Right _ -> assertFailure "expected the slow import to time out"
    ]
