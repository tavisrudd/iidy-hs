# Safety Hardening: Partial Functions, NTP, S3 Limit (H-2, H-3, M-3, M-7)

**Status**: DONE
**Severity**: High/Medium
**Files**: `src/Iidy/Cfn/TemplateLoader.hs`, `src/Iidy/Aws/Timing.hs`,
`src/Iidy/Yaml/Emitter.hs`, `src/Iidy/Yaml/Imports/Loaders/S3.hs`

## H-2: Partial TE.decodeUtf8 in TemplateLoader

`TemplateLoader.hs:165` uses `TE.decodeUtf8` (throws on invalid UTF-8).
**Fix**: Use `TE.decodeUtf8'` and return a proper error message.

## H-3: NTP Word32 underflow

`Timing.hs:119-128`: `secs - ntpToUnixOffset` underflows if `secs < ntpToUnixOffset`.
**Fix**: Guard `secs >= ntpToUnixOffset`, return `Nothing` otherwise. Add test.

## M-3: Partial `init` in Emitter

`Emitter.hs:55-61` and ~215: `init lns` is partial. While `T.splitOn` never returns
empty, CLAUDE.md says "No partial functions".
**Fix**: Replace with safe pattern: `if null lns then [] else Prelude.init lns` or
use a helper. Or use `dropWhileEnd` on the split result.

## M-7: S3 no size limit

`S3.hs:66-70`: Reads entire S3 object with no cap. HTTP has 10MB limit.
**Fix**: Add a size check during streaming (count bytes, abort if >10MB). Match the
HTTP loader's `httpMaxResponseBytes` constant.

## Verification
- `cabal build` zero warnings
- `cabal test` all 972+ tests pass
- Add tests for: invalid UTF-8 file, NTP underflow, S3 oversize
