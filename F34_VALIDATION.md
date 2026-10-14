# F34 — Mobile/firmware integration validation

Baseline mobile `f287d66`, firmware `1c38d8c`. Experimental branches only.
No dependency/API/UUID/packet-format changes, push, merge, main changes or flash.
The combined detailed report is `F34_SYSTEM_INTEGRITY_AUDIT.md` in the firmware
worktree's existing nested `scrbrd/` directory.

## Confirmed mobile fixes

- **P1:** Sports/golf transfers could cross reconnects or report obsolete final
  writes as successful. `BluetoothDeviceTransport._sendTransferPackets` extends
  existing fantasy generation protection to complete logical transfers;
  `_sendPacket` now throws cancellation for stale completion. Previously valid
  baselines stay intact. Six start/chunk/end reconnect regressions, stale single
  completions, active fresh ownership and retries are covered.
- **P1:** `SportsOperationGate.runInitialSync` discarded startup during an older
  sync and could overlap refresh ownership. Startup is queued and prioritized;
  it waits for active refresh completion. `InitialDeviceSyncCoordinator` skips
  obsolete queued generations and stale destructive/terminal status updates.
  Rapid reconnect, blocked fetch, queued WAKE and operation exclusivity are tested.
- **P1:** `FantasyLiveObservationCoordinator.syncStartupCategory` could finish
  old provider work into a new session. It now guards reconciliation, provider
  startup, built slate and final baseline work by captured generation. Sleeper
  and ESPN regressions cover interrupted fetches.
- **P2:** An empty fantasy slate incorrectly counted as a loaded category.
  Slate-capable startup now returns availability based on nonempty content;
  legacy baseline behavior remains. Legal empty transfers still clear Fantasy.

## Results

- **591 full Flutter tests passed**, static analysis **no issues**.
- Final focused expectations replayed against an untouched `f287d66` snapshot:
  **16 failures among 130 focused tests**; corrected current suite passes.
- Actual production serializers export a fixture consumed by native firmware:
  advertising name/UUID agreement, **18 steps, 112 packet operations**, including
  one deliberately malformed end plus incomplete/timeout cases. Covers 72 games,
  50 golfers, eight fantasy matchups, selection/Primary, standby and MLB/NFL state.
- Companion firmware's nine test entry points and ASan/UBSan/TSan checks passed.
  Final ESP32 normal build: **780,373 flash / 139,912 static RAM bytes**;
  timing build: **784,997 / 140,608**. These are compilation/native results;
  F34 was not physically tested here.

```sh
SCRBRD_PROTOCOL_FIXTURE=/tmp/scrbrd-protocol.json flutter test --no-pub test/firmware_protocol_compatibility_test.dart
flutter test --no-pub
flutter analyze --no-pub
# From the firmware worktree root, where source is nested in scrbrd/:
python3 scrbrd/test/mobile_protocol_compatibility_test.py /tmp/scrbrd-protocol.json
```

## Remaining priorities requiring review/qualification

1. **P1, confirmed:** ATT success is not device validation/commit acceptance;
   failed delivery can advance phone baselines. Receipts/transfer completeness,
   retry/idempotency and alert backpressure need protocol review.
2. **P1, confirmed:** refresh only follows delivered original-date/tournament
   baselines; initially absent/failed categories and day/tournament rollover lack
   recovery. Destructive startup clears cache before fetch succeeds, and fantasy
   provider failures collapse into omitted/empty results. Consumer-versus-history
   intent and empty-versus-unavailable reconciliation need a state/policy decision.
3. **P1, confirmed:** canonical-player alert aggregation can count transitions as
   leagues and consume multiple deltas behind the first presentation. Agree on
   presentation and pacing into the firmware's 16-entry waiting FIFO before changing it.
4. **P2, unverified hardware risk:** actual heap/stack margin, SPI latency,
   weak-RF reconnects and locked/background iOS behavior require bench testing.
   iOS declares Bluetooth central background mode; declaration is not qualification.

A cancelled old provider operation can delay queued startup until it finishes;
current clients have 10/12-second per-request timeouts, and multi-provider work
can take longer. No request was dropped to disguise that latency. Preserve the
working F33 responsiveness and use the firmware report's ESP #2 checklist after
separately authorized installation. No device was flashed during this assignment.
