{- | Custom templates and parent variables (card C15).

A custom template loaded from a trusted document (a local file, or a
location under a @--trust-import-source@ prefix reached through trusted
documents) sees the importing template's variables, as in Rust. One from
an untrusted location expands with its parameters only, as in
TypeScript. Each case runs through a resource type and through
@!$expand@, using the dispatcher helper that gives the engine the same
policy as the dispatcher.
-}
module Test.CustomTemplateTrustTest (customTemplateTrustTests) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

import Iidy.Yaml.Engine (PreprocessError (..), PreprocessResult (..))
import Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher, mkImportConfig)
import Iidy.Yaml.Imports.Types (ImportPolicy, RemoteImports (..), importPolicy)
import Iidy.Yaml.OValue (toValue)
import Iidy.Yaml.Resolution.Resolver (ResolveError (..))
import Test.ImportFixtures (flagPolicy, preprocessText, stubDocsLoader)

customTemplateTrustTests :: [TestTree]
customTemplateTrustTests =
    [ testGroup
        (T.unpack name)
        [ testCase "resource type" $ check expectInherit policyFor loc resourceRoot resourceTemplate
        , testCase "!$expand" $ check expectInherit policyFor loc expandRoot expandTemplate
        ]
    | (name, loc, policyFor, expectInherit) <-
        [ ("local template keeps parent variables", "tmpl.yaml", noFlags, True)
        , ("untrusted template gets its parameters only", "https://evil.example/tmpl.yaml", noFlags, False)
        , ("flag-trusted template keeps parent variables", "https://t.example.com/tmpl.yaml", trustT, True)
        ]
    ]
  where
    noFlags :: IO ImportPolicy
    noFlags = pure (importPolicy AllowRemoteImports)
    trustT :: IO ImportPolicy
    trustT = flagPolicy ["https://t.example.com/"]

-- | A template that uses its parameter and the parent's @secret@.
expandTemplate :: Text
expandTemplate = "$params:\n  - Name: p\nvalue: \"{{p}}-{{secret}}\"\n"

expandRoot :: Text -> Text
expandRoot loc =
    "$defs:\n  secret: s3cr3t\n$imports:\n  T: \""
        <> loc
        <> "\"\nout: !$expand\n  template: T\n  params:\n    p: given\n"

resourceTemplate :: Text
resourceTemplate =
    "$params:\n  - Name: Suffix\nResources:\n  Bucket:\n    Type: AWS::S3::Bucket\n"
        <> "    Properties:\n      BucketName: \"{{Suffix}}-{{secret}}\"\n"

resourceRoot :: Text -> Text
resourceRoot loc =
    "$defs:\n  secret: s3cr3t\n$imports:\n  Tagged: \""
        <> loc
        <> "\"\nResources:\n  Data:\n    Type: Tagged\n    Properties:\n      Suffix: given\n"

{- | Preprocess the root with the template served at @loc@ (every other
location through the real dispatcher) and check whether the template saw
the parent's @secret@.
-}
check :: Bool -> IO ImportPolicy -> Text -> (Text -> Text) -> Text -> IO ()
check expectInherit mkPolicy loc root template = do
    policy <- mkPolicy
    let loader = stubDocsLoader [(loc, template)] (mkFullDispatcher (mkImportConfig Nothing policy))
    result <- preprocessText policy loader "local.yaml" (root loc)
    case (expectInherit, result) of
        (True, Right r) ->
            assertBool ("expected given-s3cr3t in " <> rendered r) ("given-s3cr3t" `T.isInfixOf` T.pack (rendered r))
        (True, Left err) -> assertFailure ("expected success, got " <> show err)
        (False, Right r) -> assertFailure ("untrusted template read the parent's secret: " <> rendered r)
        (False, Left (PeResolveError ResolveError{reMessage = msg})) ->
            assertBool ("expected an error naming secret, got: " <> T.unpack msg) ("secret" `T.isInfixOf` msg)
        (False, Left other) -> assertFailure ("expected a variable error, got " <> show other)
  where
    rendered :: PreprocessResult -> String
    rendered = show . toValue . prValue
