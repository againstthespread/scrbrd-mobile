import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports_hub_mobile/fantasy_alert_transport.dart';
import 'package:sports_hub_mobile/fantasy_league_config.dart';
import 'package:sports_hub_mobile/fantasy_live_observation_coordinator.dart';
import 'package:sports_hub_mobile/fantasy_matchup_display_data.dart';
import 'package:sports_hub_mobile/fantasy_matchup_transport.dart';
import 'package:sports_hub_mobile/fantasy_point_alert.dart';
import 'package:sports_hub_mobile/fantasy_point_delta_tracker.dart';
import 'package:sports_hub_mobile/pending_fantasy_alert_store.dart';
import 'package:sports_hub_mobile/sleeper_api_client.dart';
import 'package:sports_hub_mobile/sleeper_fantasy_repository.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';
import 'package:sports_hub_mobile/sleeper_player_repository.dart';

void main() {
  late SharedPreferencesFantasyLeagueConfigStore store;
  late FantasyLiveObservationCoordinator coordinator;
  late _Transport transport;
  late Map<String, double> points;
  late Set<String> failures;
  late List<String> loads;
  Completer<void>? loadGate;
  Completer<void>? loadStarted;

  Future<void> save(
    String id, {
    String? team = '1',
    bool alerts = true,
    FantasyProvider provider = FantasyProvider.sleeper,
  }) => store.upsert(
    FantasyLeagueConfig(
      provider: provider,
      leagueId: id,
      teamId: team,
      alertsEnabled: alerts,
    ),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = SharedPreferencesFantasyLeagueConfigStore();
    points = {'a': 10, 'b': 20, 'c': 30};
    failures = {};
    loads = [];
    loadGate = null;
    loadStarted = null;
    transport = _Transport();
    final api = SleeperApiClient(
      client: MockClient(
        (_) async => throw StateError('Tests must not use the network'),
      ),
    );
    coordinator = FantasyLiveObservationCoordinator(
      leagueConfigStore: store,
      repository: SleeperFantasyRepository(api),
      playerRepository: SleeperPlayerRepository(apiClient: api),
      transport: transport,
      isBleConnected: () => transport.connected,
      setupLoader: (id) async => _snapshot(id, points[id]!),
      matchupLoader: (id) async {
        loads.add(id);
        if (loadStarted != null && !loadStarted!.isCompleted) {
          loadStarted!.complete();
        }
        if (loadGate != null) await loadGate!.future;
        if (failures.contains(id)) throw StateError('Unavailable $id');
        return _snapshot(id, points[id]!);
      },
      metadataResolver: (_) async => {},
    );
    await save('a');
    await save('b');
  });

  tearDown(() => coordinator.dispose());

  test(
    'two leagues establish independent zero-alert baselines in one cycle',
    () async {
      final result = await coordinator.observe();
      expect(loads, ['a', 'b']);
      expect(result.leagues.keys, ['sleeper:a', 'sleeper:b']);
      expect(
        result.leagues.values.every((r) => r.configured && r.baselineReset),
        isTrue,
      );
      expect(result.alerts, isEmpty);
      expect(transport.alerts, isEmpty);
      expect(result.succeeded, isTrue);
    },
  );

  test(
    'three leagues retain baselines and alert independently over successive cycles',
    () async {
      await save('c');
      await coordinator.observe();
      points['a'] = 11;
      final first = await coordinator.observe();
      expect(first.leagues['sleeper:a']!.alertCount, 1);
      expect(first.alertCount, 1);
      points['b'] = 22;
      final second = await coordinator.observe();
      expect(second.leagues['sleeper:a']!.alerts, isEmpty);
      expect(second.leagues['sleeper:b']!.alerts.single.delta.delta, 2);
      expect(second.leagues['sleeper:c']!.alerts, isEmpty);
      points['c'] = 33;
      expect(
        (await coordinator.observe())
            .leagues['sleeper:c']!
            .alerts
            .single
            .delta
            .delta,
        3,
      );
      expect(transport.alerts.map((a) => a.userName), [
        'Team a',
        'Team b',
        'Team c',
      ]);
    },
  );

  test(
    'same player and exact point transition in two leagues produces two alerts',
    () async {
      points['b'] = 10;
      await coordinator.observe();
      points['a'] = 11;
      points['b'] = 11;
      final result = await coordinator.observe();
      expect(result.alertCount, 2);
      expect(transport.alerts.map((a) => a.delta.playerId), [
        'shared-player',
        'shared-player',
      ]);
      expect((await coordinator.observe()).alerts, isEmpty);
      expect(transport.alerts.length, 2);
    },
  );

  test(
    'a failing middle league does not prevent either neighbor from alerting',
    () async {
      await save('c');
      await coordinator.observe();
      failures.add('b');
      points['a'] = 11;
      points['c'] = 31;
      final result = await coordinator.observe();
      expect(result.leagues['sleeper:b']!.error, isStateError);
      expect(result.leagues['sleeper:a']!.succeeded, isTrue);
      expect(result.leagues['sleeper:c']!.succeeded, isTrue);
      expect(result.succeeded, isFalse);
      expect(result.alertCount, 2);
      failures.clear();
      points['b'] = 21;
      expect((await coordinator.observe()).leagues['sleeper:b']!.alertCount, 1);
    },
  );

  test('adding a league baselines only that league', () async {
    await coordinator.observe();
    await save('c');
    points['a'] = 11;
    final result = await coordinator.observe();
    expect(result.leagues['sleeper:a']!.alertCount, 1);
    expect(result.leagues['sleeper:b']!.baselineReset, isFalse);
    expect(result.leagues['sleeper:c']!.baselineReset, isTrue);
    expect(result.leagues['sleeper:c']!.alerts, isEmpty);
  });

  test(
    'removing primary league preserves remaining baseline and changes device primary',
    () async {
      await coordinator.observe();
      await store.remove(FantasyProvider.sleeper, 'a');
      points['b'] = 21;
      final result = await coordinator.observe();
      expect(result.leagues.keys, ['sleeper:b']);
      expect(result.alerts.single.delta.delta, 1);
      expect(transport.matchups.last.leagueName, 'League b');
      expect(coordinator.pendingAlertsByLeague.keys, ['sleeper:b']);
    },
  );

  test('changing roster resets only that league', () async {
    await coordinator.observe();
    await save('b', team: '2');
    points['a'] = 11;
    points['b'] = 21;
    final result = await coordinator.observe();
    expect(result.leagues['sleeper:a']!.alertCount, 1);
    expect(result.leagues['sleeper:b']!.baselineReset, isTrue);
    expect(result.leagues['sleeper:b']!.alerts, isEmpty);
    points['b'] = 22;
    final next = await coordinator.observe();
    expect(
      next.leagues['sleeper:b']!.alerts.single.delta.side,
      FantasyMatchupSide.opponent,
    );
  });

  test(
    'disabled alerts maintain matchup and do not disable another league',
    () async {
      await coordinator.observe();
      await save('a', alerts: false);
      points['a'] = 15;
      points['b'] = 21;
      final result = await coordinator.observe();
      expect(result.leagues['sleeper:a']!.alerts, isEmpty);
      expect(result.leagues['sleeper:a']!.matchup!.team.matchup.points, 15);
      expect(result.leagues['sleeper:b']!.alertCount, 1);
      expect(transport.matchups.last.userScore, 15);
    },
  );

  test(
    're-enabling baselines just that league before future scoring',
    () async {
      await save('a', alerts: false);
      await coordinator.observe();
      points['a'] = 40;
      await save('a');
      points['b'] = 21;
      final result = await coordinator.observe();
      expect(result.leagues['sleeper:a']!.baselineReset, isTrue);
      expect(result.leagues['sleeper:a']!.alerts, isEmpty);
      expect(result.leagues['sleeper:b']!.alertCount, 1);
      points['a'] = 41;
      expect((await coordinator.observe()).alerts.single.delta.delta, 1);
    },
  );

  test(
    'pending alerts from multiple leagues coexist and deduplicate on retry',
    () async {
      await coordinator.observe();
      transport.connected = false;
      points['a'] = 11;
      points['b'] = 21;
      await coordinator.observe();
      expect(coordinator.pendingAlertsByLeague, {
        'sleeper:a': 1,
        'sleeper:b': 1,
      });
      expect(coordinator.status.pendingAlerts, 2);
      await coordinator.observe();
      expect(coordinator.status.pendingAlerts, 2);
      transport.connected = true;
      await coordinator.observe();
      expect(transport.alerts.length, 2);
      expect(coordinator.status.pendingAlerts, 0);
    },
  );

  test(
    'delivery failure retains only affected queue while another league delivers',
    () async {
      await coordinator.observe();
      transport.failTeams.add('Team a');
      points['a'] = 11;
      points['b'] = 21;
      final result = await coordinator.observe();
      expect(result.leagues['sleeper:a']!.deliveryError, isStateError);
      expect(result.leagues['sleeper:a']!.pendingAlerts, 1);
      expect(result.leagues['sleeper:b']!.succeeded, isTrue);
      expect(coordinator.pendingAlertsByLeague, {
        'sleeper:a': 1,
        'sleeper:b': 0,
      });
      expect(transport.alerts.single.userName, 'Team b');
      transport.failTeams.clear();
      await coordinator.observe();
      expect(transport.alerts.map((a) => a.userName), ['Team b', 'Team a']);
      expect(coordinator.status.pendingAlerts, 0);
    },
  );

  test(
    'clearing one league queue never clears another pending transition',
    () async {
      await coordinator.observe();
      transport.connected = false;
      points['a'] = 11;
      points['b'] = 21;
      await coordinator.observe();
      await save('a', alerts: false);
      await coordinator.observe();
      expect(coordinator.pendingAlertsByLeague, {
        'sleeper:a': 0,
        'sleeper:b': 1,
      });
      await store.remove(FantasyProvider.sleeper, 'a');
      transport.connected = true;
      await coordinator.observe();
      expect(transport.alerts.single.userName, 'Team b');
    },
  );

  test(
    'startup repeated calls skip ready leagues and retry failed league safely',
    () async {
      failures.add('b');
      await coordinator.establishStartupBaseline();
      failures.clear();
      points['a'] = 11;
      points['b'] = 99;
      await coordinator.establishStartupBaseline();
      expect(loads, ['a', 'b', 'b']);
      expect(transport.alerts, isEmpty);
      expect(coordinator.status.pendingAlerts, 0);
      expect((await coordinator.observe()).alerts.single.userName, 'Team a');
    },
  );

  test(
    'reconnect discards stale pending alerts and baselines every league',
    () async {
      await coordinator.establishStartupBaseline();
      transport.connected = false;
      points['a'] = 11;
      points['b'] = 21;
      await coordinator.observe();
      expect(coordinator.status.pendingAlerts, 2);
      coordinator.endConnectionSession();
      coordinator.beginConnectionSession();
      transport.connected = true;
      points['a'] = 90;
      points['b'] = 95;
      await coordinator.establishStartupBaseline();
      expect(transport.alerts, isEmpty);
      expect(coordinator.status.pendingAlerts, 0);
      await coordinator.observe();
      expect(transport.alerts, isEmpty);
      points['b'] = 96;
      expect((await coordinator.observe()).alerts.single.delta.delta, 1);
    },
  );

  test('direct observation after reconnect also baselines safely', () async {
    await coordinator.observe();
    coordinator.beginConnectionSession();
    points['a'] = 99;
    points['b'] = 99;
    final result = await coordinator.observe();
    expect(result.leagues.values.every((r) => r.baselineReset), isTrue);
    expect(result.alerts, isEmpty);
  });

  test(
    'in-flight observation from old connection cannot establish new baseline',
    () async {
      await coordinator.observe();
      loadGate = Completer<void>();
      loadStarted = Completer<void>();
      points['a'] = 99;
      final pending = coordinator.observe();
      await loadStarted!.future;
      coordinator.endConnectionSession();
      coordinator.beginConnectionSession();
      loadGate!.complete();
      await pending;
      loadGate = null;
      final result = await coordinator.observe();
      expect(result.leagues.values.every((r) => r.baselineReset), isTrue);
      expect(transport.alerts, isEmpty);
    },
  );

  test(
    'one league and legacy migration use new store with legacy values untouched',
    () async {
      SharedPreferences.setMockInitialValues({
        'sleeper_fantasy_league_id': 'a',
        'sleeper_fantasy_roster_id': 1,
        'sleeper_fantasy_alerts_enabled': true,
      });
      await coordinator.observe();
      points['a'] = 11;
      expect((await coordinator.observe()).alerts.single.delta.delta, 1);
      await coordinator.setAlertsEnabled(false);
      expect((await store.readAll()).single.alertsEnabled, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'sleeper_fantasy_alerts_enabled',
        ),
        isTrue,
      );
      await coordinator.removeConfiguration();
      expect(await store.readAll(), isEmpty);
      expect((await coordinator.observe()).configured, isFalse);
    },
  );

  test(
    'configuration edit during a load invalidates only that league',
    () async {
      await coordinator.observe();
      loadGate = Completer<void>();
      loadStarted = Completer<void>();
      points['a'] = 99;
      points['b'] = 21;
      final pending = coordinator.observe();
      await loadStarted!.future;
      await coordinator.selectRoster(2);
      loadGate!.complete();
      final result = await pending;
      expect(result.leagues['sleeper:a']!.alerts, isEmpty);
      expect(result.leagues['sleeper:b']!.alertCount, 1);
      loadGate = null;
      expect(
        (await coordinator.observe()).leagues['sleeper:a']!.baselineReset,
        isTrue,
      );
    },
  );

  test(
    'removing a later league during a load does not abort remaining leagues',
    () async {
      await save('c');
      await coordinator.observe();
      loadGate = Completer<void>();
      loadStarted = Completer<void>();
      points['c'] = 31;
      final pending = coordinator.observe();
      await loadStarted!.future;
      await store.remove(FantasyProvider.sleeper, 'b');
      await coordinator.loadConfigurationStatus();
      loadGate!.complete();
      final result = await pending;
      expect(result.leagues.containsKey('sleeper:b'), isFalse);
      expect(result.leagues['sleeper:c']!.alertCount, 1);
      expect(result.succeeded, isTrue);
    },
  );

  test(
    'persisted primary changes only device display, including startup sync',
    () async {
      await coordinator.observe();
      expect(transport.matchups.single.leagueName, 'League a');
      await coordinator.setPrimaryLeague('sleeper:b');
      expect(await coordinator.syncStartupCategory(), isTrue);
      expect(transport.matchups.last.leagueName, 'League b');
      points['a'] = 11;
      points['b'] = 21;
      final result = await coordinator.observe();
      expect(result.alertCount, 2);
      expect(result.baselineReset, isFalse);
      expect(result.matchup!.league.leagueId, 'b');
    },
  );

  test(
    'primary eligibility is provider neutral and allows alerts off',
    () async {
      await save('a', team: null);
      await save('b', alerts: false);
      await save('c', provider: FantasyProvider.espn);
      await coordinator.loadConfigurationStatus();
      expect(coordinator.primaryLeagueId, 'espn:c');
      await coordinator.setPrimaryLeague('espn:c');
      expect(coordinator.primaryLeagueId, 'espn:c');
      await expectLater(
        coordinator.setPrimaryLeague('sleeper:a'),
        throwsArgumentError,
      );
      await save('b', team: null);
      await coordinator.loadConfigurationStatus();
      expect(coordinator.primaryLeagueId, 'espn:c');
      await store.remove(FantasyProvider.espn, 'c');
      await coordinator.loadConfigurationStatus();
      expect(coordinator.primaryLeagueId, isNull);
    },
  );

  test('ESPN and unselected Sleeper leagues never invoke loader', () async {
    await save('c', provider: FantasyProvider.espn);
    await save('unselected', team: null);
    final result = await coordinator.observe();
    expect(loads, ['a', 'b']);
    expect(result.leagues['sleeper:unselected']!.configured, isFalse);
    expect(result.leagues.containsKey('espn:c'), isFalse);
  });

  test(
    'invalid Sleeper team reports per-league failure without blocking peers',
    () async {
      await save('a', team: 'not-an-integer');
      final result = await coordinator.observe();
      expect(result.leagues['sleeper:a']!.error, isFormatException);
      expect(result.leagues['sleeper:b']!.baselineReset, isTrue);
    },
  );

  test(
    'UI adapter edits selected league without overwriting others or legacy keys',
    () async {
      await coordinator.observe();
      await coordinator.configureLeague('c');
      await coordinator.selectRoster(1);
      await coordinator.setAlertsEnabled(false);
      expect((await coordinator.readConfig())!.leagueId, 'c');
      expect((await store.readAll()).length, 3);
      points['a'] = 11;
      final result = await coordinator.observe();
      expect(result.leagues['sleeper:a']!.alertCount, 1);
      // Editing another league must not steal the persisted primary.
      expect(transport.matchups.last.leagueName, 'League a');
      await coordinator.setPrimaryLeague('sleeper:c');
      await coordinator.observe();
      expect(transport.matchups.last.leagueName, 'League c');
      await coordinator.removeConfiguration();
      expect((await store.readAll()).map((c) => c.leagueId), ['a', 'b']);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          'sleeper_fantasy_league_id',
        ),
        isFalse,
      );
    },
  );

  test(
    'transition identity includes provider league and side; same event deduplicates',
    () {
      final matchup = _snapshot('a', 11).matchupForRoster(1);
      const delta = FantasyPointDelta(
        playerId: 'shared-player',
        side: FantasyMatchupSide.user,
        previousPoints: 10,
        currentPoints: 11,
        delta: 1,
      );
      String id(
        String league, {
        FantasyProvider provider = FantasyProvider.sleeper,
      }) => fantasyTransitionId(
        provider: provider,
        leagueId: league,
        week: 1,
        matchup: matchup,
        delta: delta,
      );
      expect(
        {id('a'), id('b'), id('a', provider: FantasyProvider.espn)}.length,
        3,
      );
      final pending = PendingFantasyAlertStore();
      final alert = FantasyPointAlert(
        delta: delta,
        player: null,
        userName: 'Home',
        userScore: 11,
        opponentName: 'Away',
        opponentScore: 0,
      );
      expect(
        pending.add(PendingFantasyAlert(id: id('a'), alert: alert)),
        isTrue,
      );
      pending.markDelivered(id('a'));
      expect(
        pending.add(PendingFantasyAlert(id: id('a'), alert: alert)),
        isFalse,
      );
      expect(
        pending.add(PendingFantasyAlert(id: id('b'), alert: alert)),
        isTrue,
      );
    },
  );
}

class _Transport implements FantasyAlertTransport, FantasyMatchupTransport {
  bool connected = true;
  final failTeams = <String>{};
  final alerts = <FantasyPointAlert>[];
  final matchups = <FantasyMatchupDisplayData>[];

  @override
  Future<void> sendFantasyAlert(FantasyPointAlert alert) async {
    if (failTeams.contains(alert.userName)) throw StateError('BLE send failed');
    alerts.add(alert);
  }

  @override
  Future<void> sendFantasyMatchup(FantasyMatchupDisplayData data) async =>
      matchups.add(data);

  @override
  Future<void> clearFantasyMatchup() async {}
}

SleeperLeagueSnapshot _snapshot(String id, double points) =>
    SleeperLeagueSnapshot(
      league: SleeperLeague(
        leagueId: id,
        name: 'League $id',
        season: '2026',
        status: 'in_season',
        scoringSettings: {},
        rosterPositions: [],
      ),
      week: 1,
      users: [
        SleeperUser(userId: 'home', displayName: 'Team $id'),
        const SleeperUser(userId: 'away', displayName: 'Opponent'),
      ],
      rosters: const [
        SleeperRoster(
          rosterId: 1,
          ownerId: 'home',
          players: ['shared-player'],
          starters: ['shared-player'],
        ),
        SleeperRoster(
          rosterId: 2,
          ownerId: 'away',
          players: ['opponent'],
          starters: ['opponent'],
        ),
      ],
      matchups: [
        SleeperMatchup(
          rosterId: 1,
          matchupId: 1,
          points: points,
          starters: const ['shared-player'],
          playerPoints: {'shared-player': points},
        ),
        const SleeperMatchup(
          rosterId: 2,
          matchupId: 1,
          points: 0,
          starters: ['opponent'],
          playerPoints: {'opponent': 0},
        ),
      ],
    );
