# F21 — Fantasy matchup status

Scope: status evidence only. Scores, projection calculations, alert deltas, BLE
packet fields and scheduling remain in their existing paths. The status enum was
moved into a small shared model and re-exported from the existing display module
so existing callers retain their imports. No app installation or hardware changes.

## Rules implemented

- **ESPN:** read `winner` from the uniquely selected `schedule` entry for the
  requested **matchup period**, not merely the scoring period. Explicit `HOME`,
  `AWAY` or `TIE` results map to FINAL. Missing, undecided or unrecognized results
  provide no lifecycle assertion. Total points (including negatives), live score
  field names, projections, period arithmetic and elapsed time never imply LIVE
  or FINAL. ESPN byes keep the existing BYE representation and score handling.
- **Sleeper:** reuse NFL phases already fetched for projection enrichment; add no
  requests. Any observed starter game LIVE establishes LIVE. When both nonempty
  lineups are fully resolved, all FINAL establishes FINAL; a mixture of completed
  and still-upcoming games establishes an active weekly matchup. All upcoming
  stays UPCOMING. Missing metadata/game phases or bye players block FINAL; an
  empty lineup cannot establish completion. The existing explicit league
  `complete` fallback remains.
- Starter slot `0` is empty, not an NFL player. Both sides still require at least
  one actual starter to infer completion from game phases. Unpaired Sleeper
  matchups retain the existing unavailable-matchup behavior.
- Wrong-season/type/week projections cannot supply game dates for status lookup.
  Conflicting phases for an NFL team across requested dates cannot overwrite a
  pending/rescheduled game with an earlier FINAL, regardless of date order.
- Lifecycle-only changes notify the existing slate-refresh path even when frozen
  projections have not changed. Status evidence is keyed by lineup and cleared
  on projection-context rollover. Totals and legitimate corrections remain live
  observations even after a displayed FINAL; this is not a score lock.

## Provider and protocol limits

Sleeper's [documented weekly matchup response](https://docs.sleeper.com/#getting-matchups-in-a-league)
does not expose a weekly completed flag. NFL completion here means all resolved
starters' games finished, not commissioner settlement or immunity from corrections.
A bye, missing projection date or unavailable metadata can leave lifecycle
unresolved. NFL phases retain the existing status source's cache/failure behavior.

The consumed ESPN response has no verified active-game marker. In particular,
`totalPointsLive` and `totalProjectedPointsLive` are **not** kickoff evidence.
Unsettled ESPN matchups therefore do not currently assert LIVE. Synthetic provider
fixtures exercise explicit result enums, including zero-point ties and multi-week
periods; their real-provider availability and settlement timing still need a
sanitized observed fixture. An unauthenticated public schema check returned 404;
no private league response or credentials were collected. This change does not
add an unverified ESPN lifecycle endpoint or a clock-based approximation.

There is no UNKNOWN wire value. Missing lifecycle evidence uses the existing
**UPCOMING** representation, with totals intact; this can also represent an
already-started matchup whose lifecycle is unavailable. Reliable ESPN active-state
enrichment or a neutral protocol label requires separate, evidenced work.

## Verification and physical checks

Ten status regressions failed against the original implementation: nonzero-score
LIVE inference, ESPN settled results never becoming FINAL, and zero-score Sleeper
LIVE/FINAL observations ignored. One additional initial failure was a test-fixture
null assignment and was corrected independently.

Verification: **262 focused tests and all 874 Flutter tests passed; static analysis
reported no issues.**

Focused tests cover pregame/negative points, zero-point play/finals, settled and
undecided results, byes/missing lineups, missing phases, postponed/conflicting
schedules, rollover, unchanged projections/redraw, totals and scoring alerts.

After a separately approved installation, compare ESPN and Sleeper before kickoff,
during play, after both lineups finish, and with an unresolved/bye starter. Check
ESP #2 changes its label without navigation or reconnect, preserves selection and
scores, and still displays positive and negative scoring alerts. For ESPN, retain
a sanitized current-period schedule result marker at completion and a genuine
active-game observation before extending LIVE detection. No hardware was used for
this change.
