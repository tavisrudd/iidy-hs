{- | Trusted import sources (card C15): validation of
@--trust-import-source@ prefixes and the one trust decision,
'isTrustedBase'.
-}
module Test.TrustedSourceTest (trustedSourceTests) where

import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Iidy.Yaml.Imports.Types (
    TrustedSources,
    isTrustedBase,
    mkTrustedSources,
    noTrustedSources,
    parseTrustedSource,
    trustedSourceText,
 )

trustedSourceTests :: [TestTree]
trustedSourceTests =
    [ testGroup "parseTrustedSource accepts" acceptCases
    , testGroup "parseTrustedSource rejects" rejectCases
    , testGroup "isTrustedBase" trustCases
    ]

------------------------------------------------------------------------
-- Prefix validation
------------------------------------------------------------------------

validPrefixes :: [Text]
validPrefixes =
    [ "s3://bucket/"
    , "s3://bucket/templates/"
    , "s3:bucket/"
    , "https://t.example.com/"
    , "http://t.example.com:8080/shared/"
    , "ssm:/app/"
    , "ssm-path:/app/"
    , "cfn:export/"
    ]

-- | Invalid prefixes, each with the reason it must be refused.
invalidPrefixes :: [(Text, String)]
invalidPrefixes =
    [ ("s3://bucket", "no trailing /")
    , ("https://t.example.com", "no trailing /")
    , ("s3:///", "no bucket")
    , ("s3:/", "no bucket in the short form")
    , ("https:///", "no host")
    , ("http:///path/", "no host")
    , ("templates/", "local path")
    , ("./templates/", "local path")
    , ("/abs/", "local path")
    , ("file:templates/", "local scheme")
    , ("env:HOME/", "local-only scheme")
    , ("git:x/", "local-only scheme")
    , ("ftp://host/", "unknown scheme")
    , ("HTTPS://t.example.com/", "upper-case scheme")
    , ("https://t.example.com/a/../", "dot-dot segment")
    , ("https://t.example.com/./", "dot segment")
    , ("https://t.example.com/%2E%2e/", "encoded dot-dot segment")
    , ("", "empty")
    ]

acceptCases :: [TestTree]
acceptCases =
    [ testCase (T.unpack p) $ fmap trustedSourceText (parseTrustedSource p) @?= Right p
    | p <- validPrefixes
    ]

rejectCases :: [TestTree]
rejectCases =
    [ testCase (T.unpack p <> " (" <> why <> ")") $
        assertBool "expected a validation error" (isLeft (parseTrustedSource p))
    | (p, why) <- invalidPrefixes
    ]

------------------------------------------------------------------------
-- Trust decision
------------------------------------------------------------------------

-- | Build trusted sources from prefixes that must validate.
sources :: [Text] -> IO TrustedSources
sources ps = case traverse parseTrustedSource ps of
    Right ts -> pure (mkTrustedSources ts)
    Left err -> assertFailure (T.unpack err)

-- | (trusted prefixes, document location, expected trust)
trustTable :: [([Text], Text, Bool)]
trustTable =
    [ ([], "stack-args.yaml", True)
    , ([], "dir/template.yaml", True)
    , ([], "https://t.example.com/a.yaml", False)
    , ([], "s3://bucket/a.yaml", False)
    , ([], "ssm:/app/a", False)
    , (["https://t.example.com/"], "https://t.example.com/a.yaml", True)
    , (["https://t.example.com/"], "https://t.example.com/dir/a.yaml", True)
    , (["https://t.example.com/"], "https://t.example.com.evil/a.yaml", False)
    , (["https://t.example.com/"], "https://t.example.com:8443/a.yaml", False)
    , (["https://t.example.com/"], "http://t.example.com/a.yaml", False)
    , (["https://t.example.com/"], "https://T.example.com/a.yaml", False)
    , (["https://t.example.com/team/"], "https://t.example.com/team/a.yaml", True)
    , (["https://t.example.com/team/"], "https://t.example.com/teamx/a.yaml", False)
    , (["https://t.example.com/team/"], "https://t.example.com/team/../other/a.yaml", False)
    , (["https://t.example.com/team/"], "https://t.example.com/team/%2e%2E/other/a.yaml", False)
    , (["s3://bucket/"], "s3://bucket/a.yaml", True)
    , (["s3://bucket/"], "s3:bucket/a.yaml", False)
    , (["s3://bucket/"], "s3://bucket2/a.yaml", False)
    , (["s3:bucket/"], "s3:bucket/a.yaml", True)
    , (["s3:bucket/"], "s3://bucket/a.yaml", False)
    , (["ssm:/app/"], "ssm:/app/tmpl", True)
    , (["ssm:/app/"], "ssm:/application/tmpl", False)
    , (["ssm:/app/"], "ssm-path:/app/tmpl", False)
    , (["s3://a/", "https://b.example.com/"], "https://b.example.com/x.yaml", True)
    , (["s3://a/", "https://b.example.com/"], "s3://a/x.yaml", True)
    ]

trustCases :: [TestTree]
trustCases =
    [ testCase (T.unpack (loc <> " under " <> T.intercalate "," ps)) $ do
        ts <- if null ps then pure noTrustedSources else sources ps
        isTrustedBase ts loc @?= expected
    | (ps, loc, expected) <- trustTable
    ]
