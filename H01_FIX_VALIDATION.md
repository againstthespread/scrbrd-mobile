# H01 — Silent WAKE Notification Failure

## Evidence and remaining uncertainty

Reference: `H01_DIAGNOSTIC_INVESTIGATION.md` in the experimental firmware worktree,
then `build/hardware-validation/H01-foreground-paired-capture-03-findings.md`.
The newer paired capture supersedes the original investigation's uncertainty
about whether a refresh gate/provider operation was blocking this reproduction.

On 2026-10-15, ESP #2 logged notification attempts at 13:42:57 and 13:43:17 EDT.
Lab was confirmed foreground/unlocked and stalled, with no raw WAKE callbacks.
The preceding APP RESUME refresh fetched scores, completed writes, and released
its gate at 13:39:47 EDT. Firmware logs prove attempts, not radio delivery.

Pinned flutter_reactive_ble 5.5.0 uses Repeater.broadcast for notifications.
Its async detach is invoked from the void broadcast onCancel callback; awaiting
Dart cancellation does not guarantee native unsubscribe completion. Native iOS
PluginController calls Central.turnNotifications(.off/.on), whose result completes
from the notification-state callback. The previous transport could therefore
start replacement before old native cleanup finished. A regression reproduces
that Dart ordering gap. **The actual native race in the captured hardware failure
is still a hypothesis.** Native delivery failure or stream-routing loss cannot be
excluded by the old logs.

## Scoped changes

- Foreground/background transitions retain the current subscription, including
  a listener still awaiting its first notification or already recovering. The
  existing explicit APP RESUME refresh and SportsOperationGate coalescing remain.
- A WAKE-only, single-listener adapter uses the existing platform interface to
  resolve the discovered characteristic instance, receive values, and await
  native enable/disable completion. Cancellation during enable waits for enable
  to settle before disable; replacement waits for actual disable completion.
  No plugin fork or native Swift changes are needed.
- A three-second caller wait can expire, but **never releases the underlying
  cancellation barrier**. Pending cleanup continues to block replacement, even
  across connection generations. A failed cleanup blocks replacement on that
  same connection; a later connection can retry after the old operation settles.
- A single 75-second foreground deadline detects silence (three expected
  20-second intervals plus margin). Accepted value receipt renews it. Background
  time is excluded; foreground return grants a fresh interval without replacing
  the listener. No periodic API polling is added.
- Silence, error, and stream termination share the existing 1/2/4-second retry
  budget: at most three automatic replacements per connection/recovery cycle.
  Receipt and duplicate connected events do not replenish the budget. Exhaustion
  shows the existing automatic-refresh warning and stops automatic retries.
  Explicit foreground return after exhaustion may start one new bounded cycle.
- WAKE epochs, connection generations and cancelled connection-attempt guards
  prevent old values, terminal events, timers, and delayed resolution from
  installing or disturbing an active listener.
- Existing bounded Developer Tools history remains. New events distinguish
  `subscription.registered receipt=unconfirmed`, native enable/disable start,
  completed/failed, `subscription.receipt-confirmed`, `subscription.silent`,
  preserved resume, retry, and blocked cleanup. `receiving` requires an accepted
  raw callback; `listening` alone still means Dart registration, not delivery.
  Native acknowledgment does not itself prove WAKE receipt. No payloads or
  credential/error text are logged; originG/epoch identify late native completions.

The already locked reactive_ble_platform_interface 5.5.0 is now declared directly
because the adapter needs its characteristic-instance type and native completion
API. The package graph, versions and checksums are unchanged; only its lockfile
classification changes from transitive to direct. BLE UUIDs, packet formats,
firmware, refresh gate, provider logic and preference storage are unchanged.

If native enable/disable never completes, the transport intentionally fails closed:
it warns after bounded waits/retries rather than overlapping another native
operation. It does not automatically reconnect indefinitely. Background execution
remains subject to iOS suspension; this is foreground subscription recovery.

## Installed baseline and isolated candidate

Read-only iPhone inventory confirms SCRBRD Lab 1.0.0 (1007),
`com.againstthespread.scrbrd.lab`. The preserved signed-build/install manifest maps
that build to source `88814d41d9262985e08d1b3110a5f04cbbf1d7dd`.
The original SCRBRD remains 1.0.0 (6), `com.againstthespread.scrbrd`.
The commit identity comes from build provenance, not a Git revision read from iOS.

- `codex/h01-wake-recovery`: fix on top of `229d4b2`, preserving all later fixes.
- `codex/h01-lab-validation`: installed `88814d4` baseline plus this H01 patch only.
  It excludes subsequent F30/F23/F21/F22 changes to isolate hardware attribution.
- Candidate: Lab 1.0.0 (1008), same separate bundle ID and previous Lab
  Firebase/signing configuration, prepared in
  `/tmp/scrbrd-hardware-validation/ios-source-h01-fix-1008`.
  Lab configuration changes are local build configuration, not production changes.
- No install, launch, uninstall, settings reset, diagnostic clear or firmware flash
  was performed. Installing later requires explicit approval and an in-place
  update, preserving Lab's container and fantasy configurations.

## Software verification

Before implementation, focused regressions failed for unnecessary foreground
replacement in both transport and lifecycle/refresh-coalescing tests. The pinned
broadcast-cancellation test demonstrated the missing cleanup barrier.

- Accumulated-fixes branch: **58 focused tests; 899 complete-suite tests passed**.
- Isolated installed-baseline + H01 candidate: **58 focused tests; 674 complete-suite
  tests passed**. The suite counts differ because later fixes and their tests are
  deliberately excluded from the isolated candidate.
- `flutter analyze --no-pub`: **no issues** on both sources.
- iOS release arm64 build 1008: **unsigned and signed builds passed**. Deep/strict
  signature verification passed; entitlements exactly match build 1007 and the
  development profile includes the connected iPhone.
- Signed artifact: experimental firmware worktree
  `build/hardware-validation/SCRBRD-Lab-H01-fix-1008.app`.
  Results/provenance: `h01-fix-1008-verification.json` alongside preserved test/build
  logs and artifact checksums in that directory.
- All dependency versions/checksums remain unchanged. Both `main` refs are untouched.
  No phone installation or ESP modification was performed.

Focused coverage includes cancellation during native enable, delayed native off,
cleanup timeout and failure, stale resolution/WAKE/error/done/connection events,
repeated reconnects, foreground grace after long background time, receipt renewal,
silent retry exhaustion, explicit retry, disposal, and existing startup/live-refresh
coalescing and offline cached-content recovery.

## Physical verification — perform one stage at a time

1. **Before any approved update:** COPY the current installed Lab timeline and save
   it with build 1007, local time and ESP/reference score/status. Never CLEAR or
   force quit before export. After installation approval, update Lab in place;
   confirm build 1008, retained categories, ordering and fantasy configurations.
   Keep ESP #1 off and ESP #2 on firmware ee5b0c6. No flash is required.
2. **Online baseline:** internet/Bluetooth ON, Lab visible/unlocked, known live game.
   Observe 90 seconds. COPY via Settings → Developer Tools → Refresh diagnostics.
   Require raw `accepted=true` WAKE roughly every 20 seconds, receipt-confirmed,
   and completed refresh/gate/write events for a real provider change. Record the
   game, ESP/reference values and delay. An unchanged score needs no duplicate write.
3. **Foreground transitions, internet unchanged:** Home for 10 seconds, return;
   repeat three times. Require `subscription.resume preserved` and continued WAKE
   receipt, without native-disable/enable churn on healthy return. Then background
   for over 75 seconds and return: no silence recovery solely for time suspended;
   allow a new 75-second foreground grace interval. COPY after each stage.
4. **Offline reconnect:** turn Wi-Fi/cellular OFF, leave Bluetooth ON, disconnect/
   reconnect ESP #2 once. Observe 60–90 seconds without further changes; COPY
   while offline. Cached scores must remain and provider failure stay visible.
   Restore internet without touching BLE; foreground Lab and watch 90 seconds.
   Require retry completion, warning clearance and continuing WAKE-driven updates
   beyond the one APP RESUME refresh. COPY before any recovery action.
5. **If silence recurs:** keep Lab visible/unlocked and connections unchanged for
   at least 90 seconds. Expect `subscription.silent` after 75 seconds, bounded
   recovery, old native-disable completed **before** replacement native-enable
   starts, then accepted raw receipt. If it remains silent for all four windows
   (about 5 minutes 7 seconds plus native-operation time), require the warning and
   no more automatic attempts. Export the whole timeline before reconnect/reset.
   Do not flash or alter firmware just to suppress WAKE. Natural/fault-injected
   native silence is covered by software tests; physical recovery is unverified
   until this path is actually exercised.
6. **Reconnect stability:** three deliberate BLE reconnects, then at least 30
   minutes foreground with a changing live reference. No duplicate listeners,
   stale-origin accepted events, unbounded retries or frozen automatic updates.
   Save the final timeline and any failure time/actions. Repeat fantasy updates
   only as part of the unchanged regular refresh path, without changing providers.

Pair any recurrence with receive-only timestamped ESP serial capture. Keep USB
unchanged throughout and record whether opening the monitor changes behavior.
If native enable succeeds but raw callbacks stay absent, the new native completion
markers narrow the next investigation; they still cannot prove over-air delivery
or peripheral CCCD state. Additional native/peripheral instrumentation would then
be a separate focused diagnostic step.
