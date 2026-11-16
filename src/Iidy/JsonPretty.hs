{- | The one two-space pretty-JSON encoder for the render and get-import
commands, matching Rust @serde_json::to_string_pretty@ (@render.rs:44@,
@get_import.rs@). The result has no trailing newline.
-}
module Iidy.JsonPretty (
    prettyJsonText,
) where

import Data.Aeson (ToJSON)
import Data.Aeson.Encode.Pretty qualified as Pretty
import Data.Text (Text)
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE

-- | Two-space pretty JSON, no trailing newline.
prettyJsonText :: (ToJSON a) => a -> Text
prettyJsonText v =
    TL.toStrict (TLE.decodeUtf8 (Pretty.encodePretty' Pretty.defConfig{Pretty.confIndent = Pretty.Spaces 2} v))
