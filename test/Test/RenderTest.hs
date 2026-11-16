{- | Tests for the render command's JSON output bytes, pinned to the Rust
original (@serde_json::to_string_pretty@ plus @println!@, @render.rs:44@).
-}
module Test.RenderTest (renderTests) where

import Data.Text (Text)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (testCase, (@?=))

import Iidy.Cli (RenderArgs (..), RenderFormat (..))
import Iidy.Render (runRender)
import Iidy.Types (YamlSpec (..))
import Test.Shared (collectRawOutput, docFixture, listFixture, testGlobalOpts)

-- | Render a fixture to stdout as JSON, returning exit code and raw output.
renderJson :: Text -> IO (Int, [Text])
renderJson path = do
    (emit, readOut) <- collectRawOutput
    let args =
            RenderArgs
                { raTemplate = path
                , raOutfile = "-"
                , raFormat = RenderJson
                , raQuery = Nothing
                , raOverwrite = False
                , raYamlSpec = YamlAuto
                }
    rc <- runRender emit args (testGlobalOpts False)
    (,) rc <$> readOut

renderTests :: [TestTree]
renderTests =
    [ testCase "render --format json: nested mapping is two-space with trailing newline" $
        renderJson docFixture
            >>= ( @?=
                    ( 0
                    , ["{\n  \"a\": 1,\n  \"b\": {\n    \"c\": \"x\",\n    \"d\": {}\n  }\n}\n"]
                    )
                )
    , testCase "render --format json: list is two-space, one element per line" $
        renderJson listFixture
            >>= (@?= (0, ["{\n  \"l\": [\n    \"x\",\n    \"y\"\n  ]\n}\n"]))
    ]
