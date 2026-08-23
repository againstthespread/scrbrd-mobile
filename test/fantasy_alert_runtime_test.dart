import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sports_hub_mobile/fantasy_alert_packet_serializer.dart';
import 'package:sports_hub_mobile/fantasy_alert_transport.dart';
import 'package:sports_hub_mobile/fantasy_live_observation_coordinator.dart';
import 'package:sports_hub_mobile/fantasy_matchup_display_data.dart';
import 'package:sports_hub_mobile/fantasy_matchup_transport.dart';
import 'package:sports_hub_mobile/fantasy_point_alert.dart';
import 'package:sports_hub_mobile/fantasy_point_delta_tracker.dart';
import 'package:sports_hub_mobile/pending_fantasy_alert_store.dart';
import 'package:sports_hub_mobile/sleeper_api_client.dart';
import 'package:sports_hub_mobile/sleeper_fantasy_config.dart';
import 'package:sports_hub_mobile/sleeper_fantasy_repository.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';
import 'package:sports_hub_mobile/sleeper_player_repository.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  group('Sleeper-only fantasy runtime', () {
    late _ConfigStore config;
    late _Transport transport;
    late List<SleeperLeagueSnapshot> snapshots;
    late int loads;
    late int metadataResolutions;
    late FantasyLiveObservationCoordinator coordinator;

    setUp(() {
      config = _ConfigStore(
        const SleeperFantasyConfig(leagueId: 'league-1', rosterId: 1),
      );
      transport = _Transport();
      snapshots = [_snapshot()];
      loads = 0;
      metadataResolutions = 0;
      final api = SleeperApiClient(
        client: MockClient((_) async => throw 'unused'),
      );
      coordinator = FantasyLiveObservationCoordinator(
        configStore: config,
        repository: SleeperFantasyRepository(api),
        playerRepository: SleeperPlayerRepository(apiClient: api),
        transport: transport,
        isBleConnected: () => transport.connected,
        matchupLoader: (_) async {
          final index = loads < snapshots.length ? loads : snapshots.length - 1;
          loads++;
          return snapshots[index];
        },
        metadataResolver: (ids) async {
          metadataResolutions++;
          return {
            for (final id in ids)
              if (id == 'user-player') id: _chase,
          };
        },
      );
    });

    test('first observation establishes baseline and emits no alert', () async {
      final result = await coordinator.observe();
      expect(result.baselineReset, isTrue);
      expect(result.alerts, isEmpty);
      expect(transport.alerts, isEmpty);
      expect(transport.matchups, hasLength(1));
    });

    test('0-0 resolved Week 1 matchup sends as upcoming', () async {
      snapshots = [
        _snapshot(
          week: 1,
          userPoints: 0,
          opponentPoints: 0,
          userTotal: 0,
          opponentTotal: 0,
        ),
      ];
      await coordinator.establishStartupBaseline();
      expect(transport.matchups.single.week, 1);
      expect(
        transport.matchups.single.status,
        FantasyMatchupDisplayStatus.upcoming,
      );
    });

    test(
      'unchanged matchup skips persistent send; score change sends',
      () async {
        snapshots = [_snapshot(), _snapshot(), _snapshot(userTotal: 105.7)];
        await coordinator.observe();
        await coordinator.observe();
        expect(transport.matchups, hasLength(1));
        await coordinator.observe();
        expect(transport.matchups, hasLength(2));
        expect(transport.matchups.last.userScore, 105.7);
      },
    );

    test('failed persistent send retains baseline for next wake', () async {
      snapshots = [_snapshot(), _snapshot(userTotal: 105.7)];
      await coordinator.observe();
      transport.failMatchup = true;
      await coordinator.observe();
      expect(transport.matchups, hasLength(1));
      transport.failMatchup = false;
      await coordinator.observe();
      expect(transport.matchups, hasLength(2));
    });

    test('long names send and advance the normalized device baseline', () async {
      snapshots = [
        _snapshot(
          leagueName:
              'A very long Sleeper league name that exceeds forty-eight characters',
          userName: 'The Extremely Long Home Team Name',
          opponentName: 'The Extremely Long Away Team Name',
        ),
      ];
      await coordinator.observe();
      await coordinator.observe();
      expect(transport.matchups, hasLength(1));
      expect(
        utf8.encode(transport.matchups.single.leagueName).length,
        lessThanOrEqualTo(48),
      );
      expect(
        utf8.encode(transport.matchups.single.userName).length,
        lessThanOrEqualTo(20),
      );
      expect(coordinator.deviceSession.baseline, transport.matchups.single);
    });

    test('user delta sends once, unchanged wake does not resend', () async {
      snapshots = [
        _snapshot(),
        _snapshot(userPoints: 23.4, userTotal: 104.7),
        _snapshot(userPoints: 23.4, userTotal: 104.7),
      ];
      await coordinator.observe();
      final changed = await coordinator.observe();
      await coordinator.observe();
      expect(changed.alerts.single.delta.delta, 15);
      expect(transport.alerts, hasLength(1));
      expect(transport.alerts.single.player?.fullName, "Ja'Marr Chase");
    });

    test(
      'opponent, fractional, and negative deltas are authoritative',
      () async {
        snapshots = [
          _snapshot(),
          _snapshot(opponentPoints: 6.25, opponentTotal: 89.45),
          _snapshot(opponentPoints: 5.75, opponentTotal: 88.95),
        ];
        await coordinator.observe();
        expect((await coordinator.observe()).alerts.single.delta.delta, 1.25);
        expect((await coordinator.observe()).alerts.single.delta.delta, -0.5);
      },
    );

    test('missing metadata falls back without blocking the alert', () async {
      snapshots = [_snapshot(), _snapshot(opponentPoints: 7)];
      await coordinator.observe();
      await coordinator.observe();
      expect(transport.alerts.single.player, isNull);
      final packet = const FantasyAlertPacketSerializer().serialize(
        transport.alerts.single,
      );
      expect(jsonDecode(utf8.decode(packet))['player'], 'opponent-player');
    });

    test(
      'one alert maximum per wake with deterministic user priority',
      () async {
        snapshots = [
          _snapshot(),
          _snapshot(userPoints: 9.4, opponentPoints: 20),
          _snapshot(userPoints: 9.4, opponentPoints: 20),
        ];
        await coordinator.observe();
        await coordinator.observe();
        expect(transport.alerts.single.delta.side, FantasyMatchupSide.user);
        await coordinator.observe();
        expect(transport.alerts, hasLength(2));
        expect(transport.alerts.last.delta.side, FantasyMatchupSide.opponent);
      },
    );

    test('BLE failure retains alert and later wake retries it', () async {
      snapshots = [
        _snapshot(),
        _snapshot(userPoints: 10),
        _snapshot(userPoints: 10),
      ];
      await coordinator.observe();
      transport.fail = true;
      await coordinator.observe();
      expect(coordinator.status.pendingAlerts, 1);
      transport.fail = false;
      await coordinator.observe();
      expect(transport.alerts, hasLength(1));
      expect(coordinator.status.pendingAlerts, 0);
    });

    test('startup baseline is owned once per connection session', () async {
      await coordinator.establishStartupBaseline();
      await coordinator.establishStartupBaseline();
      expect(loads, 1);
      expect(transport.alerts, isEmpty);
    });

    test('a new connection session resends persistent device state', () async {
      await coordinator.establishStartupBaseline();
      coordinator.endConnectionSession();
      coordinator.beginConnectionSession();
      await coordinator.establishStartupBaseline();
      expect(transport.matchups, hasLength(2));
    });

    test(
      'manual then automatic observation cannot duplicate transition',
      () async {
        snapshots = [
          _snapshot(),
          _snapshot(userPoints: 10),
          _snapshot(userPoints: 10),
        ];
        await coordinator.establishStartupBaseline();
        await coordinator.observe();
        await coordinator.observe();
        expect(transport.alerts, hasLength(1));
      },
    );

    test(
      'week or opponent change creates a clean zero-alert baseline',
      () async {
        snapshots = [
          _snapshot(),
          _snapshot(week: 9, opponentRosterId: 3, userPoints: 40),
        ];
        await coordinator.observe();
        final result = await coordinator.observe();
        expect(result.baselineReset, isTrue);
        expect(result.alerts, isEmpty);
      },
    );

    test(
      'ordinary observations resolve metadata without player download',
      () async {
        snapshots = [_snapshot(), _snapshot(userPoints: 10)];
        await coordinator.observe();
        await coordinator.observe();
        expect(metadataResolutions, 2);
        // The injected cached resolver is the only metadata path used.
        expect(loads, 2);
      },
    );

    test('alerts OFF persists and suppresses BLE delivery', () async {
      snapshots = [_snapshot(), _snapshot(userPoints: 20, userTotal: 105.7)];
      await coordinator.observe();
      await coordinator.setAlertsEnabled(false);
      await coordinator.observe();
      expect((await config.read())!.alertsEnabled, isFalse);
      expect(transport.alerts, isEmpty);
      expect(transport.matchups, hasLength(2));
    });

    test('removing configuration sends fantasy clear only', () async {
      await coordinator.observe();
      await coordinator.removeConfiguration();
      expect(transport.clears, 1);
      expect(await config.read(), isNull);
      expect(transport.matchups, hasLength(1));
    });

    test(
      're-enabling establishes a baseline without historical alerts',
      () async {
        snapshots = [
          _snapshot(),
          _snapshot(userPoints: 20),
          _snapshot(userPoints: 20),
          _snapshot(userPoints: 21),
        ];
        await coordinator.observe();
        await coordinator.setAlertsEnabled(false);
        await coordinator.observe();
        await coordinator.setAlertsEnabled(true);
        final baseline = await coordinator.observe();
        expect(baseline.baselineReset, isTrue);
        expect(transport.alerts, isEmpty);
        await coordinator.observe();
        expect(transport.alerts.single.delta.delta, 1);
      },
    );

    test(
      'test alert uses existing transport and handles disconnection',
      () async {
        transport.connected = false;
        expect(await coordinator.sendTestAlert(), isFalse);
        transport.connected = true;
        expect(await coordinator.sendTestAlert(), isTrue);
        expect(transport.alerts.single.delta.delta, 12);
      },
    );
  });

  test('changing league atomically clears an old roster selection', () async {
    final store = _ConfigStore(
      const SleeperFantasyConfig(leagueId: 'old', rosterId: 3),
    );
    final api = SleeperApiClient(
      client: MockClient((_) async => throw 'unused'),
    );
    final coordinator = FantasyLiveObservationCoordinator(
      configStore: store,
      repository: SleeperFantasyRepository(api),
      playerRepository: SleeperPlayerRepository(apiClient: api),
      transport: _Transport(),
      isBleConnected: () => true,
      setupLoader: (_) async => _snapshot(),
      matchupLoader: (_) async => _snapshot(),
      metadataResolver: (_) async => const {},
    );
    await coordinator.configureLeague('new');
    expect((await store.read())!.leagueId, 'new');
    expect((await store.read())!.rosterId, isNull);
  });

  test('pending store is bounded and transition-deduplicated', () {
    final store = PendingFantasyAlertStore(capacity: 2);
    for (var index = 0; index < 4; index++) {
      store.add(PendingFantasyAlert(id: '$index', alert: _alert('$index')));
    }
    expect(store.length, 2);
    expect(
      store.add(PendingFantasyAlert(id: '0', alert: _alert('0'))),
      isFalse,
    );
  });

  test(
    'firmware-compatible packet uses empty fallback fields and <=512 bytes',
    () {
      final packet = const FantasyAlertPacketSerializer().serialize(
        _alert('user-player', player: _chase),
      );
      final json = jsonDecode(utf8.decode(packet)) as Map<String, dynamic>;
      expect(packet.length, lessThanOrEqualTo(512));
      expect(json['type'], 'fantasy_alert');
      expect(json['headline'], '');
      expect(json['confidence'], 'none');
      expect(json['points'], 1.0);
    },
  );

  test(
    'fantasy alert transport does not mutate tracked sports session',
    () async {
      final session = TrackedDeviceSession();
      final before = session.snapshot();
      await _Transport().sendFantasyAlert(_alert('1'));
      expect(session.snapshot(), before);
    },
  );

  test('fantasy failure does not prevent the sports WAKE domain', () async {
    var sportsRan = false;
    await runIsolatedWakeDomains(
      refreshSports: () async => sportsRan = true,
      observeFantasy: () async => throw StateError('Sleeper unavailable'),
    );
    expect(sportsRan, isTrue);
  });

  test('sports failure does not prevent the fantasy WAKE domain', () async {
    var fantasyRan = false;
    await runIsolatedWakeDomains(
      refreshSports: () async => throw StateError('sports unavailable'),
      observeFantasy: () async => fantasyRan = true,
    );
    expect(fantasyRan, isTrue);
  });
}

class _ConfigStore implements SleeperFantasyConfigStore {
  _ConfigStore(this.value);
  SleeperFantasyConfig? value;

  @override
  Future<SleeperFantasyConfig?> read() async => value;

  @override
  Future<void> save(SleeperFantasyConfig config) async => value = config;

  @override
  Future<void> clear() async => value = null;
}

class _Transport implements FantasyAlertTransport, FantasyMatchupTransport {
  final alerts = <FantasyPointAlert>[];
  final matchups = <FantasyMatchupDisplayData>[];
  bool connected = true;
  bool fail = false;
  bool failMatchup = false;
  int clears = 0;

  @override
  Future<void> sendFantasyAlert(FantasyPointAlert alert) async {
    if (fail) throw StateError('BLE failed');
    alerts.add(alert);
  }

  @override
  Future<void> sendFantasyMatchup(FantasyMatchupDisplayData matchup) async {
    if (failMatchup) throw StateError('matchup BLE failed');
    matchups.add(matchup);
  }

  @override
  Future<void> clearFantasyMatchup() async {
    clears++;
  }
}

SleeperLeagueSnapshot _snapshot({
  int week = 8,
  int opponentRosterId = 2,
  double userPoints = 8.4,
  double opponentPoints = 5,
  double userTotal = 89.7,
  double opponentTotal = 88.2,
  String leagueName = 'Friends',
  String userName = 'Peter',
  String opponentName = 'Mike',
}) => SleeperLeagueSnapshot(
  league: SleeperLeague(
    leagueId: 'league-1',
    name: leagueName,
    season: '2026',
    status: 'in_season',
    scoringSettings: {},
    rosterPositions: [],
  ),
  week: week,
  users: [
    SleeperUser(userId: 'u1', displayName: userName),
    SleeperUser(userId: 'u2', displayName: opponentName),
  ],
  rosters: [
    const SleeperRoster(
      rosterId: 1,
      ownerId: 'u1',
      players: ['user-player'],
      starters: ['user-player'],
    ),
    SleeperRoster(
      rosterId: opponentRosterId,
      ownerId: 'u2',
      players: const ['opponent-player'],
      starters: const ['opponent-player'],
    ),
  ],
  matchups: [
    SleeperMatchup(
      rosterId: 1,
      matchupId: 7,
      points: userTotal,
      starters: const ['user-player'],
      playerPoints: {'user-player': userPoints},
    ),
    SleeperMatchup(
      rosterId: opponentRosterId,
      matchupId: 7,
      points: opponentTotal,
      starters: const ['opponent-player'],
      playerPoints: {'opponent-player': opponentPoints},
    ),
  ],
);

FantasyPointAlert _alert(String playerId, {SleeperFantasyPlayer? player}) =>
    FantasyPointAlert(
      delta: FantasyPointDelta(
        playerId: playerId,
        side: FantasyMatchupSide.user,
        previousPoints: 0,
        currentPoints: 1,
        delta: 1,
      ),
      player: player,
      userName: 'PETER',
      userScore: 104.7,
      opponentName: 'MIKE',
      opponentScore: 97.2,
    );

const _chase = SleeperFantasyPlayer(
  sleeperPlayerId: 'user-player',
  fullName: "Ja'Marr Chase",
  firstName: "Ja'Marr",
  lastName: 'Chase',
  position: 'WR',
  nflTeam: 'CIN',
  espnPlayerId: '4362628',
);
