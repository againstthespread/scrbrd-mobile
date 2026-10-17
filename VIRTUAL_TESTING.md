# Virtual integration testing

Run from any directory, with the mobile and firmware testing branches checked out:

```sh
python3 /path/to/scrbrd-mobile/tools/run_virtual_tests.py \
  --firmware /path/to/scrbrd
```

For the worktrees created during implementation:

```sh
python3 /private/tmp/scrbrd-virtual-mobile/tools/run_virtual_tests.py \
  --firmware /private/tmp/scrbrd-virtual-firmware
```

Both repositories use branch `codex/virtual-integration`, created independently
from local `main` (mobile `07ccb26`, firmware `fe254aa`). Neither branch includes
unmerged F13 commit `49d5f0b`. Existing F13 and hardware-validation worktrees,
Lab1009/1010 artifacts, configurations and documentation are preserved.

## Prerequisites and output

Use the project's existing Flutter/Dart SDK, Python 3, a C++17 compiler (`c++`),
and ArduinoJson headers. These are the same requirements as the existing native
harnesses. Set `ARDUINOJSON_INCLUDE=/path/to/ArduinoJson/src` if needed; otherwise
headers are read from `~/Documents/Arduino/libraries/ArduinoJson/src`.
Flutter packages must already be cached. The command runs
`flutter pub get --offline --enforce-lockfile`; it does not upgrade dependencies,
install apps, use a simulator, initialize Firebase, contact providers, or flash hardware.
A fresh machine needs the normal Flutter package/toolchain setup first.

The default command runs:

1. Native bridge build and ten mobile ↔ firmware integration scenarios.
2. Existing Dart serializer fixture export and native protocol compatibility test.
3. Complete Flutter suite (including the virtual scenarios) and static analysis.
4. All existing firmware Python native runners and both standalone C++ tests.

`--quick` runs only steps 1–2 plus dependency preparation. `--output /path/to/report`
changes the output directory (default `build/virtual-testing` under mobile).
`report.txt` is concise; `report.json` records steps, exit codes, durations, source
revisions and working-tree status. Per-step logs and `scenario-N-transcript.json`
record requests, exact transmitted bytes and native state responses. A required
failure makes the overall command exit nonzero; dependent steps are marked BLOCKED.
Reports are local build artifacts; no reporting service is contacted.

Running plain `flutter test` without `SCRBRD_VIRTUAL_DEVICE` still runs every
preexisting test, but explicitly skips these ten native-backed scenarios. Use the
command above for a complete virtual run; a bridge build failure cannot silently
turn it into a passing skipped integration run.

## What is real and what is simulated

The test backend in `test/virtual/support/virtual_ble.dart` supplies the existing
`BluetoothDeviceTransport` scan, connection, write and WAKE factory seams. It does
not replace the production transport: packet serializers, transaction queue,
session-generation cancellation, WAKE subscription health, initial sync,
session-aware sender, live-refresh coordinator and sports ownership gate execute
production code. The harness supplies the connection/WAKE coordinator wiring;
it does not boot the full app or render Flutter screens.

Every accepted mobile packet is delivered over local JSON-lines stdin/stdout to
one persistent native process per scenario. Firmware's
`test/virtual/build_bridge.py` reuses `test/responsiveness_test.py`: actual sketch
packet handlers, transfer interruption/expiration logic and `GameManager.cpp`
are compiled together. Replies inspect the firmware's real committed catalog,
selected event/matchup, score, staging and verification state. Navigation invokes
actual `GameManager` navigation. There is no Dart copy of firmware parsing or storage.
The firmware BLE queue, clock, buttons and display are the existing host stubs;
this bridge is a test protocol, not a new BLE packet format.

`fixtures/season.json` supplies a fixed UTC date, normalized NBA/MLB slates and
ESPN/Sleeper-style fantasy totals. `FixtureSource` implements the existing sports
provider boundary, with scripted score changes and outages. Fantasy fixtures enter
the prepared-startup boundary, then use the production fantasy serializer and native
packet handlers. Live provider HTTP parsing, credentials, lineup discovery and
projection calculations are not part of this harness (existing unit tests remain).
F28 is unchanged and deferred pending commercial licensing.

## Scenarios and faults

- Initial synchronization commits two sports categories and Fantasy; sports and
  fantasy selections survive ordinary refreshes.
- WAKE triggers score replacement and serialized/coalesced refreshes. Foreground
  subscription resume keeps the healthy listener.
- Dropping a sports chunk retains the previous native slate. The test deliberately
  observes the mobile/native disagreement after a successful write: native write
  completion is not an ESP application acknowledgment. It does not claim this
  existing protocol limitation is fixed.
- Disconnect while a chunk is held cancels staging and stale mobile work; a scripted
  reconnect performs normal sync and resumes WAKE-driven updates. Releasing the old
  write cannot restart its transaction or overwrite the new session.
- Native write errors retain mobile delivery cache; a new session recovers.
- Held writes time out; after link invalidation their late completion cannot deliver.
- Device absence/adapter-off leaves the baseline disconnected; scripted restoration
  and reconnection resume sync without silently inventing an automatic retry policy.
- Provider outage retains the cached firmware catalog; retry recovers.

For new cases, create a fresh `Harness`, change fixture scores/failures and set
`ble.faults[ble.packets.length + N]` to `Fault.drop`, `fail`, `disconnect` or `hold`
(the index is one-based at the native write boundary). `ble.release()` completes a
held operation, `writeDelay` adds write latency, `available`/`ready` control discovery
and adapter state, `disconnect()` interrupts the native and mobile sessions,
`connect()` scripts central connection, and `notifyWake()` injects a notification.
Native `advance` requests advance the firmware stub clock for transfer expiration.
Clock advancement is explicit; it is not a physical latency measurement. Mobile
production transfer IDs still use the wall clock, so transcripts vary in IDs and
trace timings even though fixture values, fault positions and assertions are fixed.

## Limits and next steps

This first environment is a component integration harness, not full UI automation
or an ESP32 emulator. It cannot validate BLE radio range/interference, ATT delivery,
MTU negotiation, OS permission prompts, CoreBluetooth scheduling/cancellation,
BluetoothManager's real RX queue task concurrency, device identity across iOS
reinstalls, power usage, real buttons, LCD performance or visual correctness.
Existing standalone native tests still cover the RX queue and render logic with stubs.

Local main has no F13 automatic reconnection policy. Here reconnects are scripted;
no claim is made about exponential backoff, remembered-device persistence or
intentional-disconnect suppression. Once F13 is approved/integrated, extend the same
plugin boundary with its status stream/store inputs and fake-clock retry tests;
do not duplicate the policy in this backend. The unfinished F13 physical tests
remain pending; virtual results do not retroactively pass them.

Native iOS Bluetooth state restoration, suspended/terminated relaunch, background
reconnection and physical display performance still require separate native/physical
validation. No physical hardware automation is implemented.

## Implementation verification

The initial implementation passed all 18 runner steps on 2026-10-17: ten virtual
scenarios, 962 total Flutter tests, clean static analysis, 18 existing protocol
compatibility fixture steps, all seven Python native runners and both standalone
C++ tests. The final full-run report is preserved in
`build/virtual-testing/final/report.txt` with logs/transcripts alongside it.
Generated reports are intentionally excluded from Git. No firmware/iOS device build
or installation is required for this host-only environment. These results apply to
the baseline and test changes, not to unmerged F13 or physical Bluetooth behavior.
