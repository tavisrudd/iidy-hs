-- | HTTP/HTTPS import loader: fetch content from HTTP or HTTPS URLs.
module Iidy.Yaml.Imports.Loaders.Http
  ( loadHttpImport
  , urlPath
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client (responseTimeoutMicro)
import Network.HTTP.Simple
  ( getResponseBody
  , getResponseStatusCode
  , httpBS
  , parseRequest
  , setRequestResponseTimeout
  )
import System.FilePath (takeExtension)

import Iidy.Constants (httpTimeoutSeconds, httpMaxResponseBytes)
import Iidy.Yaml.Imports.Types (ImportData(..), ImportError(..), ImportType(..))

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

-- | Load an import from an HTTP or HTTPS URL.
-- Accepts @http://...@ or @https://...@ URLs.
-- Enforces a response timeout ('httpTimeoutSeconds') and maximum body
-- size ('httpMaxResponseBytes').
-- Returns the response body as UTF-8 text on success, or an error message.
loadHttpImport :: Text -> IO (Either ImportError ImportData)
loadHttpImport location = do
  result <- try @SomeException (fetchHttp location)
  case result of
    Left ex ->
      pure $ Left $ ImportError $
        "HTTP fetch error for " <> location <> ": " <> T.pack (show ex)
    Right (statusCode, body)
      | statusCode >= 200 && statusCode < 300 ->
          if BS.length body > httpMaxResponseBytes
            then pure $ Left $ ImportError $
              "HTTP response for " <> location <> " exceeds maximum size of "
              <> T.pack (show (httpMaxResponseBytes `div` (1024 * 1024))) <> " MB"
            else case TE.decodeUtf8' body of
              Left ex ->
                pure $ Left $ ImportError $
                  "UTF-8 decode error for " <> location <> ": " <> T.pack (show ex)
              Right content ->
                let ext = takeExtension (T.unpack (urlPath location))
                    doc = parseByExtension ext content body
                in  pure $ Right $ ImportData
                      { idType     = ImportHttp
                      , idLocation = location
                      , idRawData  = content
                      , idDoc      = doc
                      }
      | otherwise ->
          pure $ Left $ ImportError $
            "HTTP error " <> T.pack (show statusCode) <> " for " <> location

------------------------------------------------------------------------
-- HTTP fetch
------------------------------------------------------------------------

-- | Perform an HTTP GET and return (statusCode, responseBodyBytes).
-- Applies a response timeout of 'httpTimeoutSeconds'.
fetchHttp :: Text -> IO (Int, BS.ByteString)
fetchHttp url = do
  baseReq <- parseRequest (T.unpack url)
  let req = setRequestResponseTimeout
              (responseTimeoutMicro (httpTimeoutSeconds * 1000000))
              baseReq
  resp <- httpBS req
  pure (getResponseStatusCode resp, getResponseBody resp)

------------------------------------------------------------------------
-- Content parsing
------------------------------------------------------------------------

-- | Parse response body based on URL path extension.
parseByExtension :: String -> Text -> BS.ByteString -> Value
parseByExtension ext content rawBytes
  | ext `elem` [".yaml", ".yml"] = parseJsonOrString rawBytes content
  | ext == ".json"                = parseJsonOrString rawBytes content
  | otherwise                     = String content

-- | Attempt JSON parse; fall back to plain string.
parseJsonOrString :: BS.ByteString -> Text -> Value
parseJsonOrString rawBytes content =
  case Aeson.eitherDecodeStrict' rawBytes of
    Right v -> v
    Left _  -> String content

------------------------------------------------------------------------
-- URL helpers
------------------------------------------------------------------------

-- | Extract the path component from a URL (everything after the host),
-- for the purpose of inferring content type from the file extension.
-- Strips query strings and fragments so takeExtension works correctly.
urlPath :: Text -> Text
urlPath url =
  let noScheme = maybe url id (T.stripPrefix "https://" url)
      noScheme' = maybe noScheme id (T.stripPrefix "http://" noScheme)
      rawPath = case T.dropWhile (/= '/') noScheme' of
        p | T.null p  -> "/"
          | otherwise -> p
      -- Strip query string and fragment
      noQuery = fst (T.breakOn "?" rawPath)
      noFragment = fst (T.breakOn "#" noQuery)
  in  noFragment
