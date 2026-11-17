{- | Tests for the render command's output bytes, pinned to the Rust
original: JSON is @serde_json::to_string_pretty@ plus @println!@
(@render.rs:44@), YAML is @serialize_yaml_iidy_js_compatible@ (@render.rs:45@,
sequences indented under their key, unlike @serde_yaml@).
-}
module Test.RenderTest (renderTests) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (testCase, (@?=))

import Iidy.Cli (RenderArgs (..), RenderFormat (..))
import Iidy.Render (runRender)
import Iidy.Types (YamlSpec (..))
import Test.Shared (collectRawOutput, docFixture, listFixture, nestedSeqFixture, preprocTagsImporterFixture, testGlobalOpts)

-- | Render a fixture to stdout as JSON, returning exit code and raw output.
renderJson :: Text -> IO (Int, [Text])
renderJson = renderAs RenderJson

-- | Render a fixture to stdout in the given format, returning exit code and raw output.
renderAs :: RenderFormat -> Text -> IO (Int, [Text])
renderAs fmt path = do
    (emit, readOut) <- collectRawOutput
    let args =
            RenderArgs
                { raTemplate = path
                , raOutfile = "-"
                , raFormat = fmt
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
    , testCase "render --format yaml: sequences stay indented under their key" $
        renderAs RenderYaml nestedSeqFixture >>= (@?= (0, [nestedSeqRenderYaml]))
    , testCase "render --format yaml: an imported plain document keeps its !$ tags" $
        renderAs RenderYaml preprocTagsImporterFixture >>= (@?= (0, [preprocTagsRenderYaml]))
    ]

-- | Bytes printed by the Rust binary's @render@ for 'nestedSeqFixture' (C25).
nestedSeqRenderYaml :: Text
nestedSeqRenderYaml =
    T.unlines
        [ "a:"
        , "  c:"
        , "    - x"
        , "    - y"
        , "  grid:"
        , "    - - 1"
        , "      - 2"
        , "    - - 3"
        , "      - - 4"
        , "        - 5"
        , "  items:"
        , "    - deep:"
        , "        k:"
        , "          - p"
        , "          - q"
        , "      name: n1"
        , "      tags:"
        , "        - t1"
        , "        - t2"
        , "    - empty: []"
        , "      name: n2"
        , "top:"
        , "  - u"
        , "  - v"
        ]

-- | Bytes printed by the Rust binary's @render@ for 'preprocTagsImporterFixture' (C26).
preprocTagsRenderYaml :: Text
preprocTagsRenderYaml =
    T.unlines
        [ "out:"
        , "  a: !$ secret"
        , "  b: !$map"
        , "    items:"
        , "      - 1"
        , "      - 2"
        , "    template: '{{item}}'"
        , "seq:"
        , "  c: !$join"
        , "    - ','"
        , "    - - a"
        , "      - b"
        ]
