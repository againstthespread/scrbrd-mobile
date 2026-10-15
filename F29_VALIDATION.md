# F29 — runtime lifetime and logical Bluetooth ownership

## Runtime lifetime (first commit)

The app root created a provider repository on every build while the connection
screen's coordinators retained the original repository. A second confirmed defect
allowed an outstanding fantasy observation to notify/send after disposal.

Regressions were added before implementation: both failed in
`build/f29-lifetime-before.log` (the failed widget test also left cleanup timers,
causing one cascading failure). The same tests pass after the fix.

The app state now owns one repository for its lifetime. Factory-created sources
are explicitly owned and closed once; injected sources and HTTP clients remain
borrowed. The connection screen consistently uses its initial dependency graph;
replace its widget key when intentionally creating another runtime. Disposal
invalidates startup/fantasy work. Projection callbacks from an older generation
or disposed coordinator cannot schedule a display refresh.

Validation at this commit: 171 focused tests passed, including late projections,
resource ownership, disposal during observation, H01 foreground recovery and desired
content recovery. Static analysis: no issues. Protocol and lifecycle foreground /
background behavior are unchanged. Final full-suite and iOS results follow in the
logical ownership commit.

## Logical Bluetooth transaction ownership (second commit)

All production Bluetooth send entry points now use one connection-owned queue.
A lease spans the entire sports/golf/fantasy transfer, including start, every
chunk/entry, and end. Prepared startup catalog writes hold the same lease across
SYNC_START, all categories and SYNC_COMPLETE/SYNC_EMPTY. Explicit multi-league
sends also hold one lease. Nested sends join the current lease; late asynchronous
callbacks cannot reuse an expired lease or acquire ownership on a new connection.
No protocol bytes, dependencies, state-management frameworks or polling were added.

The queue permits one active transaction plus 16 waiting transactions, in FIFO
order. Overflow fails explicitly; it never silently drops a user send. Manual
requests wait for the current complete transfer rather than interrupting device
staging. Existing WAKE/FCM coalescing retains one follow-up refresh. Fantasy slate
replacements validate freshness at admission and omit superseded queued content.
Provider preparation and the follow-up fantasy baseline observation occur outside
Bluetooth ownership; the existing standalone fantasy commit API is preserved.

Connection invalidation cancels active and waiting callers immediately. Old
provider work cannot hold the new session's operation gate, clear its owner or
resume its writes. Cancellation registrations are removed when operations finish.
Each native write has a 10-second deadline; timeout fails the connection and
releases all waiting callers. Late native completion cannot restore connected
state or continue the cancelled transfer. App foreground/background transitions
retain the H01 subscription behavior.

Delivery bookkeeping remains conditional on completed writes. Failed alerts stay
retryable within their valid observation session. F18's new-session baseline and
stale-alert suppression remain intact. Automatic refreshes recheck their baseline
after queue admission, preserving a newer manual selection. Startup performs this
check both after provider preparation and after queue admission; superseded startup
ends with a deferred status and retries as reconciliation from the new selection.
Queue rejection cannot report a successful empty refresh. Cached content and the
F20 provider/write freshness distinctions remain covered by regression tests.

## Before / after evidence

Each confirmed defect below had a failing regression before its implementation.
Logs are local, ignored build artifacts; this table preserves their results.

| Regression group | Before | Final |
| --- | --- | --- |
| Repository replacement and disposed observation (`f29-lifetime-before.log`) | 2 intended failures; 1 cascading cleanup failure | Pass |
| Competing sends and unresolved native-write cancellation (`f29-transactions-before.log`) | 2 failures | Pass |
| Cancelled sports fetch blocks next refresh (`f29-refresh-before.log`) | 1 failure | Pass |
| Reconnect startup waits for obsolete fetch (`f29-startup-before.log`) | 1 failure | Pass |
| Old fantasy observation blocks new session (`f29-fantasy-before.log`) | 1 failure | Pass |
| Manual selection supersedes startup preparation / admission (`f29-manual-startup-before.log`) | 2 failures | Pass |

Additional coverage includes bounded queue overflow, nested transactions, expired
callback leases, superseded pending work, failed-owner release/retry, native write
timeout, atomic startup catalog boundaries, provider observation outside ownership,
automatic bursts competing with manual/alert/projection traffic, queued alert
failure/retry and latest-only queued fantasy display updates. Existing F01/F02
packet-boundary disconnect/reconnect tests and H01/F07/F08/F18/F20 tests pass.
Two old tests expecting overlap rejection now verify successful serialization;
the existing refresh test that replaced a baseline during another league's send
now verifies that the newer baseline is preserved.

## Final validation

- Focused suite: **334 passed**, `build/f29-focused.log`.
- Complete Flutter suite: **952 passed**, `build/f29-full-suite.log`.
- Previous F20 baseline: **926 tests**; F29 adds **26** tests.
- `flutter analyze --no-pub`: **no issues**, `build/f29-analyze.log`.
- `flutter build ios --release --no-codesign --no-pub`: **passed**, final build
  17.0 seconds, `build/ios/iphoneos/Runner.app` 25.1 MB,
  `build/f29-ios-build.log`.
- `git diff --check`: passed. All edits are in `scrbrd-mobile-codex` on
  `codex/h01-wake-recovery`. `main` remains
  `7785c601fb733369b8dd3057722460de6e96d733`.
- No Lab reinstall, deployment, ESP flash, dependency changes or physical tests.

## Limits and required physical verification

A completed BLE write is a transport fact, not proof that the ESP processed,
committed or displayed the data. There are no application acknowledgments or new
receipt packets. An already-issued native write cannot be retracted. Failed
partial transfers may leave device staging until the next compatible start/reset;
actual device content must be checked visually. Superseded provider requests may
finish under their existing HTTP timeouts; their results cannot send or re-verify
an obsolete observation. Background execution remains subject to iOS scheduling.
The console/test transport compatibility fallback does not own Bluetooth hardware.

Physical verification is still required on a separately approved F29 Lab build
and the existing compatible ESP firmware, without changing protocol or flashing:

1. With Lab foregrounded, overlap automatic refreshes, a manual sports/golf or
   multi-league send, fantasy Primary/preview changes, a projection completion and
   a real scoring alert. Verify contiguous transaction boundaries in diagnostics,
   no normal-load busy rejection, one coalesced follow-up refresh, and the final
   correct device content. Confirm manual controls remain responsive while writes
   wait and that the latest explicit selection survives older prepared refreshes.
2. Disconnect at start/chunk/end boundaries with additional sends waiting, then
   reconnect. Verify cancellation of old-generation work, successful current-session
   startup and WAKE refresh, and no old continuation writing on the new generation.
   Repeat foreground/resume transitions during pending provider and BLE work;
   export diagnostics before any recovery action if progress stops.
3. Interrupt internet and restore it while Bluetooth stays connected. Verify cached
   content remains, failed fetches do not advance successful freshness timestamps,
   and recovery resumes automatically. Exercise a delivery failure: same-session
   fantasy alerts remain queued/retryable, while reconnect establishes a fresh
   baseline under F18 rather than replaying obsolete alerts.
4. Observe a real game/score and projection change against a reference. Record
   visual ESP updates and latency separately from provider and BLE-write timestamps.
   Run a 30-minute mixed-traffic hold and check for disconnects, stalls, duplicate
   alerts and persistent waiting transactions. Successful app diagnostics alone
   cannot satisfy this device-display verification.
