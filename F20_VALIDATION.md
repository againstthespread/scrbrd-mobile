# F20 — Accurate delivery success and data freshness

Scope: F20 only, on `codex/h01-wake-recovery` in `scrbrd-mobile-codex`, based on `8707047e0a3e67a8bd8a7ad971abe54e0fd59043`. Reference: F20 in `PRODUCTION_READINESS_AUDIT.md`. Existing H01, F01/F02, F07/F08 and later fixes were inspected and retained. No BLE packet, UUID, acknowledgment, dependency version, firmware or production-main changes. No installation or physical device actions were performed.

## Confirmed defects and regressions

Before implementation, four new tests compiled and all four failed because `FantasyObservationResult.succeeded` was `true` for:

1. A failed legacy fantasy matchup write.
2. A failed fantasy slate write.
3. A failed fantasy alert write with the alert still pending.
4. A cancelled observation whose connection generation changed while fetching.

The same four regressions pass after implementation. The failed matchup/slate/alert tests also verify that later observations retry successfully. Baseline log: `build/f20-before.log`.

## Corrections

- Persistent matchup, slate, clear and alert delivery failures now reach observation outcomes instead of being swallowed as success. Provider-error-free observation, queued delivery, unchanged content, completed writes, failed delivery and cancellation are separate facts. Skipped concurrent observations and cancelled generations cannot report success. Per-league pending counts reflect the queue after attempted delivery.
- Fantasy alert entries are removed only after successful transport completion, with the original generation, store and pending-entry identity still valid. Failed alerts remain pending for retry in the existing session. Failed persistent writes do not advance deduplication baselines; the next ordinary refresh can retry. No new reconnect/replay policy is introduced.
- Sports refreshes return per-league outcomes. Provider and transport failures, retained empty/shrinkage candidates, cancellation and skipped work are not reported as fully successful refreshes. Existing unchanged-data suppression, filters, gate ordering and cached-content policies remain.
- A native write that resolves after connection invalidation is logged as `write.cancelled`, never first as `write.completed`. The F01/F02 characteristic and generation checks remain. H01 listener preservation, native cleanup barrier, 75-second foreground silence detection and bounded retry behavior are unchanged.
- Existing Refresh diagnostics and COPY now include bounded, app-session freshness snapshots: latest provider/delivery states and attempts, last successful provider fetch, last completed logical BLE write, and corresponding scopes. Sports are separated by league, fantasy provider fetches by provider-qualified league, and fantasy slate/matchup/alert/clear writes by operation. Successful historical scope is retained separately from a newer failed scope.
- Only accepted successful provider operations advance fetch timestamps. Cancelled/superseded fetches do not. Valid empty responses are explicitly labeled `empty`; they do not verify the retained cached slate. Cached writes do not advance provider freshness. Unchanged data advances provider-fetch time but never the last-write time. Failed/cancelled writes preserve the previous successful-write timestamp. A newer rejected send cannot hide an older write that actually completes.
- Freshness facts survive event-ring eviction and timeline CLEAR, but not app termination. The summary is bounded to 64 keys; event history remains 512 entries/240 characters per message. Diagnostics use structural states and identifiers, not provider exception text, payloads, cookies, tokens or credentials. No timer or polling was added.
- Automatic refresh execution diagnostics now distinguish completed work containing failures/retained data from successful refreshes. Background dispatch acknowledgment remains a handling/queueing acknowledgment; console text no longer presents it as fetch/delivery success. FCM routing and gate coalescing are unchanged.

## Verification

| Check | Result |
| --- | --- |
| Four original F20 defect regressions | Before: 4 failed; after: 4 passed |
| Focused delivery/freshness/transport/startup/gate/desired-content tests | 308 passed |
| Complete Flutter suite | 926 passed; previous documented baseline 899; 27 added tests |
| `flutter analyze --no-pub` | No issues |
| `flutter build ios --release --no-codesign --no-pub` | Passed; unsigned release arm64 `build/ios/iphoneos/Runner.app` (25.1 MB), Xcode build43.6seconds |

Focused command includes `data_freshness_test`, `fantasy_alert_runtime_test`, `fantasy_multi_league_runtime_test`, `live_refresh_coordinator_test`, `initial_device_sync_coordinator_test`, `background_score_refresh_test`, `refresh_diagnostic_history_test`, `session_aware_device_sender_test`, `bluetooth_device_transport_test`, `sports_operation_gate_test`, and `desired_content_refresh_test`.

Additional regressions cover sports/fantasy provider failures, failed and cancelled writes, clear retry, alert retry, unchanged scores, empty responses, startup cached-baseline reuse, mixed successful peers with failed ESPN/cached content, disconnected queued slates, superseded responses, concurrent rejected sends, diagnostics rendering/export, bounded storage and timeline CLEAR. All H01 transport regressions run unchanged except for one added F20 cancellation-reporting test. Preserved logs: `build/f20-focused.log`, `build/f20-full.log`, `build/f20-analysis.log`, `build/f20-ios-release.log`.

## Limits

A completed BLE write means the phone transport completed the existing write-with-response operation(s), including all packets for a logical slate. It does **not** prove ESP application acceptance, commit, processing or display. No application-level receipts were added. Partial writes may have reached the ESP even when the logical delivery fails, so retries cannot provide exactly-once display guarantees.

Freshness timestamps describe phone-observed activity, independently of content currently visible on the ESP. A successful provider fetch can return unchanged or empty data; a cached send can complete while a provider is failing. Provider error-free observation/baseline reuse alone is not a new provider verification: the actual fetch timestamp/state is the freshness evidence. No arbitrary age threshold is used to claim data is live. Historical timestamps do not establish current connection/device state, and app termination returns tracking to unknown.

The existing fantasy policy resets alert observation queues on a connection-session reset. This change preserves retries within a session and persistent-content resynchronization after reconnect; it does not introduce historical alert replay across reconnects (F26 is separate).

## Physical verification still required

Use a separately approved F20 candidate installation; do not treat the earlier Lab1008 H01 hardware run as verification of these new changes. No install is authorized or performed by this task.

1. With internet/Bluetooth on and a known changing game plus configured fantasy leagues, export Refresh diagnostics. Compare actual ESP/reference values and delay. Confirm fetch timestamps advance, and logical write timestamps advance only after complete writes. Summary must continue to say ESP unconfirmed.
2. Observe several unchanged WAKE cycles: provider fetch time should advance, write time should stay unchanged, and duplicate slates/alerts should not appear.
3. Disable internet with BLE connected: useful cached content must stay visible; failed fetch attempts must not renew successful-fetch time. Restore internet on the same BLE connection; ordinary refreshes should recover and transmit only changed content. Include an offline reconnect/restore spot check for F07/F08 preservation.
4. During a controlled sports/fantasy slate write, disconnect at early, middle and final-packet boundaries. Export before restarting. Cancelled/failed logical delivery must not advance its successful timestamp or cached baseline. Reconnect should resynchronize normally, with no stale-generation success. Physical partial-device state remains unconfirmed without future approved receipts.
5. Under a controlled same-session alert-write failure, capture failed delivery plus pending count, then verify the next ordinary WAKE retries and clears only successfully written pending entries. A physical connection reset continues to follow the existing queue-reset policy.
6. Repeat healthy foreground/background returns and three reconnects, then a 30-minute changing-reference hold. Require existing H01 listener preservation, continued raw WAKE receipt, bounded recovery if genuine silence occurs, and no false freshly-verified labels after failed/cancelled work. Capture any recurrence before reconnect/reset; do not alter firmware to induce silence.
7. Exercise diagnostics COPY/navigation/CLEAR on the phone: timeline clear must not manufacture or erase freshness facts, and app termination must start unknown freshness rather than inventing persisted verification.
