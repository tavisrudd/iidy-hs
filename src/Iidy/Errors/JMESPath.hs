module Iidy.Errors.JMESPath (
    formatJMESPathQueryError,
) where

import Data.Text (Text)

import Iidy.Types (ColorChoice)
import Iidy.Yaml.Errors.Display (
    ErrorColors (..),
    detectErrorColors,
    formatFooter,
    formatGuidance,
 )
import Iidy.Yaml.Errors.Ids (ErrorId (..))
import Iidy.Yaml.JMESPath (JMESPathError (..))

{- | Format a JMESPath error from a CLI --query flag.

Unlike YAML-embedded JMESPath errors (which have a source position and
variable context), CLI query errors have no source location, so we emit
a simpler but consistently styled message using the same color helpers.
-}
formatJMESPathQueryError :: ColorChoice -> Text -> JMESPathError -> IO Text
formatJMESPathQueryError colorChoice expr (JMESPathError detail) = do
    c <- detectErrorColors colorChoice
    pure $
        formatQueryHeader c expr detail
            <> formatGuidance c "invalid JMESPath expression passed via --query flag"
            <> formatFooter c InvalidCommandLineArgument

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

formatQueryHeader :: ErrorColors -> Text -> Text -> Text
formatQueryHeader c expr detail =
    ecBoldRed c
        <> "Query error"
        <> ecReset c
        <> ": invalid JMESPath expression '"
        <> expr
        <> "': "
        <> detail
        <> "\n"
