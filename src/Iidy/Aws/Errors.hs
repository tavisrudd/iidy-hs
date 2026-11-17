{-# LANGUAGE OverloadedRecordDot #-}

{- | The one place that turns an AWS or HTTP exception into message text.

@show@ of an 'Amazonka.TransportError' (and of an http-client
'HttpExceptionRequest') prints the whole request: its headers, among them
@X-Amz-Security-Token@ (the session token of temporary credentials), the
query string (a presigned URL's signature) and the proxy. Nothing that
reaches a terminal or a log may use it; format the exception here instead.

* 'Amazonka.ServiceError': @\<code\>: \<message\>@ (the code alone when there is no message).
* 'Amazonka.TransportError': the request host and what went wrong, never
  the request.
* 'Amazonka.SerializeError': the service and the parse failure, never the
  response body.
-}
module Iidy.Aws.Errors (
    formatAwsError,
    formatHttpException,
) where

import Amazonka qualified
import Amazonka.Data qualified as AmazonkaData
import Control.Exception (displayException)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client (HttpException (..), HttpExceptionContent (..))
import Network.HTTP.Client qualified as Client
import Network.HTTP.Types.Status (Status (..))

-- | A one-line description of an 'Amazonka.Error' that holds no request data.
formatAwsError :: Amazonka.Error -> Text
formatAwsError = \case
    Amazonka.ServiceError se ->
        let Amazonka.ErrorCode code = se.code
         in maybe code (\m -> code <> ": " <> Amazonka.fromErrorMessage m) se.message
    Amazonka.TransportError he -> formatHttpException he
    Amazonka.SerializeError se ->
        AmazonkaData.toText se.abbrev <> ": could not parse the response (" <> T.pack se.message <> ")"

{- | A one-line description of an 'HttpException': the host (never the path,
query string, headers or proxy) and the failure.
-}
formatHttpException :: HttpException -> Text
formatHttpException = \case
    InvalidUrlException _url reason -> "invalid URL: " <> T.pack reason
    HttpExceptionRequest req content ->
        TE.decodeUtf8Lenient (Client.host req) <> ": " <> describeContent content

describeContent :: HttpExceptionContent -> Text
describeContent = \case
    StatusCodeException resp _body ->
        let Status code msg = Client.responseStatus resp
         in "HTTP status " <> T.pack (show code) <> " " <> TE.decodeUtf8Lenient msg
    TooManyRedirects _ -> "too many redirects"
    ResponseTimeout -> "response timeout"
    ConnectionTimeout -> "connection timeout"
    ConnectionFailure e -> "connection failed: " <> T.pack (displayException e)
    InternalException e -> "internal error: " <> T.pack (displayException e)
    InvalidStatusLine _ -> "invalid status line in the response"
    InvalidHeader _ -> "invalid header in the response"
    InvalidRequestHeader _ -> "invalid request header"
    ProxyConnectException _ _ (Status code _) -> "proxy refused the connection (status " <> T.pack (show code) <> ")"
    InvalidProxyEnvironmentVariable name _ -> "invalid proxy environment variable " <> name
    InvalidProxySettings _ -> "invalid proxy settings"
    other -> T.pack (show other)
