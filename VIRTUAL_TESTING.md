# Virtual integration testing

From the mobile checkout, run the complete suite with one command:

```sh
python3 tools/run_virtual_tests.py
```

Checkout discovery is based on the runner's own location, independently of your
shell's working directory. Normal sibling repositories are `scrbrd-mobile/` and
`scrbrd/`. The permanent paired worktrees are
`~/Projects/_worktrees/scrbrd-virtual-mobile/` and
`~/Projects/_worktrees/scrbrd-virtual-firmware/`; these are also detected automatically.
Run the script by its full path from another directory if needed.

For other checkout layouts, use `--firmware /path/to/firmware` or set
`SCRBRD_FIRMWARE`. The explicit argument takes precedence over the environment,
then the documented sibling is used. Missing infrastructure fails with an actionable
error; the runner never switches branches, searches unrelated worktrees, or falls
back to another device/application source revision.

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

1. Native bridge build and eleven mobile ↔ firmware integration scenarios.
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
preexisting test, but explicitly skips these eleven native-backed scenarios. Use the
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
- Explicit connection cancellation also closes the native link and cancels staging.
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

The initial implementation passed all 18 runner steps on 2026-10-17: eleven virtual
scenarios, 963 total Flutter tests, clean static analysis, 18 existing protocol
compatibility fixture steps, all seven Python native runners and both standalone
C++ tests. The final full-run report is preserved in
`build/virtual-testing/final/report.txt` with logs/transcripts alongside it.
Generated reports are intentionally excluded from Git. No firmware/iOS device build
or installation is required for this host-only environment. These results apply to
the baseline and test changes, not to unmerged F13 or physical Bluetooth behavior.

## Development workflow and CI

Root `AGENTS.md` in each repository tells future Codex sessions when to run the
quick cross-repository checks and when a full run is required. For targeted changes:

```sh
python3 tools/run_virtual_tests.py --quick
```

Before proposing a merge of code/test changes affecting this boundary, run the full
command. Runner/path changes also require
`python3 -m unittest discover -s tools -p '*_test.py'`. Documentation-only changes
may use inspection. Do not substitute plain `flutter test` for native-backed tests.
Keep the companion checkout explicit when testing a pair of unmerged branches.

Each repository has a small `.github/workflows/virtual-tests.yml` for pull requests,
pushes to main, and manual dispatch. Both call the same mobile runner for the full
18-step suite; no second copy of the suite commands is maintained in YAML. The
changed repository is tested at its workflow revision and the companion at `main`.
Manual dispatch accepts `companion_ref` to test a particular branch or SHA. Logs,
reports and transcripts are uploaded even on failure; no binaries are installed.

CI uses the currently validated Flutter 3.47.0 and ArduinoJson 7.4.3 headers, with
checkout/action references pinned to exact commits. Its one online
`flutter pub get --enforce-lockfile` prepares an empty cache; the runner itself
continues to resolve offline with the existing lockfile. No dependency versions are
changed. These public repositories need no additional cross-repository token;
permissions are limited to reading repository contents. See the official
[checkout documentation](https://github.com/actions/checkout) and
[Flutter setup action](https://github.com/subosito/flutter-action).

The workflows are prepared locally, not executed on GitHub in this task. Both
repositories must publish the infrastructure before default companion-main runs
can succeed. For initial rollout, merge/publish firmware first and mobile second,
then rerun any firmware bootstrap job that encountered the older mobile main.
Alternatively, after approved branch publication, dispatch with `companion_ref`
set to the companion development branch. No remote publication is authorized here.

The permanent-workflow verification and approval-gated merge sequence are recorded
in [VIRTUAL_MERGE_PREPARATION.md](VIRTUAL_MERGE_PREPARATION.md).
