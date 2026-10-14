# F18/F37 — WAKE recovery and fantasy startup outcomes

Scope: experimental `scrbrd-mobile-codex`, baseline `e07384f`. Previous fixes and
commits are preserved. No firmware, BLE packet/UUID, dependency, or main changes.

## F18 — bounded subscription recovery

`BluetoothDeviceTransport` tracks inactive/subscribing/listening/retrying/failed
subscription health. Error, unexpected stream completion and synchronous subscribe
failure all enter the same recovery path. Automatic retries use 1, 2 and 4 second
backoffs, at most three retries per physical connection or explicit foreground
recovery cycle. Receiving data or duplicate connected events does not replenish
this budget. Exhaustion preserves the connection and exposes an automatic-refresh
warning on Home; it does not schedule another automatic retry loop.

Cancellation precedes replacement subscription and is bounded by a three-second
wait. Connection generations and subscription epochs reject obsolete values,
errors, completion and pending recovery work. Disconnect, transport error and
disposal invalidate ownership and cancel recovery timers. Concurrent explicit
resume requests share one recovery future. No callbacks parse or send scores.

A real transition back to resumed renews the subscription and requests one
freshness refresh through the existing `SportsOperationGate`. Repeated resumed
notifications are ignored. Existing startup ownership and WAKE/refresh coalescing
remain: bursts during startup or an active refresh cause at most one pending
follow-up; operations never overlap. Disconnected resumes do not refresh.

Listening means a Dart listener is installed, not that native CCCD state or RF
reception has been independently acknowledged. A stream that silently stops
producing without error/completion is renewed on foreground resume; this change
adds no continuous background polling/watchdog. Native iOS behavior requires the
bench checks below.

## F37 — empty, loaded and failed are different facts

F34 already made an empty slate return false for loaded content. That fix remains.
The remaining defect was hidden provider failures: the builder omitted errors,
so all-failed startup appeared empty and partial failure appeared complete.

The builder now exposes entries plus provider-qualified failures; existing
`build()` callers retain their list API. Startup returns structured content/error
facts to the initial-sync coordinator. The boolean `syncStartupCategory()` wrapper
remains for existing callers. Alert baselines still initialize without historical
alerts, including when a slate write fails. Existing session guards are retained.

| Actual startup result | Phone status | Existing BLE terminal command |
| --- | --- | --- |
| No loaded content, no failures | empty | `SYNC_EMPTY` |
| Loaded content, no failures | complete | `SYNC_COMPLETE` |
| Loaded content and failures | partialFailure | `SYNC_COMPLETE` |
| No loaded content and failures | failure | Neither success nor empty |

Unconfigured/unselected Fantasy still transmits a legitimate empty slate to
clear Fantasy. All-provider failure does not transmit a false empty clear.
Partial success sends its valid entries and reports the omitted failures.
Matchup/slate ordering, scoring, alert aggregation and packet formats are unchanged.

There is no failure-specific command in the current BLE protocol. In the last
row the phone reports failure, while firmware may remain connected/loading until
another successful synchronization. No false empty/no-games claim or new packet
was introduced. A dedicated device failure presentation needs protocol/product
review. Existing wider category rediscovery/reconnect policies are outside scope.

## Regression evidence

Before implementation: five failures and two passing genuine-empty controls in
`/tmp/scrbrd-f18-f37/before-tests.log` (temporary). Failures reproduced error/done
subscription loss and all-failed/partially-failed Sleeper/ESPN startup classification.

Sixteen added tests cover error/done/synchronous failure, bounded exhaustion,
resume single ownership, recovery after exhaustion, data/duplicate-connect budget
stability, disconnect/cancellation races, obsolete stream isolation, disposal,
visible warnings, real widget lifecycle/coalescing, genuine empty clearing,
provider failures, partial fantasy content, and sports plus failed Fantasy.

Passed:

- 158 focused tests across transport, startup, fantasy runtime/builder, Home and
  foreground lifecycle.
- Complete Flutter suite: 620 tests, including previous F03/F04/F09/F10/F11 fixes.
- `flutter analyze --no-pub`: no issues.
- `git diff --check`: clean.

## iPhone and ESP #2 verification still required

No hardware was flashed or physically tested. With an authorized experimental
pair, exercise native notification/CCCD failure and stream termination, the three
backoffs/exhaustion warning, and foreground recovery. Check that only one WAKE
subscription remains and refreshes continue without duplicate sends. Repeat
background/lock/unlock, rapid disconnect/reconnect, and resume during startup or
active refresh; verify the firmware's periodic WAKE still drives updates.

Test Fantasy-only with no config, no selected teams, all providers failing and a
mixed successful/failed set; repeat with valid sports content. Confirm deliberate
empty clearing, correct phone status/category count, partial display content and
absence of false success/empty completion. Inspect the zero-content failure case
on the display under the unchanged protocol limitation above.
