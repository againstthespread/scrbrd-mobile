# SCRBRD Mobile

SCRBRD is a small ESP32 scoreboard driven by a companion app. This repository
contains the Flutter client: it loads sports and fantasy data, lets the user
choose what the device tracks, and sends validated display-ready slates to the
scoreboard over Bluetooth Low Energy (BLE).

The app can browse live games, manage favorites and college-football filters,
configure fantasy leagues, perform the initial device sync, refresh changed
content, and send short-lived fantasy scoring alerts. The firmware and enclosure
live in the [SCRBRD firmware repository](https://github.com/againstthespread/scrbrd).

## Data support

- Sports: NFL, NCAA football (NCAAF), NBA, MLB, and PGA leaderboards.
- Sports providers: ESPN is the default and needs no API key. SportsDataIO is an
  optional alternative selected at build/run time.
- Fantasy providers: ESPN Fantasy Football and Sleeper NFL leagues. Multiple
  configured leagues can be sent as one ordered Fantasy category, with the
  selected primary league first.

Projected fantasy scores intentionally differ by provider:

- ESPN: the app passes through ESPN's `totalProjectedPointsLive` matchup totals.
  Missing or invalid values are displayed as unavailable.
- Sleeper: the app scores each starter's projection with that league's scoring
  settings. A starter's baseline is captured only before their NFL game begins,
  remains frozen while the game is live, and is replaced by the player's actual
  points after the game is final. Baselines persist for the current
  season/season-type/week. If every required starter cannot be resolved safely,
  that team's projection is unavailable rather than guessed.

The device only renders the actual and optional projected totals sent by the app;
provider-specific calculation stays in this repository.

## BLE relationship

The Flutter app is the BLE central and the ESP32 is the peripheral advertising as
`Peter Sports Hub`. On a new connection the app performs an authoritative sync,
then sends complete replacements only for changed sports, golf, or fantasy data.
Large payloads use staged, atomic transfers so an incomplete update does not
replace the device's last good content. The firmware emits periodic `WAKE`
notifications that trigger the same sports-refresh and fantasy-observation paths.

UUIDs, packet schemas, limits, and lifecycle rules are documented in
[SPORTS_HUB_PROTOCOL.md](SPORTS_HUB_PROTOCOL.md). Keep that file and the
firmware's protocol document aligned when changing the wire format.

## Setup and development

Install a Flutter SDK that satisfies the package's Dart constraint (`^3.12.2`),
plus the normal Android or iOS toolchain. A physical device is recommended for
BLE work.

```sh
flutter pub get
flutter run
```

ESPN is used by default. To use SportsDataIO, provide the provider and key as
local build-time definitions; do not add the key to the repository:

```sh
flutter run \
  --dart-define=SPORTS_DATA_PROVIDER=sportsdataio \
  --dart-define=SPORTSDATAIO_API_KEY=your_key_here
```

Run static analysis and the full Flutter test suite with:

```sh
flutter analyze
flutter test
```

## Code map

- `lib/main.dart` initializes Firebase, persisted preferences, and the app shell.
- `lib/connection_screen.dart` owns the connected runtime and coordinates initial
  sync, live refresh, fantasy observation, and device state.
- `lib/sports_league.dart`, `lib/sports_data_provider.dart`,
  `lib/sports_repository.dart`, `lib/espn_data_source.dart`, and
  `lib/sports_data_io_data_source.dart` define normalized sports data access.
- `lib/live_games_screen.dart`, `lib/college_football_screen.dart`, and the
  favorites/settings screens provide sports browsing and device-content setup.
- `lib/bluetooth_device_transport.dart`, `lib/sports_hub_ble_protocol.dart`, the
  packet serializers, `lib/initial_device_sync_coordinator.dart`, and
  `lib/live_refresh_coordinator.dart` implement the device transport and sync
  lifecycle.
- `lib/fantasy_league_config.dart`, the ESPN/Sleeper repositories,
  `lib/fantasy_live_observation_coordinator.dart`, and
  `lib/sleeper_projection.dart` implement fantasy setup, scoring alerts, matchup
  slates, and projected totals.
- `test/` contains serializer, provider, projection, refresh, session, protocol,
  and widget coverage.

## Automated virtual integration

See [VIRTUAL_TESTING.md](VIRTUAL_TESTING.md) for the one-command mobile/native
integration suite, deterministic fixtures, fault injection and explicit hardware limits.
