# F11 — Fantasy alert aggregation

Scope: experimental `scrbrd-mobile-codex`, starting at `19039e1`. No firmware,
BLE packet/UUID, dependency, or main-branch changes.

## Confirmed defects and fixes

- The drain previously grouped all pending transitions by canonical player,
  counted transitions as leagues, displayed one included delta/snapshot, and
  consumed every member. Different events and scoring values disappeared.
- Each observation now has an internal monotonically increasing sequence, shared
  by its Sleeper and ESPN league observations. Pending delivery is chronological
  across observations, retaining the existing user/magnitude priority within an
  observation. Larger new deltas cannot overtake older pending events.
- Duplicate detection uses observation plus transition identity. A legitimate
  10→11→10→11 sequence retains all three events, before or after delivery, while
  retries/unchanged polling do not manufacture duplicates. Removing a delivered
  entry is scoped to its exact observation and transition.
- Aggregation requires the same observation, canonical player and delta, with at
  most one included transition per provider-qualified league. Unique league IDs
  determine the headline count. Multiple entries from one league are delivered
  individually. Matching cross-provider observations still aggregate.
- Different scoring values and opposite-sign corrections deliver independently
  with their own captured matchup totals. Values are neither summed nor replaced
  with a different observation's totals. Successful delivery consumes only the
  represented entries; a failure retains that group and all following events.
  Retrying successful groups is unnecessary; older failed work precedes new work.
- Existing league/context reset, alert enablement, Primary selection, persistent
  slate and transport behavior remain unchanged.

## Product-policy boundaries

The APIs expose polling snapshots, not a shared play/event identifier. One
observation is an ordering/compatibility boundary, not proof of one NFL play.
Do not infer that equal deltas from different refreshes are the same event, or
that differing league deltas should be summed or represented by an arbitrary
first value. This fix keeps those observations separate to avoid losing data.
The previous test accepting a +2/+1 mixed-provider group with only +2 displayed
now asserts two deliveries, preserving both values and their matchup totals.

For compatible equal-delta groups, the existing presentation remains: the first
included league supplies team names/totals, one shared delta is displayed, and
the headline gives the unique league count. Choosing Primary, displaying several
league-specific totals, presenting unequal deltas in one alert, or correlating
provider updates across refreshes requires a product decision. No new scoring
formula, time window, sign-specific headline, or packet format was invented.

An explicit connection-session reset still clears pending state and establishes
fresh baselines, as before. Durable catch-up across those resets/app restarts is
a separate product policy; this fix guarantees ordering/retention for pending
work within the existing observation session. A successful transport future is
still the existing delivery boundary, not a firmware display receipt.

## Regression evidence

Before implementation, eight new runtime cases produced seven failures and one
passing compatibility control. They reproduced false league counts, lost
successive events/corrections, lost differing scoring values, and incorrect
partial-delivery recovery. Logs: `/tmp/scrbrd-f11/before-tests.log` (temporary).

Thirteen added regressions cover repeated events, queued/delivered correction
cycles in Sleeper and ESPN, unique/provider-qualified league counting, duplicate
same-player entries within one league, differing scoring systems, matching
negative corrections, both matchup totals, scoped removal and partial-failure
retry ordering. Existing matching-delta/provider aggregation and simultaneous
user/opponent priority tests remain green.

Validation passed:

- 111 focused tests in `fantasy_multi_league_runtime_test.dart` and
  `fantasy_alert_runtime_test.dart`.
- Complete Flutter suite: 604 tests.
- `flutter analyze --no-pub`: no issues.
- `git diff --check`: clean.

Run with the installed Flutter SDK, without changing dependencies:

```sh
flutter test --no-pub test/fantasy_multi_league_runtime_test.dart test/fantasy_alert_runtime_test.dart
flutter test --no-pub
flutter analyze --no-pub
```

## ESP #2 / iPhone verification still required

No hardware was flashed or physically tested. With the experimental app and an
authorized ESP #2 setup, verify successive alerts retain order and correct signed
points/totals; matching observations across leagues count once per league;
differing scoring rules and corrections appear separately. Simulate failed BLE
writes, recover within the same session, and verify only failed/pending groups
retry. Separately exercise disconnect/reconnect and confirm the existing fresh
baseline policy. Check overlays, standby/wake restoration, and alert bursts near
or above the firmware FIFO capacity. Increased faithful event delivery can expose
existing device pacing/acceptance limits; no firmware receipt/backpressure
protocol or queue/pacing policy was added in this F11-only change.
