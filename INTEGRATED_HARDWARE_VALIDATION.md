# Integrated hardware validation — SCRBRD Lab 1009

October 15–17, 2026 · iPhone 16 / iOS 26.6.2 · ESP #2

**Decision: suitable as a provisional development baseline, with a known Sleeper
projection discrepancy and explicitly unexercised stress cases. This is not a
complete production qualification or an all-fixes pass.** The hardware session is
finished; no further user actions are requested for this session.

## Build, compatibility and preservation

| Item | Verified configuration |
| --- | --- |
| Mobile | `codex/h01-wake-recovery`, `bcab9097ccc17459e6a8c5948aceb59a8b4437d4`; includes H01 `8707047`, F20 `0ef47e0`, F29 lifetime `dee8355` and transaction ownership `bcab909`, plus preceding accumulated fixes |
| Firmware | `codex/firmware-production-fixes`, `ee5b0c6bba4915002f5f1a325c2b8bac4f449523`; prior ESP #2 flash plus user confirmation of no subsequent flash. All 29 tracked source files matched HEAD at their relocated paths during preparation |
| Installed candidate | Signed Release SCRBRD Lab **1.0.0 (1009)**, `com.againstthespread.scrbrd.lab`; explicitly approved update and launch without debugger |
| Compatibility | Current mobile serializer against actual firmware parser/storage/lifecycle: **18 scenarios / 112 packets passed**. BLE protocol unchanged; no receipt packets |
| Original app | Original SCRBRD build **6** untouched; its data-container path unchanged in post-install inventory |
| Rollback | Signed Lab **1008**, source `8d9cbba06110b7bcd013dde241f7058e2c6681cd`, configuration/provenance and all **90** recorded file hashes preserved and verified |

Lab 1009 signature verification passed, its entitlements match Lab 1008, and all
90 candidate files are hashed. The final pinned signed build preserved committed
Dart/Swift lockfiles. Lab's container path rotated during update, but the user
confirmed all settings, category order, leagues and fantasy teams were retained.
ESP #1 was confirmed OFF and ESP #2 powered for testing. Firmware was not flashed.
There was no original-app action, new fix, dependency change or main-branch change.
The firmware source relocation was pre-existing and left untouched.

At close, both experimental HEADs still matched the pinned revisions. Mobile main
remains `7785c601fb733369b8dd3057722460de6e96d733`; firmware main remains
`f5967a8993dcb03e1430002cbc3c3a357559cd39`.

Candidate: [signed Lab 1009](build/hardware-validation/integrated-1009/SCRBRD-Lab-integrated-1009.app).
Rollback: [preserved Lab 1008](build/hardware-validation/integrated-1009/rollback-1008/SCRBRD-Lab-H01-fix-1008.app).
Another installation, rollback or flash requires explicit approval.

## Physical results

| Check | Result and evidence |
| --- | --- |
| Configuration and initial synchronization | **PASS observed subsets.** Settings retained. Captured startup/reconciliation completions had zero failures; reconnect startup completed three categories in **5.391 s** |
| H01 WAKE and healthy foreground returns | **PASS observed behavior.** Accepted notifications continued at approximately **20-second** intervals, including after reconnect and internet recovery. Foreground returns preserved receiving health and subsequent periodic refreshes completed |
| Manual navigation and sending | **PASS.** User reports buttons/navigation work. Captured manual MLB and NCAAF transfers completed all packets without interleaving |
| Whole logical transactions | **PASS contiguous transfers observed; contention qualification incomplete.** Reconnect catalog transaction held all **23 writes** through start/categories/completion. Multiple automatic NCAAF transfers held **13 writes** each. Actual competing payloads waiting behind an active transaction were not captured |
| Fantasy display and alerts | **PASS actual scores and ESPN projections by user comparison.** Sample alert worked; alert freshness records a completed write. General selection retention passed. Exact post-overlay matchup restoration and real scoring-alert failure/retry were not separately established |
| Disconnect/reconnect | **PASS idle-disconnect recovery.** G1→G2, subscription cancellation and empty ownership reset; reconnect writes all originated on G2, with no old-generation writes observed. The intended active interruption missed: NCAAF send finished **6.586 s before disconnect** |
| Internet outage and recovery | **PASS.** Failed discovery retained cached catalog without SYNC_START, successful timestamps stayed unchanged, WAKE retries released ownership. User confirms cached sports/fantasy remained visible/navigable, selections stayed unchanged and no warnings remained. Restoration on the same BLE connection completed reconciliation in **4.480 s from APP RESUME**, followed by healthy WAKE refreshes |
| F20 freshness and resumed transmission | **PASS observed distinctions.** Successful provider refreshes, failed attempts, unchanged content and completed BLE delivery remained distinct. Unchanged MLB/fantasy retained earlier write times; later changing NCAAF data completed new BLE writes |
| Live visual responsiveness | **PASS qualitative user observation.** User explicitly confirms the live display keeps up well and being ahead of TV is positive. TB/CLE **0–0 pregame** was separately reported; NBA/MLB live changes and exact numeric display latency were not established |
| Stability hold | **PASS operational observation with sampled diagnostics.** User reports “It's working great.” Checkpoints at **12:12:05 and 12:42:10 EDT** are **30 min 5 s** apart on the same app session/G2/epoch6. No freeze/disconnect was reported; retained tails show healthy writes/refreshes and released owners |

Internet-off failures were expected test effects. An in-progress live owner
spanned 41.884 s across initial/deferred work during the transition; reconciliation
then acquired ownership, hit a 10-second provider timeout, and released normally.
This was temporary provider delay, with no permanent queue blockage observed.

## Recorded failure: Sleeper projections

League label **“gay”**, week **6**, pdeluc99 versus gsvanbeek:

| Team | SCRBRD projection | Sleeper reference projection | Difference |
| --- | ---: | ---: | ---: |
| pdeluc99 | 144.3 | 128.76 | +15.54 |
| gsvanbeek | 144.9 | 134.74 | +10.16 |

Actual scores were separately reported as **0 / 5.2**. The comparison was reported
at “12:02 est” October 17; the user's label is retained, although Detroit observes
EDT on that date. This is an observed comparison failure. Cause, duration and
whether it predates Lab 1009 are unknown; Lab versus ESP location was not separately
specified. No accompanying projection-specific diagnostic export was supplied.
No fix or broad investigation was performed during validation.

## Stability evidence and limits

The final export is session `2026-10-17T15:14:36.923468Z`, asOf
`2026-10-17T16:42:10.575325Z`, clears **0**, lastSequence **23085**.
Its 512 events retain only **61.300 s** under changing NCAAF traffic. Three complete
13-packet updates (transactions 546/549/552; writes 1623–1661) completed in
**2.26–2.34 s**, with no interleaved writes. Four refreshes completed in
**3.429–3.668 s**, released their owners, and ended with no queued/pending work.
No failure or disconnect appears in the final tail. Sports and all four fantasy
provider timestamps remain current; unchanged deliveries retain their earlier
write times.

These are sampled traces plus user observations, not a continuous thirty-minute
record. Original hold start/end times were not independently supplied; endpoint
spacing establishes elapsed time, not every foreground transition or event in the
gap. No separate twenty-minute export arrived. October 15 and the two October 17
app sessions are separate; the session change's cause was not supplied. Earlier
repeated clipboard exports were excluded from interruption evidence, and a fresh
on-phone capture was obtained. No app freeze was established from those repeats.

A completed BLE write **does not confirm ESP processing, commit or display**.
Visual observations supplement transport facts; no application acknowledgments
exist. This session also does not measure memory/resource leakage or establish
all runtime lifetime properties from a short hold.

## Remaining targeted verification

- Interrupt an actual active transfer with other sends waiting, reconnect before
  late native completion, and verify cancellation cannot resume on the new generation.
- Capture genuine overlapping manual/automatic/alert/projection payloads and latest
  selection behavior while ownership is contested. Contiguous ordinary transfers
  alone do not establish this timing case.
- Exercise a real fantasy scoring alert failure/retry and actual projection changes;
  resolve the recorded Sleeper discrepancy in separately authorized work, then retest.
- Verify live NBA/MLB changes when available. Actual silent-WAKE recovery, push
  delivery, overnight/rollover and power variants were not exercised here.

Existing F29 software evidence remains **334 focused / 952 total Flutter tests**,
clean analysis and successful unsigned iOS build; these were not rerun as physical
passes. The separately prepared signed Lab build and protocol fixture checks passed.

The evidence directory contains the manifest, installation/signing/protocol records,
per-stage analyses and preserved working notes:
[validation evidence](build/hardware-validation/integrated-1009/manifest.json).
Full user-pasted exports remain in the conversation; analysis JSON files are summaries,
not verbatim exports. Lab 1008 remains available for an approved rollback. Lab 1009
can be retained for continued development with the projection issue documented;
production readiness remains conditional on the unresolved failure and coverage gaps.
