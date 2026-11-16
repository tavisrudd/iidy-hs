# Rework HTTP Import Size Enforcement to Stream -- Enhancement

**Status**: DONE
**Date**: 2026-03-01
**References**: `src/Iidy/Yaml/Imports/Loaders/Http.hs`, `src/Iidy/Constants.hs`

## Context

The current HTTP import loader (`loadHttpImport`) uses `httpBS` which buffers
the entire response body in memory before checking the size limit. A malicious
or misconfigured server could send a multi-GB response that gets fully buffered
before the size check on line 45 rejects it.

The fix: switch to streaming/chunked reads that abort as soon as the accumulated
size exceeds `httpMaxResponseBytes`, before the full body is in memory.

## Current Code (Http.hs)

```haskell
fetchHttp :: Text -> IO (Int, BS.ByteString)
fetchHttp url = do
  baseReq <- parseRequest (T.unpack url)
  let req = setRequestResponseTimeout
              (responseTimeoutMicro (httpTimeoutSeconds * 1000000))
              baseReq
  resp <- httpBS req           -- <-- buffers entire body
  pure (getResponseStatusCode resp, getResponseBody resp)
```

Then in `loadHttpImport`:
```haskell
  if BS.length body > httpMaxResponseBytes  -- <-- too late, already buffered
```

## Implementation Plan

### Option A: Use http-conduit streaming (recommended)

Replace `httpBS` with `httpSink` or `withResponse` + manual chunked read:

```haskell
import Network.HTTP.Simple (httpSink, getResponseStatusCode)
import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import Data.ByteString.Builder (byteString, toLazyByteString)

fetchHttpStreaming :: Text -> IO (Int, BS.ByteString)
fetchHttpStreaming url = do
  baseReq <- parseRequest (T.unpack url)
  let req = setRequestResponseTimeout
              (responseTimeoutMicro (httpTimeoutSeconds * 1000000))
              baseReq
  httpSink req $ \resp -> do
    let status = getResponseStatusCode resp
    chunks <- sinkWithLimit httpMaxResponseBytes
    pure (status, BS.concat chunks)

-- Conduit sink that accumulates chunks up to a byte limit, then throws
sinkWithLimit :: Int -> C.ConduitT BS.ByteString C.Void IO [BS.ByteString]
sinkWithLimit maxBytes = go 0 []
  where
    go !acc chunks = do
      mChunk <- C.await
      case mChunk of
        Nothing -> pure (reverse chunks)
        Just chunk ->
          let newAcc = acc + BS.length chunk
          in if newAcc > maxBytes
             then liftIO $ throwIO $ HttpSizeLimitExceeded maxBytes
             else go newAcc (chunk : chunks)
```

### Option B: Use withResponse + manual brk read (no conduit dep)

Use `Network.HTTP.Client.withResponse` + `Network.HTTP.Client.brRead`:

```haskell
import Network.HTTP.Client (withResponse, brRead, responseBody, responseStatus)

fetchHttpStreaming :: Manager -> Text -> IO (Int, BS.ByteString)
fetchHttpStreaming mgr url = do
  baseReq <- parseRequest (T.unpack url)
  let req = setRequestResponseTimeout ... baseReq
  withResponse req mgr $ \resp -> do
    let status = statusCode (responseStatus resp)
    chunks <- readWithLimit (responseBody resp) httpMaxResponseBytes
    pure (status, BS.concat chunks)

readWithLimit :: BodyReader -> Int -> IO [BS.ByteString]
readWithLimit br maxBytes = go 0 []
  where
    go !acc chunks = do
      chunk <- brRead br
      if BS.null chunk
        then pure (reverse chunks)
        else let newAcc = acc + BS.length chunk
             in if newAcc > maxBytes
                then throwIO $ HttpSizeLimitExceeded maxBytes
                else go newAcc (chunk : chunks)
```

**Recommendation**: Option B is simpler (no conduit dependency needed).
`http-client` is already a dependency. The `httpBS` function from
`http-conduit` internally uses the same `withResponse` + `brRead` pattern,
so this just adds the size check in the loop.

### Error type

Add a small exception type:
```haskell
data HttpSizeLimitExceeded = HttpSizeLimitExceeded Int
  deriving stock (Show)
instance Exception HttpSizeLimitExceeded
```

The existing `try @SomeException` in `loadHttpImport` will catch this and
produce the same error message. Alternatively, return it as an `Either`
instead of throwing.

### Dependencies

- `http-client` already in cabal (added for `responseTimeoutMicro`)
- No new dependencies needed for Option B
- Need to add `Network.HTTP.Client` imports (Manager, withResponse, brRead, etc.)
- Need a Manager — either create one per call or thread it through. Creating
  per call is fine for import loading (not a hot path).

## Codebase Reference

| What                  | Where                                          |
|-----------------------|------------------------------------------------|
| `loadHttpImport`      | `src/Iidy/Yaml/Imports/Loaders/Http.hs:36`    |
| `fetchHttp`           | `src/Iidy/Yaml/Imports/Loaders/Http.hs:72`    |
| Constants             | `src/Iidy/Constants.hs`                         |
| Import types          | `src/Iidy/Yaml/Imports/Types.hs`               |
| Existing HTTP tests   | `test/Test/ImportLoaderTest.hs` (urlPath only) |

## Build/Test Commands

Per CLAUDE.md.

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet
- **Why**: Self-contained change in one file. Option B is straightforward — replace
  `httpBS` with `withResponse` + `brRead` loop with size accumulator.

## Progress

- [ ] Replace `fetchHttp` with streaming version (Option B)
- [ ] Add `HttpSizeLimitExceeded` exception or handle via Either
- [ ] Update `loadHttpImport` to remove post-hoc size check (now in stream)
- [ ] Verify existing `urlPath` and dispatcher tests still pass
- [ ] Build clean + all tests pass
