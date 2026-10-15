# H01 diagnostic capture

This change adds observation only. It does not repair H01, add a WAKE watchdog,
change refresh/retry scheduling, change BLE packets, or alter provider requests.
The installed iPhone app has not been updated. These instructions apply after
an instrumented **SCRBRD Lab** build is prepared and installed with approval;
keep its separate Lab bundle ID so the working app remains installed.

## Timeline and limits

Open **Settings → Developer Tools → Refresh diagnostics**.

- The panel shows newest events first. **COPY** exports the retained timeline
  oldest first to the clipboard; paste it into Notes, a plain text file, or chat.
  If clipboard access fails, long-press/select the visible diagnostic text instead.
- Each line includes an ISO UTC timestamp, elapsed milliseconds since this
  diagnostic session started, a sequence number, source, transport ID **T** and
  observed connection generation **G**. `originG` preserves a WAKE/write/request's
  originating generation if it finishes after the transport generation changes.
  `syncG`/`originSyncG` identify the sync coordinator's separate generation counter.
  Gate `op` IDs identify ownership; refresh `id` connects request and execution events.
- The latest **512 events** are retained; each message is capped at **240 characters**.
  The export header records evicted entries, explicit clears and the last sequence.
  Timestamps and counters are metadata only; packet contents, credentials, player
  details, provider URLs and free-form provider error messages are not exported.
- The in-memory history is shared across navigation, reconnection and replacement
  ConnectionScreen/transport instances within the same app isolate. Foreground
  return does not clear it. **Force quit/process/isolate restart loses it**;
  export before recovery. **CLEAR** deliberately removes retained entries.
- Logging adds no diagnostic polling or retry timer. A silent subscription can
  still stall; its last `wake.raw` and health transitions will now be visible.

## One controlled capture

1. Leave ESP #1 off. Use ESP #2 with a known live game, internet on, Lab foreground
   and the iPhone unlocked. Record Lab build, sport/teams, starting score/status,
   enabled categories and league-provider counts; include no account credentials.
2. After observing an automatic update, tap **COPY** and save as **online baseline**.
   Keep existing history; avoid CLEAR between test stages.
3. Turn off iPhone Wi-Fi/cellular data, leaving Bluetooth on. Disconnect/reconnect
   once in Lab. Let startup settle; note the phone connection/warning status and
   the ESP's score/status. Do not change categories or selected historical dates.
4. Restore internet without reconnecting BLE. Observe a real reference change.
   At a stall, go to the diagnostic panel and tap **COPY before force quitting,
   reconnecting again, or resetting ESP**. Save as **stalled**, with local time/zone,
   reference score/status, ESP score/status and the exact actions performed.
5. Only after exporting, test Home/return without swiping Lab away. Export again
   as **after foreground return**. If force quit is subsequently used, export first
   and label the resulting new-session capture separately.

Pair exports with timestamped ESP serial output when available. Opening a USB
reader can affect timing; note whether one was open. A firmware “notification
sent” line records an attempt, not confirmed phone receipt.

## Reading the boundary

- `subscription.health ...listening` without later `wake.raw`: subscription created,
  no received event shown. Check firmware send attempts and subscription events.
- `wake.raw accepted=false`: old generation/epoch or invalid current transport state;
  it is not forwarded. `accepted=true` should be followed by `wake.forwarded`.
- `request.begin` → `retry.enter`/`discovery.enter` with no matching exit: inspect
  `runningG`, `runningAgeMs`, sync prepare phase and gate ownership.
- A `gate.request` can return **deferred**. `request.end ...gate-returned` is not
  proof of completed work. `execution.begin/end` and gate acquisition/release show
  actual execution; gate fields expose startup queue, live activity and pending WAKE.
- `write.start` without completion/failure/release identifies an outstanding write.
  A completion with an old `originG` must be distinguished from a current write.
- `screen.init`/`screen.dispose`, T/G IDs, lifecycle events and the export session/
  clear counters help explain an apparently empty or replaced diagnostic history.

## Verification

Run only the directly affected history/export, BLE transport, foreground recovery,
operation gate, initial sync, desired discovery and home/Developer Tools UI tests,
plus `flutter analyze --no-pub`. No iPhone installation is part of verification.

Result: **119 relevant tests passed across these seven files; static analysis
reported no issues.** Focused assertions cover bounded/ordered export, navigation
and transport recreation retention, clipboard failure fallback, raw WAKE and
subscription transitions, reconnect generations, pending/completed writes, retry/
discovery phases, and exclusion of synthetic secrets from exported/provider logs.
The full Flutter suite was not run.
