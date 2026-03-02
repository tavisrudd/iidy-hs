# Add Subsystem Tests for Iidy.Aws.Timing -- Test Addition

**Date**: 2026-03-01
**References**: `src/Iidy/Aws/Timing.hs`, `~/src/iidy/src/aws/timing.rs`

## Context

`Iidy.Aws.Timing` implements NTP time synchronization (SNTP RFC 4330) with a
fallback chain: NTP query (2s timeout) → retry (2s timeout) → system clock.
Zero dedicated tests exist. The module has three testable areas: packet
parsing, fallback behavior, and timeout behavior.

## Module Summary (135 LOC)

### Exports
```haskell
data TimeProvider = TimeProvider
  { tpNow       :: IO UTCTime
  , tpStartTime :: IO UTCTime  -- now() - 500ms
  }

systemTimeProvider  :: TimeProvider           -- system clock, no NTP
reliableTimeProvider :: IO TimeProvider       -- NTP with fallback
mockTimeProvider    :: UTCTime -> TimeProvider -- fixed time for tests
```

### Internal Functions (need testing)
```haskell
reliableNow      :: IO UTCTime              -- try NTP twice, fallback to system
tryNtp           :: IO (Maybe UTCTime)      -- single NTP attempt with 2s timeout
queryNtp         :: IO (Maybe UTCTime)      -- UDP query to pool.ntp.org:123
parseNtpResponse :: ByteString -> Maybe UTCTime  -- extract time from 48-byte packet
getWord32        :: ByteString -> Int -> Word32   -- big-endian read helper
ntpRequest       :: ByteString              -- 48-byte SNTP request packet
ntpTimeoutMicros :: Int                     -- 2_000_000 (2 seconds)
```

## What to Test

### A. Packet parsing (pure, no IO)

`parseNtpResponse` and `getWord32` are pure functions — ideal unit test targets.
They are not currently exported, so either:
- Export them from an Internal module, OR
- Add tests to the module itself (less ideal), OR
- **Recommended**: Create `Iidy.Aws.Timing.Internal` that exports the internals,
  have `Iidy.Aws.Timing` re-export the public API only.

**Test cases for parseNtpResponse:**

| Case                                   | Expected                                  |
|----------------------------------------|-------------------------------------------|
| Valid 48-byte NTP response             | `Just <UTCTime>` with correct conversion  |
| Packet shorter than 48 bytes           | `Nothing`                                 |
| Empty ByteString                       | `Nothing`                                 |
| Known NTP timestamp (hand-computed)    | Exact UTCTime match                       |

To construct a valid test packet:
- Create 48 zero bytes
- Set bytes 40-43 to a known NTP seconds value (big-endian)
- Set bytes 44-47 to a known fraction value
- Verify the parsed UTCTime matches the expected conversion

**NTP epoch math**: NTP epoch is 1900-01-01. Unix epoch offset = 2,208,988,800.
Example: NTP seconds 3,917,000,000 → Unix seconds 1,708,011,200 → 2024-02-15T18:13:20Z.

**Test cases for getWord32:**

| Case                          | Expected    |
|-------------------------------|-------------|
| `getWord32 "\x00\x00\x00\x01" 0` | `1`     |
| `getWord32 "\xFF\xFF\xFF\xFF" 0`  | `maxBound :: Word32` |
| `getWord32 "\x00\x00\x01\x00" 0`  | `256`   |

**Test ntpRequest packet format:**
- Length is 48 bytes
- First byte is 0x23 (LI=0, VN=4, Mode=3)
- Remaining 47 bytes are all zeros

### B. Fallback behavior

`reliableNow` tries NTP twice then falls back. Testing the actual NTP path is
flaky (network-dependent), but we can test:

**mockTimeProvider tests:**
- `tpNow` returns the exact fixed time
- `tpStartTime` returns fixed time minus 500ms
- Two calls to `tpNow` return the same value (no drift)

**systemTimeProvider tests:**
- `tpNow` returns a time close to current time (within 1 second)
- `tpStartTime` < `tpNow` (start time is earlier)
- Difference between `tpNow` and `tpStartTime` is approximately 500ms

**reliableTimeProvider smoke test:**
- Returns a TimeProvider successfully (may or may not use NTP)
- `tpNow` returns a time within 5 seconds of system time
- `tpStartTime` < `tpNow`

### C. Timeout behavior

Hard to test without mocking the network layer. Document as manual verification.
The key property: `ntpTimeoutMicros == 2_000_000` (2 seconds).

## Implementation

### Step 1: Create Internal module

Move `parseNtpResponse`, `getWord32`, `ntpRequest`, `ntpTimeoutMicros` exports
to `Iidy.Aws.Timing.Internal` (or just export them from `Iidy.Aws.Timing` —
simpler, and these are not security-sensitive internals).

**Recommended**: Just add the needed functions to the export list of
`Iidy.Aws.Timing`. This is simpler and follows the project's existing pattern
(no Internal modules exist).

### Step 2: Create test file

`test/Test/TimingTest.hs` with three groups:
- `testGroup "NTP packet parsing" packetTests`
- `testGroup "TimeProvider behavior" providerTests`
- `testGroup "Constants" constantTests`

### Step 3: Wire into test/Main.hs

## Codebase Reference

| What                  | Where                                      |
|-----------------------|--------------------------------------------|
| `Iidy.Aws.Timing`    | `src/Iidy/Aws/Timing.hs`                  |
| `parseNtpResponse`   | `src/Iidy/Aws/Timing.hs:104`              |
| `getWord32`          | `src/Iidy/Aws/Timing.hs:119`              |
| `ntpRequest`         | `src/Iidy/Aws/Timing.hs:98`               |
| `mockTimeProvider`   | `src/Iidy/Aws/Timing.hs:130`              |
| `systemTimeProvider` | `src/Iidy/Aws/Timing.hs:39`               |
| Rust reference       | `~/src/iidy/src/aws/timing.rs`             |
| Test wiring          | `test/Main.hs`                             |
| Shared test helpers  | `test/Test/Shared.hs` (uses testTimestamp) |

## Build/Test Commands

Per CLAUDE.md.

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet
- **Why**: Straightforward test writing. Pure functions with clear expected values.
  Provider tests are simple smoke tests. The only decision is whether to export
  internals — recommendation is to just expand the export list.

## Progress

- [ ] Export parseNtpResponse, getWord32, ntpRequest, ntpTimeoutMicros from Timing module
- [ ] Create test/Test/TimingTest.hs with packet parsing tests
- [ ] Add TimeProvider behavior tests
- [ ] Add constant verification tests
- [ ] Wire into test/Main.hs
- [ ] Build clean + all tests pass
