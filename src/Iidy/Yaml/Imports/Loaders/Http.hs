-- | HTTP/HTTPS import loader: fetch content from HTTP or HTTPS URLs.
module Iidy.Yaml.Imports.Loaders.Http (
    loadHttpImport,
    loadHttpImportWithin,
    urlPath,
) where

import Control.Exception (Exception, Handler (..), catches, fromException, throwIO)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client (
    BodyReader,
    HttpException (..),
    HttpExceptionContent (..),
    Manager,
    brRead,
    newManager,
    responseBody,
    responseStatus,
    responseTimeoutMicro,
    withResponse,
 )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Simple (parseRequest, setRequestResponseTimeout)
import Network.HTTP.Types.Status (statusCode)
import System.FilePath (takeExtension)
import System.Timeout (timeout)

import Iidy.Aws.Errors (formatHttpException)
import Iidy.Constants (httpMaxResponseBytes, httpTimeoutSeconds, httpTotalTimeoutSeconds)
import Iidy.Yaml.Imports.ContentParsing (ParsedDoc (..), parseByExtensionStrict)
import Iidy.Yaml.Imports.Loaders.HttpGuard (GuardRefusal (..), HttpGuard, HttpSeam, guardManagerSettings)
import Iidy.Yaml.Imports.Types (ImportData (..), ImportError (..), ImportType (..))

------------------------------------------------------------------------
-- Exception type
------------------------------------------------------------------------

-- | Thrown when the HTTP response body exceeds 'httpMaxResponseBytes'.
newtype HttpSizeLimitExceeded = HttpSizeLimitExceeded Int
    deriving stock (Show)

instance Exception HttpSizeLimitExceeded

-- | Thrown when the whole fetch passes 'httpTotalTimeoutSeconds'.
data HttpTotalTimeExceeded = HttpTotalTimeExceeded
    deriving stock (Show)

instance Exception HttpTotalTimeExceeded

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

{- | Load an import from an HTTP or HTTPS URL.
Accepts @http://...@ or @https://...@ URLs.
Enforces a response timeout ('httpTimeoutSeconds') and maximum body
size ('httpMaxResponseBytes'). The size limit is enforced while
streaming — the response is aborted before the full body is buffered.
Returns the response body as UTF-8 text on success, or an error message.
Every hop, redirects included, passes the 'HttpGuard' (see
"Iidy.Yaml.Imports.Loaders.HttpGuard"); plain connections go through the
'HttpSeam'. @HTTP_PROXY@ / @HTTPS_PROXY@ are honoured.
-}
loadHttpImport :: HttpSeam -> HttpGuard -> Text -> IO (Either ImportError ImportData)
loadHttpImport = loadHttpImportWithin (httpTotalTimeoutSeconds * 1000000)

{- | 'loadHttpImport' with the total time for the fetch, from request to the
end of the body, given in microseconds (the limit is 'httpTotalTimeoutSeconds';
tests pass a short one).
-}
loadHttpImportWithin :: Int -> HttpSeam -> HttpGuard -> Text -> IO (Either ImportError ImportData)
loadHttpImportWithin totalMicros seam guard location = do
    -- Fresh manager per call; fine for a CLI tool with a handful of HTTP imports.
    mgr <- newManager =<< guardManagerSettings seam guard tlsManagerSettings
    let mkError :: Text -> IO (Either ImportError ImportData)
        mkError msg =
            pure $
                Left $
                    ImportError $
                        "HTTP fetch error for " <> location <> ": " <> msg
    ( do
            fetched <- timeout totalMicros (fetchHttpStreaming mgr location)
            (status, body) <- maybe (throwIO HttpTotalTimeExceeded) pure fetched
            if status >= 200 && status < 300
                then case TE.decodeUtf8' body of
                    Left ex ->
                        pure $
                            Left $
                                ImportError $
                                    "UTF-8 decode error for " <> location <> ": " <> T.pack (show ex)
                    Right content ->
                        let ext = takeExtension (T.unpack (urlPath location))
                         in case parseByExtensionStrict location ext content body of
                                Left err -> pure (Left err)
                                Right (ParsedDoc doc ordered) ->
                                    pure $
                                        Right $
                                            ImportData
                                                { idType = ImportHttp
                                                , idLocation = location
                                                , idRawData = content
                                                , idOrdered = ordered
                                                , idDoc = doc
                                                }
                else
                    pure $
                        Left $
                            ImportError $
                                "HTTP error " <> T.pack (show status) <> " for " <> location
        )
        `catches` [ Handler $ \(e :: HttpException) -> mkError (httpExceptionText e)
                  , Handler $ \(e :: HttpSizeLimitExceeded) -> mkError (T.pack (show e))
                  , Handler $ \HttpTotalTimeExceeded ->
                        mkError ("total time limit of " <> T.pack (show (totalMicros `div` 1000000)) <> " seconds exceeded")
                  , Handler $ \(GuardRefusal why) -> mkError ("refused: " <> why)
                  ]

-- | An http-client exception, with a guard refusal it wrapped spelled out.
httpExceptionText :: HttpException -> Text
httpExceptionText = \case
    HttpExceptionRequest _req (InternalException e)
        | Just (GuardRefusal why) <- fromException e -> "refused: " <> why
    other -> formatHttpException other

------------------------------------------------------------------------
-- HTTP fetch (streaming with size limit)
------------------------------------------------------------------------

{- | Perform an HTTP GET and return (statusCode, responseBodyBytes).
Applies a response timeout of 'httpTimeoutSeconds'.
Aborts streaming and throws 'HttpSizeLimitExceeded' if the accumulated
body size exceeds 'httpMaxResponseBytes', before the full body is buffered.
-}
fetchHttpStreaming :: Manager -> Text -> IO (Int, BS.ByteString)
fetchHttpStreaming mgr url = do
    baseReq <- parseRequest (T.unpack url)
    let req =
            setRequestResponseTimeout
                (responseTimeoutMicro (httpTimeoutSeconds * 1000000))
                baseReq
    withResponse req mgr $ \resp -> do
        let status = statusCode (responseStatus resp)
        chunks <- readWithLimit (responseBody resp) httpMaxResponseBytes
        pure (status, BS.concat chunks)

{- | Read chunks from a 'BodyReader' up to a byte limit.
Throws 'HttpSizeLimitExceeded' if the accumulated size exceeds @maxBytes@.
-}
readWithLimit :: BodyReader -> Int -> IO [BS.ByteString]
readWithLimit br maxBytes = go 0 []
  where
    go :: Int -> [BS.ByteString] -> IO [BS.ByteString]
    go !acc chunks = do
        chunk <- brRead br
        if BS.null chunk
            then pure (reverse chunks)
            else
                let newAcc = acc + BS.length chunk
                 in if newAcc > maxBytes
                        then throwIO (HttpSizeLimitExceeded maxBytes)
                        else go newAcc (chunk : chunks)

------------------------------------------------------------------------
-- URL helpers
------------------------------------------------------------------------

{- | Extract the path component from a URL (everything after the host),
for the purpose of inferring content type from the file extension.
Strips query strings and fragments so takeExtension works correctly.
-}
urlPath :: Text -> Text
urlPath url =
    let noScheme = fromMaybe url (T.stripPrefix "https://" url)
        noScheme' = fromMaybe noScheme (T.stripPrefix "http://" noScheme)
        rawPath = case T.dropWhile (/= '/') noScheme' of
            p
                | T.null p -> "/"
                | otherwise -> p
        -- Strip query string and fragment
        noQuery = fst (T.breakOn "?" rawPath)
        noFragment = fst (T.breakOn "#" noQuery)
     in noFragment
