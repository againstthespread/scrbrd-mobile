# F07 — Preserve cached content through failed reconnection

Scope: F07 only, building on the existing F03/F04, F11, F18 and F37 fixes.
No dependencies, BLE packet formats, version, UUIDs or `SYNC_START` semantics
changed. Main and prior experimental commits are preserved.

## Changes

- `InitialDeviceSyncCoordinator` fetches and snapshots sports/PGA/Fantasy and
  validates replacement packets before the existing destructive reset. Provider
  failure and validation failure remain unknown data, not empty schedules. Neither
  the device catalog nor phone tracked baselines are cleared on those failures.
- During partial failure, complete nonempty sports/PGA categories can still
  commit independently. Fantasy is a single atomic category: any unavailable
  configured member holds the entire previous Fantasy slate, including successful
  peers, rather than erasing the unavailable member. Baselines and asynchronous
  projection refreshes cannot send a partial slate around startup preparation.
- Genuine empty Fantasy configurations can clear intentionally even during a
  sports failure. Disabled Fantasy uses the existing clear packet. Empty/disabled
  sports removals are deferred until all enabled providers are known; existing
  packets cannot selectively clear those categories. A fully known replacement
  reconciles removals, and a completely empty result still uses `SYNC_EMPTY`.
- Failed attempts remain retryable regardless of previously tracked categories.
  Existing WAKE, foreground and FCM triggers retry the full desired startup
  snapshot; simultaneous triggers share one attempt through the existing gate.
  Ordinary refreshes queued during a failed startup cannot overwrite the retained
  Fantasy slate. Once reconciliation succeeds, normal refresh behavior resumes.
- The phone reports `Updates incomplete; cached data unverified`. The companion
  firmware change tracks verification per received category and keeps its cached
  warning after reconnection until an actual valid replacement commits. Successful
  categories in a partial sync can show verified content independently.

## Regression evidence and results

Four focused tests failed before implementation: destructive reset during a
pending fetch, loss of cached device/phone data on provider failure, loss of peers
on partial success, and reset before invalid replacement data was rejected. The
firmware display-state harness also failed before implementation: reconnection
incorrectly made retained content live without replacement.

New/extended regression coverage checks offline reconnect, retained phone and
device categories, malformed/oversize replacement rejection, independent sports
updates, full recovery, known-empty and disabled-category clearing, repeated retry
coalescing, transfer failure/retry, cached Fantasy peers, asynchronous projection
completion during preparation, an already in-flight display fetch acquiring a
startup hold, and intentional empty/disabled Fantasy clearing.
The actual connection widget/transport test checks offline reconnect, cached
warning, a ten-WAKE burst sharing one recovery fetch, restored transfer and normal
refresh resumption alongside the previous subscription/foreground recovery tests.
Golf gate tests compare content rather than object identity because preparation
now snapshots fetched data. Existing alert/scoring tests remain unchanged.

Passed:

- Focused startup/Fantasy/alert/widget/Home tests: 157.
- Sports operation gate tests: 15.
- Complete Flutter suite: 635 tests.
- `flutter analyze`: no issues.
- All ten native firmware entry points, including cache verification, actual
  parser/lifecycle compatibility, concurrency and simulated timing. Applicable
  native harnesses passed AddressSanitizer/UndefinedBehaviorSanitizer; timing-on
  responsiveness also passed. Current mobile fixture: 18 steps/112 packets.
- ESP32-S3 compilation with core 3.3.11, ArduinoJson 7.4.3 and GFX 1.6.7: flash
  780,585/1,310,720 bytes (+212), static RAM 139,912/327,680 bytes (unchanged).
  Linker remainder is 187,768 bytes, not measured runtime free heap.

Reproduce in this worktree:

```sh
flutter test test/initial_device_sync_coordinator_test.dart test/fantasy_multi_league_runtime_test.dart test/fantasy_alert_runtime_test.dart test/wake_foreground_recovery_test.dart test/home_ui_test.dart
flutter test test/sports_operation_gate_test.dart
flutter test
flutter analyze
```

Logs and before-fix failure evidence are under `/tmp/scrbrd-f07/` (temporary,
uncommitted). See the firmware `F07_VALIDATION.md` for native/build commands.

## Protocol and execution limitations

This is compatible mitigation, not whole-catalog transactionality. The existing
`SYNC_START` still immediately clears the received catalog. If BLE fails after
that reset, failed/untransferred categories cannot be rolled back. An ATT write
response does not prove parser acceptance or display commit. Transaction IDs,
receipts, catalog rollback, targeted sports clears, per-matchup Fantasy freshness
and explicit verified-at timestamps need a separately reviewed protocol proposal;
none were added here.

The phone can retain cache on older flashed version-1 devices without new packets.
Those devices still lack the companion firmware's per-category unverified label;
use the phone warning until the new experimental firmware is qualified. Verification
means a replacement was committed in this connection, not an assurance of upstream
provider correctness or a wall-clock age guarantee.

Retry is bounded by existing refresh triggers and uses no additional polling loop.
Recovery still requires a live BLE connection and an executing phone app; iOS
suspension/termination and unavailable notifications are not new guarantees. No
midnight rollover or unrelated live-refresh redesign is included.

## Physical verification remaining

No hardware was flashed. On positively identified ESP #2 in a later authorized
bench session, record both experimental commit IDs, preload multiple sports/PGA
and Fantasy entries, reconnect with internet disabled, and confirm cached content
remains navigable with the phone/device warnings. Fail one provider and verify
other sports update while cached failed categories retain warnings and Fantasy
peers remain intact. Restore internet without a BLE reconnect; exercise WAKE and
foreground recovery separately, including burst notifications. Verify intentional
Fantasy removal, deferred sports removal and genuinely empty schedules. Repeat
while navigating, in standby and during alert overlays, then interrupt staging and
exercise RX loss/recovery. Check physical pixels/UART receipt logs, heap/stack
watermarks and resets; successful phone writes alone are insufficient. Also test
the new phone against previously flashed firmware for packet compatibility and
expected old-UI limitations. Detailed steps are in the firmware validation file.
