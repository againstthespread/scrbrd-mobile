# F08 — Automatic date rollover and missing-category recovery

Scope: experimental mobile worktree only, based on F07 commit `4df99ca`.
No firmware, BLE packet, dependency or production-branch changes. The existing
F07 preparation/validation pipeline and operation gate are reused.

## Implemented behavior

- Desired content is read from the active ordered enabled-category preferences,
  independently of the successfully delivered `TrackedDeviceSession`. Empty or
  unavailable categories remain desired and eligible for discovery.
- Every automatic WAKE, foreground-resume or FCM trigger checks the phone's local
  calendar date. A changed date causes discovery immediately on that trigger;
  otherwise healthy discovery runs at most once every five minutes. There is no new
  background timer. Between discovery passes, the existing tracked live-score
  refresh remains in use. A discovery tick does not also refetch tracked sports.
- Discovery fetches today's schedules and PGA selection by date, so it can find
  newly available games and new tournaments even within the same day. Regular
  PGA score polling can still use the discovered tournament ID between passes.
- Successful consumer deliveries carry `followsCurrentDate`; later live updates
  preserve it. Explicit Developer Tools sends default to a pinned date/tournament,
  which discovery honors instead of advancing. This includes explicit manual
  content outside enabled consumer categories. Reconnection intentionally begins
  the normal configured consumer startup again, as before. A manual send while
  discovery awaits a provider invalidates that captured pass and wins; the next
  trigger rechecks the new selection.
- Favorites, conference filters and category order use the existing startup
  transformations. Active settings retain the existing UI policy: category and
  conference changes apply at the next connection. Favorites are read per pass.
- Changed content updates individual categories; unchanged canonical content
  skips BLE transfers. Date changes are committed even if packet content happens
  to match. A changed category membership/order uses the existing `SYNC_START`
  only after the entire replacement is fetched/validated, preserving configured
  order and intentionally removing known-empty categories. Unchanged membership
  does not reset the catalog or Fantasy selection during routine refreshes.
- Same-date team shrinkage/empty responses share the existing two-observation
  membership guard with live polling. An existing same-date PGA leaderboard also
  requires two empty discovery observations before removal. Team confirmation is
  scoped to the selected date, including events rescheduled with the same IDs.
  Initially empty and newly selected dates remain distinguishable from failed
  provider requests.
- F07 cache protection remains: provider/validation failures never reset the
  catalog, failed categories retain prior content, and safe complete categories
  can update independently. Failed reconciliation retries via existing triggers
  without reverting to a startup reset. Startup/reconnect retries retain F07's
  original behavior. BLE write failures retain delivered dates and retry eligibility.
- Fantasy discovery uses ordinary score observation, preserving alert baselines,
  distinct events and negative corrections. Unchanged slates skip writes; a catalog
  reset explicitly restores the full prepared slate even when scores match.
  A failed Fantasy member still holds the entire cached Fantasy category.

## Regression evidence and results

Before implementation, four tests reproduced: yesterday's consumer date remaining
tracked after midnight; initially empty enabled NBA never rediscovered; PGA staying
on the old tournament; and an injected UTC clock selecting the UTC calendar day
instead of the phone's local date. Explicit historical selection and bounded
empty-category polling checks passed on the starting code and remain covered.

Coverage added/extended: local midnight and DST, UTC/local date conversion, missing
and failed categories recovering, PGA discovery/change/failure/recovery, partial
outages, known-empty and transient-empty schedules, failed BLE replacement,
configured ordering, favorites and conference filtering, concurrent triggers,
unchanged-transfer suppression, historical selection during pending fetches,
consumer mode surviving live updates, F07 partial reconnect verification, and
Fantasy scoring/corrections through discovery. The real Bluetooth transport/widget
regression now exercises rollover via both WAKE and foreground resume alongside
its prior F18 subscription/coalescing and F07 offline-reconnect checks.

Validation:

- Focused discovery/startup/live/session/Fantasy/alert/widget tests: 207 passed.
- Complete Flutter suite: 657 passed.
- `flutter analyze --no-pub`: no issues.
- Discovery regressions pass in `America/New_York`, `Asia/Tokyo` and `UTC`;
  the New York run includes the 23-hour spring DST day.
- Firmware HEAD, working status and existing relocated-file hashes are unchanged;
  firmware verification/ESP compilation was not required or rerun for this change.

Reproduce:

```sh
TZ=America/New_York flutter test --no-pub test/desired_content_refresh_test.dart
TZ=Asia/Tokyo flutter test --no-pub test/desired_content_refresh_test.dart
TZ=UTC flutter test --no-pub test/desired_content_refresh_test.dart
flutter test --no-pub
flutter analyze --no-pub
```

Logs, baseline failure evidence and preservation checks are under
`/tmp/scrbrd-f08/` (temporary, uncommitted).

## Remaining protocol and runtime limits

The existing protocol cannot selectively remove/reorder sports categories, so a
fully prepared catalog reset is needed for membership/order changes. During a
partial outage, safe newly available categories can append before the desired
order is restored on complete reconciliation. Such a reset retains the existing
Primary-first Fantasy behavior; routine unchanged-membership refreshes avoid it.

F07's limits still apply: a BLE interruption after `SYNC_START` has no whole-catalog
rollback, ATT success is not a device commit receipt, and old flashed firmware
has no new freshness metadata. During a continuously connected outage, the phone
warns that cached data is unverified; existing packets cannot mark an individual
retained device category stale or convey verified-at timestamps. No incompatible
freshness/clear/reorder commands were introduced.

Rollover occurs on the next executing automatic trigger, not exactly at midnight.
Discovery can take up to five minutes plus trigger/fetch latency; outages retry
at the existing refresh-trigger cadence with shared ownership. iOS suspension,
termination, missing WAKE delivery and provider correctness remain external limits.
The five-minute pass fetches enabled providers, including Fantasy for safe reset
preparation; Fantasy observation still runs for scoring alerts. Providers can
return incomplete data without an explicit error; confirmation guards reduce
transient removals but cannot establish upstream truth.

## ESP #2 physical verification remaining

No hardware was flashed. With the experimental phone app and positively identified
ESP #2, record commit IDs and verify:

1. Stay connected across local midnight; the next WAKE must load the new day's
   games without reconnecting. Repeat foreground return after midnight, timezone
   changes and a DST transition/simulated phone clock change.
2. Enable an initially empty category; make data available and wait for discovery.
   It must appear in configured category order. Verify filters/favorites and avoid
   a full reset or duplicate transfer on subsequent unchanged passes.
3. Cross a PGA tournament boundary and test a newly posted tournament on the same
   date. The provider date query must select it; subsequent score updates must
   follow the new ID.
4. Interrupt internet or one provider at rollover. Existing content must remain,
   healthy categories may update, the phone must warn, and restored service must
   recover without a BLE reconnect. Check known-empty schedules and the two-empty
   same-date removal guard separately from provider errors.
5. Send a historical date/tournament from Developer Tools, then trigger discovery,
   midnight and score refresh. It must stay pinned through that connection. Also
   send history while a provider request is pending; the manual selection must win.
6. Check Fantasy navigation/Primary behavior, positive and negative scoring alerts,
   standby and overlays during discovery and membership changes. Repeat WAKE bursts,
   foreground transitions and BLE write interruption/recovery. Inspect actual pixels
   and device receipt logs, not only phone write completion. Test an older flashed
   version-1 device for compatibility and its documented freshness-display limits.
