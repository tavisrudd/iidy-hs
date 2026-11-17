{- | Regression tests for the import trust gate (card C14).

A parent document is trusted (may use the local-only import types) only
when its base location is positively a local file. Every other base
spelling, including the short @s3:bucket/key@ form and the @ssm:@,
@ssm-path:@ and @cfn:@ loaders, is untrusted. The tests are table driven:
each untrusted base is crossed with each local-only import.
-}
module Test.ImportTrustTest (importTrustTests) where

import Data.ByteString.Lazy qualified as BL
import Data.IORef (readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Iidy.Yaml.Engine (LoadImportFn, PreprocessError (..), preprocessYaml)
import Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher, mkImportConfig)
import Iidy.Yaml.Imports.Types (
    ImportError (..),
    ImportType (..),
    RemoteImports (..),
    importPolicy,
    parseImportType,
    rootBase,
 )
import Iidy.Yaml.Parser (parseYaml)
import Test.ImportFixtures (stubDocLoader)
import Test.MockAws (MockAws (..), newMockAws)

importTrustTests :: [TestTree]
importTrustTests =
    [ testGroup "untrusted parent rejects local-only import" untrustedMatrix
    , testGroup "untrusted parent keeps random and HTTP imports" untrustedAllowedMatrix
    , testGroup "untrusted parent rejects AWS-backed import" untrustedAwsMatrix
    , testGroup "local parent imports every type" localMatrix
    , testGroup "dispatcher refuses local-only import from untrusted parent" dispatcherMatrix
    , testGroup "nested import from remote document" nestedMatrix
    ]

------------------------------------------------------------------------
-- Tables
------------------------------------------------------------------------

{- | Base locations that must be untrusted, by the spelling under test.
@a:b.yaml@ is a local file name, but its prefix is scheme shaped, so it
stays untrusted (supervisor's call on C14).
-}
untrustedBases :: [Text]
untrustedBases =
    [ "s3:bucket/dir/parent.yaml"
    , "s3://bucket/dir/parent.yaml"
    , "ssm:/app/parent"
    , "ssm-path:/app"
    , "cfn:export/ParentExport"
    , "http://example.com/parent.yaml"
    , "https://example.com/parent.yaml"
    , "S3://bucket/parent.yaml"
    , "ftp://example.com/parent.yaml"
    , "a:b.yaml"
    ]

-- | Local-only imports in every spelling a template can write them, typed.
localOnlyTyped :: [(Text, ImportType)]
localOnlyTyped =
    [ ("file:data.yaml", ImportFile)
    , ("data.yaml", ImportFile)
    , ("./data.yaml", ImportFile)
    , ("../data.yaml", ImportFile)
    , ("/abs/data.yaml", ImportFile)
    , ("env:HOME", ImportEnv)
    , ("git:branch", ImportGit)
    , ("filehash:data.txt", ImportFilehash)
    , ("filehash-base64:data.txt", ImportFilehashBase64)
    ]

localOnlyImports :: [Text]
localOnlyImports = map fst localOnlyTyped

-- | Imports that are neither local-only nor AWS-backed.
openImports :: [(Text, ImportType)]
openImports =
    [ ("random:name", ImportRandom)
    , ("http://example.com/data.yaml", ImportHttp)
    , ("https://example.com/data.yaml", ImportHttp)
    ]

-- | AWS-backed imports (read with the user's credentials), typed.
awsBackedImports :: [(Text, ImportType)]
awsBackedImports =
    [ ("s3:bucket/data.yaml", ImportS3)
    , ("s3://bucket/data.yaml", ImportS3)
    , ("cfn:export/Foo", ImportCfn)
    , ("ssm:/param", ImportSsm)
    , ("ssm-path:/path", ImportSsmPath)
    ]

-- | Imports that are not local-only, with their classified type.
nonLocalImports :: [(Text, ImportType)]
nonLocalImports = openImports <> awsBackedImports

-- | Every import, local-only or not, with its classified type.
allImports :: [(Text, ImportType)]
allImports = localOnlyTyped <> nonLocalImports

{- | Base locations a local template is loaded from today.
@dir/./c:d.yaml@ is what the file loader produces when @dir/x.yaml@
imports @./c:d.yaml@: its prefix before the colon is not a URI scheme.
-}
localBases :: [Text]
localBases =
    [ "stack-args.yaml"
    , "dir/stack-args.yaml"
    , "./stack-args.yaml"
    , "../stack-args.yaml"
    , "/abs/stack-args.yaml"
    , "file:stack-args.yaml"
    , "dir/./c:d.yaml"
    , "."
    , "-"
    , ""
    ]

------------------------------------------------------------------------
-- Pure classification
------------------------------------------------------------------------

untrustedMatrix :: [TestTree]
untrustedMatrix =
    [ testCase (caseName base loc) $ assertRejected (parseImportType loc base)
    | base <- untrustedBases
    , loc <- localOnlyImports
    ]

untrustedAllowedMatrix :: [TestTree]
untrustedAllowedMatrix =
    [ testCase (caseName base loc) $ parseImportType loc base @?= Right ty
    | base <- untrustedBases
    , (loc, ty) <- openImports
    ]

{- | The decided C15 change: through the real dispatcher, with a mock AWS
environment present, an untrusted base cannot import an AWS-backed type,
and no AWS request is made.
-}
untrustedAwsMatrix :: [TestTree]
untrustedAwsMatrix =
    [ testCase (caseName base loc) $ do
        mock <- newMockAws
        result <- mkFullDispatcher (mkImportConfig (Just (mockEnv mock)) (importPolicy AllowRemoteImports)) loc (rootBase base)
        assertRejected result
        readIORef (mockRequests mock) >>= (@?= [])
    | base <- untrustedBases
    , (loc, _ty) <- awsBackedImports
    ]

localMatrix :: [TestTree]
localMatrix =
    [ testCase (caseName base loc) $ parseImportType loc base @?= Right ty
    | base <- localBases
    , (loc, ty) <- allImports
    ]

------------------------------------------------------------------------
-- Dispatcher: the gate runs before any loader touches the environment
------------------------------------------------------------------------

dispatcherMatrix :: [TestTree]
dispatcherMatrix =
    [ testCase (caseName base loc) $
        mkFullDispatcher (mkImportConfig Nothing (importPolicy AllowRemoteImports)) loc (rootBase base)
            >>= assertRejected
    | base <- untrustedBases
    , loc <- localOnlyImports
    ]

------------------------------------------------------------------------
-- Engine: a document served by a remote loader carries that loader's
-- location as the base of its own imports.
------------------------------------------------------------------------

-- | Locations at which the stub loader serves a hostile document.
remoteDocLocations :: [Text]
remoteDocLocations =
    [ "s3:bucket/evil.yaml"
    , "s3://bucket/evil.yaml"
    , "ssm:/evil"
    , "ssm-path:/evil"
    , "cfn:export/Evil"
    , "https://example.com/evil.yaml"
    ]

nestedMatrix :: [TestTree]
nestedMatrix =
    [ testCase (T.unpack remoteLoc) $ do
        let root = "$imports:\n  remote: \"" <> remoteLoc <> "\"\nout: ok\n"
        case parseYaml (BL.fromStrict (TE.encodeUtf8 root)) "local.yaml" of
            Left err -> assertFailure ("root template did not parse: " <> show err)
            Right ast ->
                preprocessYaml (hostileStub remoteLoc) ast "local.yaml" >>= \case
                    Left (PeImportError err) -> assertRejected (Left err :: Either ImportError ())
                    Left other -> assertFailure ("expected trust-gate error, got " <> show other)
                    Right _ -> assertFailure "remote document read env:HOME"
    | remoteLoc <- remoteDocLocations
    ]

{- | Serve a document that imports @env:HOME@ at @remoteLoc@; route every
other location through the real dispatcher and its trust gate.
-}
hostileStub :: Text -> LoadImportFn
hostileStub remoteLoc =
    stubDocLoader
        remoteLoc
        "$imports:\n  secret: env:HOME\n"
        (mkFullDispatcher (mkImportConfig Nothing (importPolicy AllowRemoteImports)))

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

caseName :: Text -> Text -> String
caseName base loc = T.unpack (loc <> " from " <> base)

assertRejected :: (Show a) => Either ImportError a -> IO ()
assertRejected = \case
    Left (ImportError e) ->
        assertBool
            ("expected trust-gate error, got: " <> T.unpack e)
            ("not allowed from remote" `T.isInfixOf` e)
    Right v -> assertFailure ("expected rejection, got " <> show v)
