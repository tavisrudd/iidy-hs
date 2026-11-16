{- | Tests for the render command's JSON output bytes, pinned to the Rust
original (@serde_json::to_string_pretty@ plus @println!@, @render.rs:44@).
-}
module Test.RenderTest (renderTests) where

import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (testCase, (@?=))

import Iidy.Cli (GlobalOpts (..), RenderArgs (..), RenderFormat (..))
import Iidy.Output.Types (OutputData (..))
import Iidy.Render (runRender)
import Iidy.Types (ColorChoice (..), Theme (..), YamlSpec (..))

globalOpts :: GlobalOpts
globalOpts =
    GlobalOpts
        { goEnvironment = "development"
        , goColor = ColorNever
        , goTheme = ThemeAuto
        , goOutputMode = Nothing
        , goDebug = False
        , goLogFullError = False
        , goRemoteImports = False
        }

-- | Render a fixture to stdout as JSON, returning exit code and raw output.
renderJson :: Text -> IO (Int, [Text])
renderJson path = do
    out <- newIORef []
    let emit = \case
            OdRawOutput t -> atomicModifyIORef' out (\ts -> (ts <> [t], ()))
            _other -> pure ()
        args =
            RenderArgs
                { raTemplate = path
                , raOutfile = "-"
                , raFormat = RenderJson
                , raQuery = Nothing
                , raOverwrite = False
                , raYamlSpec = YamlAuto
                }
    rc <- runRender emit args globalOpts
    (,) rc <$> readIORef out

renderTests :: [TestTree]
renderTests =
    [ testCase "render --format json: nested mapping is two-space with trailing newline" $
        renderJson "test-fixtures/get-import/doc.yaml"
            >>= ( @?=
                    ( 0
                    , ["{\n  \"a\": 1,\n  \"b\": {\n    \"c\": \"x\",\n    \"d\": {}\n  }\n}\n"]
                    )
                )
    , testCase "render --format json: list is two-space, one element per line" $
        renderJson "test-fixtures/get-import/list.yaml"
            >>= (@?= (0, ["{\n  \"l\": [\n    \"x\",\n    \"y\"\n  ]\n}\n"]))
    ]
