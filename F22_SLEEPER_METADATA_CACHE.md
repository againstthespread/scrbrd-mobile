# F22 — Sleeper metadata cache reliability

League metadata (league fields/scoring rules, users and rosters) now expires after
**one hour**. Expiration is checked on the next existing matchup refresh; no timer
or polling loop was added. Normal refreshes still fetch only matchups. A detected
NFL week/season-type transition forces metadata refresh even before expiration.
The existing six-hour NFL state-check interval remains unchanged.

League configuration edits expire the affected league's metadata without deleting
usable snapshots. Removing a configuration also expires its metadata so re-adding
it cannot silently reuse a fresh-looking old snapshot. Unchanged configurations,
connection resets and Primary navigation do not repeatedly invalidate metadata.
Concurrent matchup refreshes for the same league share one operation.

The three metadata resources commit as one bundle; a failed resource or mismatched
league ID retains the preceding bundle. Fresh matchup totals can still advance.
Failure does not reset metadata freshness: automatic retries occur on a subsequent
refresh, with a **one-minute** delay between failed metadata attempts. Explicit
configuration edits can request a new attempt sooner. Invalidation during a fetch
cannot be overwritten by its completion. A cold load with no cache still reports
failure, and a failed explicit reload leaves the existing snapshot intact.

F09's week-rollover safety remains: replacement matchups must succeed before the
new week check commits. Metadata fetches run after that successful matchup fetch,
so failed transitions remain promptly retryable and never overwrite valid data.

## Scoring and lifecycle

Refreshed scoring settings flow into the existing scoring-signature check. Valid
pregame projections are recalculated under the new rules. Old frozen point values
are never treated as matching a new signature. If rules change after kickoff and
no valid new baseline can be established, the existing projection policy returns
unavailable; FINAL players can still settle to their actual points. This change
does not invent a replacement pregame projection or alter scoring alerts, actual
totals, F21 lifecycle inference, BLE formats or league/configuration identities.

## Limits and verification

Metadata may remain old during an outage; it is deliberately retained for usability
and is not marked freshly fetched internally. Recovery requires the existing
refresh pipeline to run. This is an in-process cache, not a new disk cache. Saved
configuration display-name hints are not rewritten automatically; fresh matchup
and device names come from provider metadata. Six-hour NFL-state observation means
week changes are refreshed when detected, not at an invented kickoff/clock boundary.

Verification: **208 focused tests and all 886 Flutter tests passed; static analysis
reported no issues.**

Five new regressions failed before implementation: TTL expiration, week rollover,
configuration edits, failed-metadata recovery and scoring-rule projection updates.
Focused coverage also checks expiration request counts, coherent fallback, new
season type, successful week commit with metadata failure, single-flight cleanup,
in-flight invalidation, league identity mismatch and cold/explicit-load failures.

After an approved deployment, rename a test Sleeper team/change an owner or roster,
then confirm the phone matchup and ESP #2 update after expiry or a configuration
edit. Verify changes in a disposable league's scoring settings update projections
without changing observed actual totals or generating fabricated alerts. Exercise
provider/network failure followed by recovery and a real NFL week transition.
No Lab installation or hardware changes were performed for this fix.
