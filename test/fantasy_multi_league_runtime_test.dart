import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports_hub_mobile/background_score_refresh_dispatcher.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/fantasy_alert_transport.dart';
import 'package:sports_hub_mobile/fantasy_league_config.dart';
import 'package:sports_hub_mobile/fantasy_live_observation_coordinator.dart';
import 'package:sports_hub_mobile/fantasy_matchup_display_data.dart';
import 'package:sports_hub_mobile/fantasy_matchup_transport.dart';
import 'package:sports_hub_mobile/fantasy_point_alert.dart';
import 'package:sports_hub_mobile/fantasy_point_delta_tracker.dart';
import 'package:sports_hub_mobile/fantasy_provider_models.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/pending_fantasy_alert_store.dart';
import 'package:sports_hub_mobile/session_aware_device_sender.dart';
import 'package:sports_hub_mobile/sleeper_api_client.dart';
import 'package:sports_hub_mobile/sleeper_fantasy_repository.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';
import 'package:sports_hub_mobile/sleeper_player_repository.dart';
import 'package:sports_hub_mobile/sleeper_projection.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  late SharedPreferencesFantasyLeagueConfigStore store;
  late FantasyLiveObservationCoordinator coordinator;
  late _Transport transport;
  late Map<String, double> points;
  late Set<String> failures;
  late Set<String> espnFailures;
  late Map<String, SleeperFantasyPlayer> metadata;
  late List<String> loads;
  late _ProjectionEnricher projectionEnricher;
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
    espnFailures = {};
    metadata = {};
    loads = [];
    projectionEnricher = _ProjectionEnricher();
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
      metadataResolver: (ids) async => {
        for (final id in ids)
          if (metadata[id] != null) id: metadata[id]!,
      },
      sleeperProjectionEnricher: projectionEnricher,
      espnMatchupLoader: (_, leagueId, teamId) async {
        if (espnFailures.contains(leagueId)) {
          throw StateError('ESPN unavailable $leagueId');
        }
        return _espnMatchup(leagueId, points[leagueId] ?? 10);
      },
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
    'same Sleeper player in two leagues produces one aggregate delivery',
    () async {
      metadata['shared-player'] = _player('shared-player');
      points['b'] = 10;
      await coordinator.observe();
      points['a'] = 11;
      points['b'] = 11;
      final result = await coordinator.observe();
      expect(result.alertCount, 2);
      expect(transport.alerts.single.delta.playerId, 'shared-player');
      expect(transport.alerts.single.player?.fullName, 'Shared player');
      expect(transport.alerts.single.headline, 'Scored in 2 leagues');
      expect((await coordinator.observe()).alerts, isEmpty);
      expect(transport.alerts.length, 1);
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

  test(
    'projection enrichment failure does not block actual loading or alerts',
    () async {
      projectionEnricher.failApply = true;
      projectionEnricher.failRefresh = true;
      final baseline = await coordinator.observe();
      expect(baseline.succeeded, isTrue);
      expect(baseline.leagues['sleeper:a']!.matchup!.team.matchup.points, 10);

      points['a'] = 11;
      final result = await coordinator.observe();

      expect(result.succeeded, isTrue);
      expect(result.leagues['sleeper:a']!.matchup!.team.matchup.points, 11);
      expect(result.leagues['sleeper:a']!.alerts.single.delta.delta, 1);
      expect(transport.alerts.single.userName, 'Team a');
    },
  );

  test('multiple projected Sleeper leagues retain one atomic slate', () async {
    projectionEnricher.userProjections.addAll({'a': 101, 'b': 202});
    projectionEnricher.opponentProjections.addAll({'a': 91, 'b': 192});

    await coordinator.observe();

    expect(transport.slates, hasLength(1));
    final slate = transport.slates.single;
    expect(slate.map((entry) => entry.identity), ['sleeper:a', 'sleeper:b']);
    expect(slate.map((entry) => entry.matchup.userProjectedScore), [101, 202]);
    expect(slate.map((entry) => entry.matchup.opponentProjectedScore), [
      91,
      192,
    ]);
    expect(transport.matchups, isEmpty);
  });

  test('projection-only changes never create scoring alerts', () async {
    projectionEnricher.userProjections['a'] = 100;
    await coordinator.observe();
    projectionEnricher.userProjections['a'] = 150;

    final projectionOnly = await coordinator.observe();
    expect(projectionOnly.alerts, isEmpty);

    points['a'] = 11;
    final actualChange = await coordinator.observe();
    expect(actualChange.alerts.single.delta.delta, 1);
  });

  test(
    'completed baseline capture triggers a subsequent projected slate',
    () async {
      await store.remove(FantasyProvider.sleeper, 'b');
      await coordinator.loadConfigurationStatus();
      projectionEnricher.populateOnRefresh = true;
      transport.projectedSlateSent = Completer<void>();

      await coordinator.observe();
      await transport.projectedSlateSent!.future;

      expect(transport.slates.last.single.matchup.userProjectedScore, 123);
      expect(transport.slates.last.single.matchup.opponentProjectedScore, 99);
    },
  );

  test(
    'BLE WAKE production path captures and automatically resends projection',
    () async {
      await store.clear();
      await save('runtime');
      final api = SleeperApiClient(
        client: MockClient(
          (_) async => throw StateError('Tests must not use the network'),
        ),
      );
      final source = _GatedRuntimeProjectionSource();
      final baselineStore = _RuntimeBaselineStore();
      final diagnostics = <String>[];
      final projectionService = SleeperSettlingProjectionService(
        projectionSource: source,
        metadataResolver: (ids) async => {
          for (final id in ids)
            id: SleeperFantasyPlayer(
              sleeperPlayerId: id,
              fullName: id == 'qb' ? 'Runtime Quarterback' : 'Runtime Runner',
              firstName: 'Runtime',
              lastName: id,
              position: id == 'qb' ? 'QB' : 'RB',
              nflTeam: id == 'qb' ? 'BUF' : 'KC',
              espnPlayerId: null,
            ),
        },
        gameStatusSource: _RuntimeStatusSource(),
        baselineStore: baselineStore,
        onDiagnostic: diagnostics.add,
      );
      final productionCoordinator = FantasyLiveObservationCoordinator(
        leagueConfigStore: store,
        repository: SleeperFantasyRepository(api),
        playerRepository: SleeperPlayerRepository(apiClient: api),
        transport: transport,
        isBleConnected: () => true,
        matchupLoader: (_) async => _projectionRuntimeSnapshot(),
        sleeperProjectionEnricher: projectionService,
        onDiagnostic: diagnostics.add,
      );
      addTearDown(productionCoordinator.dispose);
      addTearDown(api.close);
      transport.projectedSlateSent = Completer<void>();

      final wake = runIsolatedWakeDomains(
        refreshSports: () async {},
        observeFantasy: productionCoordinator.observe,
        onDiagnostic: diagnostics.add,
      );
      await source.started.future;
      await wake;

      expect(transport.slates, hasLength(1));
      expect(transport.slates.single.single.identity, 'sleeper:runtime');
      expect(transport.slates.single.single.matchup.userProjectedScore, isNull);

      source.gate.complete();
      await transport.projectedSlateSent!.future;
      await pumpEventQueue(times: 20);

      expect(transport.slates, hasLength(2));
      expect(transport.slates.last.single.matchup.userProjectedScore, 10);
      expect(transport.slates.last.single.matchup.opponentProjectedScore, 8);
      expect(source.calls, {'qb': 1, 'rb': 1});
      expect(
        baselineStore.snapshot?.leagues['runtime']?.players.keys,
        containsAll(['qb', 'rb']),
      );
      expect(
        diagnostics,
        contains(contains('Sleeper PROJ: observation league=runtime')),
      );
      expect(
        diagnostics,
        contains(contains('Sleeper PROJ: raw fetch success player=qb')),
      );
      expect(
        diagnostics,
        contains(
          contains('Sleeper PROJ: post-capture slate refresh completed'),
        ),
      );
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
      expect(transport.slates.last.single.matchup.leagueName, 'League b');
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
      expect(transport.slates.last.first.matchup.userScore, 15);
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
      expect(transport.alerts.length, 1);
      expect(coordinator.status.pendingAlerts, 0);
    },
  );

  test(
    'failed aggregate delivery retains every included queue entry',
    () async {
      await coordinator.observe();
      transport.failTeams.add('Team a');
      points['a'] = 11;
      points['b'] = 21;
      await coordinator.observe();
      expect(coordinator.pendingAlertsByLeague, {
        'sleeper:a': 1,
        'sleeper:b': 1,
      });
      expect(transport.alerts, isEmpty);
      transport.failTeams.clear();
      await coordinator.observe();
      expect(transport.alerts.single.headline, 'Scored in 2 leagues');
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
    'startup sends a one-league slate and establishes its baseline',
    () async {
      await store.remove(FantasyProvider.sleeper, 'b');

      expect(await coordinator.syncStartupCategory(), isTrue);

      expect(transport.slates, hasLength(1));
      expect(transport.slates.single.map((entry) => entry.identity), [
        'sleeper:a',
      ]);
      expect(loads, ['a', 'a']);
      expect(transport.alerts, isEmpty);
      expect(coordinator.status.pendingAlerts, 0);
    },
  );

  test(
    'startup passes every slate entry to transport in builder order',
    () async {
      await save('c');
      await coordinator.setPrimaryLeague('sleeper:b');
      transport.slates.clear();
      transport.matchups.clear();

      expect(await coordinator.syncStartupCategory(), isTrue);

      expect(transport.slates.single.map((entry) => entry.identity), [
        'sleeper:b',
        'sleeper:a',
        'sleeper:c',
      ]);
      expect(transport.matchups, isEmpty);
    },
  );

  test(
    'production session-aware startup sends configured Sleeper and ESPN leagues',
    () async {
      await store.clear();
      await save('sleeper');
      await save('espn', provider: FantasyProvider.espn);
      points['sleeper'] = 10;
      points['espn'] = 20;
      final api = SleeperApiClient(
        client: MockClient(
          (_) async => throw StateError('Tests must not use the network'),
        ),
      );
      final productionCoordinator = FantasyLiveObservationCoordinator(
        leagueConfigStore: store,
        repository: SleeperFantasyRepository(api),
        playerRepository: SleeperPlayerRepository(apiClient: api),
        transport: SessionAwareDeviceSender(
          transport: transport,
          session: TrackedDeviceSession(),
        ),
        isBleConnected: () => transport.connected,
        matchupLoader: (id) async => _snapshot(id, points[id]!),
        espnMatchupLoader: (_, leagueId, _) async =>
            _espnMatchup(leagueId, points[leagueId]!),
      );
      addTearDown(productionCoordinator.dispose);

      expect(await productionCoordinator.syncStartupCategory(), isTrue);

      expect(transport.slates, hasLength(1));
      expect(
        transport.slates.single.map((entry) => entry.identity),
        containsAll(['sleeper:sleeper', 'espn:espn']),
      );
      expect(transport.matchups, isEmpty);
    },
  );

  test(
    'startup sends an empty slate when no configured team is selected',
    () async {
      await save('a', team: null);
      await save('b', team: null);

      expect(await coordinator.syncStartupCategory(), isTrue);

      expect(transport.slates, [isEmpty]);
      expect(loads, isEmpty);
      expect(transport.matchups, isEmpty);
    },
  );

  test(
    'startup slate suppresses the legacy standalone primary matchup send',
    () async {
      await coordinator.syncStartupCategory();

      expect(transport.slates, hasLength(1));
      expect(transport.matchups, isEmpty);
    },
  );

  test('startup slate failure still establishes no-alert baselines', () async {
    transport.failSlate = true;

    await expectLater(
      coordinator.syncStartupCategory(),
      throwsA(isA<StateError>()),
    );

    expect(transport.slates, isEmpty);
    expect(loads, ['a', 'b', 'a', 'b']);
    expect(transport.alerts, isEmpty);
    expect(coordinator.status.pendingAlerts, 0);
    points['a'] = 11;
    expect((await coordinator.observe()).alerts.single.delta.delta, 1);
  });

  test(
    'regular observation refreshes the full slate without legacy sends',
    () async {
      await coordinator.syncStartupCategory();
      points['a'] = 11;

      final result = await coordinator.observe();

      expect(transport.slates, hasLength(2));
      expect(transport.slates.last.map((entry) => entry.identity), [
        'sleeper:a',
        'sleeper:b',
      ]);
      expect(transport.slates.last.first.matchup.userScore, 11);
      expect(transport.matchups, isEmpty);
      expect(result.alertCount, 1);
    },
  );

  test(
    'observation retains last-known-good league in a refreshed slate',
    () async {
      await coordinator.observe();
      failures.add('b');
      points['a'] = 11;

      await coordinator.observe();

      final slate = transport.slates.last;
      expect(slate.map((entry) => entry.identity), ['sleeper:a', 'sleeper:b']);
      expect(slate[0].matchup.userScore, 11);
      expect(slate[1].matchup.userScore, 20);
    },
  );

  test('Sleeper and ESPN coexist in a refreshed observation slate', () async {
    await save('espn', provider: FantasyProvider.espn);
    points['espn'] = 25.5;
    await coordinator.setPrimaryLeague('sleeper:a');
    transport.slates.clear();

    await coordinator.observe();

    expect(transport.slates.single.map((entry) => entry.identity), [
      'sleeper:a',
      'espn:espn',
      'sleeper:b',
    ]);
  });

  test(
    'never-loaded failed league is omitted from the observation slate',
    () async {
      await save('c');
      failures.add('c');

      await coordinator.observe();

      expect(transport.slates.single.map((entry) => entry.identity), [
        'sleeper:a',
        'sleeper:b',
      ]);
    },
  );

  test(
    'observation sends an empty slate with no valid latest matchups',
    () async {
      await save('a', team: null);
      await save('b', team: null);

      await coordinator.observe();

      expect(transport.slates, [isEmpty]);
      expect(transport.matchups, isEmpty);
    },
  );

  test('observation caps a refreshed slate at firmware capacity', () async {
    for (var index = 0; index < 7; index++) {
      final id = 'extra$index';
      points[id] = 10.0 + index;
      await save(id);
    }

    await coordinator.observe();

    expect(transport.slates.single, hasLength(8));
    expect(transport.slates.single.first.identity, 'sleeper:a');
  });

  test(
    'legacy matchup transport retains Primary-only observation updates',
    () async {
      final legacy = _LegacyMatchupTransport();
      final api = SleeperApiClient(
        client: MockClient(
          (_) async => throw StateError('Tests must not use the network'),
        ),
      );
      final legacyCoordinator = FantasyLiveObservationCoordinator(
        leagueConfigStore: store,
        repository: SleeperFantasyRepository(api),
        playerRepository: SleeperPlayerRepository(apiClient: api),
        transport: transport,
        matchupTransport: legacy,
        isBleConnected: () => transport.connected,
        matchupLoader: (id) async => _snapshot(id, points[id]!),
      );
      addTearDown(legacyCoordinator.dispose);

      await legacyCoordinator.observe();

      expect(legacy.matchups.single.leagueName, 'League a');
      expect(transport.slates, isEmpty);
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
      expect(transport.slates.single.first.matchup.leagueName, 'League a');
      await coordinator.setPrimaryLeague('sleeper:b');
      expect(await coordinator.syncStartupCategory(), isTrue);
      expect(transport.slates.last.first.identity, 'sleeper:b');
      expect(transport.matchups, isEmpty);
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

  test('ESPN and unselected Sleeper leagues observe independently', () async {
    await save('c', provider: FantasyProvider.espn);
    await save('unselected', team: null);
    final result = await coordinator.observe();
    expect(loads, ['a', 'b']);
    expect(result.leagues['sleeper:unselected']!.configured, isFalse);
    expect(result.leagues['espn:c']!.baselineReset, isTrue);
  });

  test('ESPN scoring alerts do not affect Sleeper baselines', () async {
    await save('c', provider: FantasyProvider.espn);
    await coordinator.observe();
    points['c'] = 32.5;
    final result = await coordinator.observe();
    final espn = result.leagues['espn:c']!;
    expect(espn.alerts.single.delta.delta, 2.5);
    expect(espn.alerts.single.playerName, 'ESPN D/ST');
    expect(result.leagues['sleeper:a']!.baselineReset, isFalse);
    expect(transport.alerts.last.delta.playerId, '-16001');
  });

  test('ESPN and Sleeper pending transitions remain isolated', () async {
    await save('c', provider: FantasyProvider.espn);
    await coordinator.observe();
    transport.connected = false;
    points['a'] = 11;
    points['c'] = 12;
    await coordinator.observe();
    expect(coordinator.pendingAlertsByLeague, {
      'sleeper:a': 1,
      'sleeper:b': 0,
      'espn:c': 1,
    });
  });

  test('matching Sleeper ESPN metadata aggregates across providers', () async {
    await save('c', provider: FantasyProvider.espn);
    metadata['shared-player'] = _player('shared-player', espnId: '-16001');
    await coordinator.observe();
    points['a'] = 11;
    points['c'] = 31;
    final result = await coordinator.observe();
    expect(result.alertCount, 2);
    expect(transport.alerts, hasLength(1));
    expect(transport.alerts.single.headline, 'Scored in 2 leagues');
  });

  test('unmapped Sleeper and ESPN identities do not aggregate', () async {
    await save('c', provider: FantasyProvider.espn);
    await coordinator.observe();
    points['a'] = 11;
    points['c'] = 31;
    await coordinator.observe();
    expect(transport.alerts, hasLength(2));
  });

  test(
    'aggregate retains an included delta instead of summing league scoring',
    () async {
      await save('c', provider: FantasyProvider.espn);
      metadata['shared-player'] = _player('shared-player', espnId: '-16001');
      await coordinator.observe();
      points['a'] = 12;
      points['c'] = 31;
      await coordinator.observe();
      expect(transport.alerts.single.headline, 'Scored in 2 leagues');
      expect(transport.alerts.single.delta.delta, 2);
    },
  );

  test(
    'two ESPN leagues retain independent baselines and alert state',
    () async {
      await save('c', provider: FantasyProvider.espn);
      await save('d', provider: FantasyProvider.espn);
      await coordinator.observe();
      points['c'] = 31;
      final result = await coordinator.observe();
      expect(result.leagues['espn:c']!.alertCount, 1);
      expect(result.leagues['espn:d']!.alerts, isEmpty);
      points['d'] = 32;
      expect((await coordinator.observe()).leagues['espn:d']!.alertCount, 1);
    },
  );

  test(
    'an ESPN failure does not block Sleeper or another ESPN league',
    () async {
      await save('c', provider: FantasyProvider.espn);
      await save('d', provider: FantasyProvider.espn);
      await coordinator.observe();
      espnFailures.add('c');
      points['a'] = 11;
      points['d'] = 31;
      final result = await coordinator.observe();
      expect(result.leagues['espn:c']!.error, isStateError);
      expect(result.leagues['sleeper:a']!.alertCount, 1);
      expect(result.leagues['espn:d']!.alertCount, 1);
    },
  );

  test('ESPN primary display does not reset its alert baseline', () async {
    await save('c', provider: FantasyProvider.espn);
    await coordinator.observe();
    await coordinator.setPrimaryLeague('espn:c');
    points['c'] = 31;
    final result = await coordinator.observe();
    expect(result.leagues['espn:c']!.baselineReset, isFalse);
    expect(result.leagues['espn:c']!.alertCount, 1);
    expect(transport.slates.last.first.matchup.leagueName, 'ESPN League');
    expect(transport.matchups, isEmpty);
  });

  for (final primary in ['espn:c', 'sleeper:b']) {
    test(
      'selecting $primary preserves the full mixed-provider slate',
      () async {
        await save('c', provider: FantasyProvider.espn);
        await coordinator.syncStartupCategory();
        transport.slates.clear();
        loads.clear();

        await coordinator.setPrimaryLeague(primary);

        final slate = transport.slates.single;
        expect(slate.first.identity, primary);
        expect(
          slate.map((e) => e.identity),
          unorderedEquals(['espn:c', 'sleeper:a', 'sleeper:b']),
        );
        expect(transport.matchups, isEmpty);
        expect(transport.clearCount, 0);
        expect(loads, isEmpty);
      },
    );
  }

  test(
    'ESPN Primary preview loads missing peers without observing scores',
    () async {
      await save('c', provider: FantasyProvider.espn);
      await coordinator.loadConfigurationStatus();
      expect(coordinator.primaryLeagueId, 'espn:c');

      final matchup = await coordinator.syncPrimaryEspnMatchup();

      expect(matchup, isNotNull);
      expect(transport.slates.single.map((e) => e.identity), [
        'espn:c',
        'sleeper:a',
        'sleeper:b',
      ]);
      expect(coordinator.status.baselineReady, isFalse);
      expect(transport.alerts, isEmpty);
      expect(transport.matchups, isEmpty);
    },
  );

  test(
    'Primary display changes preserve pending alerts and scoring baselines',
    () async {
      await save('c', provider: FantasyProvider.espn);
      await coordinator.observe();
      points['a'] = 11;
      await coordinator.observe(sendAlerts: false);
      final pending = coordinator.pendingAlertsByLeague;

      await coordinator.setPrimaryLeague('espn:c');
      points['c'] = 32;
      await coordinator.syncPrimaryEspnMatchup();

      expect(coordinator.pendingAlertsByLeague, pending);
      expect(transport.alerts, isEmpty);
      final result = await coordinator.observe();
      expect(result.baselineReset, isFalse);
      expect(result.alerts.single.delta.delta, 2);
      expect(transport.alerts, hasLength(2));
    },
  );

  test('ESPN disconnect display clear preserves Sleeper peers', () async {
    await save('c', provider: FantasyProvider.espn);
    await coordinator.observe();
    transport.slates.clear();

    await coordinator.clearPrimaryEspnDisplay();

    expect(transport.slates.single.map((e) => e.identity), [
      'sleeper:a',
      'sleeper:b',
    ]);
    expect(transport.clearCount, 0);
    expect(transport.matchups, isEmpty);
    expect(coordinator.status.baselineReady, isTrue);
  });

  test(
    'removing a league through the legacy editor preserves its peers',
    () async {
      await save('c', provider: FantasyProvider.espn);
      await coordinator.observe();
      transport.slates.clear();

      await coordinator.removeConfiguration();

      expect(transport.slates.single.map((e) => e.identity), [
        'espn:c',
        'sleeper:b',
      ]);
      expect(transport.clearCount, 0);
    },
  );

  test('clearing a selected roster preserves other device matchups', () async {
    await coordinator.observe();
    transport.slates.clear();

    await coordinator.clearRosterSelection();

    expect(transport.slates.single.single.identity, 'sleeper:b');
    expect(transport.clearCount, 0);
  });

  test('disabling Fantasy prevents display-only UI slate sends', () async {
    await save('c', provider: FantasyProvider.espn);
    coordinator.beginConnectionSession(fantasyEnabled: false);
    await coordinator.setPrimaryLeague('espn:c');
    await coordinator.syncPrimaryEspnMatchup();
    await coordinator.clearPrimaryEspnDisplay();
    expect(transport.slates, isEmpty);
    expect(transport.matchups, isEmpty);
    expect(transport.clearCount, 0);
  });

  test(
    'connection becoming available mid-observation still sends only a slate',
    () async {
      transport.connected = false;
      loadGate = Completer<void>();
      loadStarted = Completer<void>();
      final observation = coordinator.observe();
      await loadStarted!.future;
      transport.connected = true;
      loadGate!.complete();
      await observation;
      expect(transport.slates.single, hasLength(2));
      expect(transport.matchups, isEmpty);
    },
  );

  test(
    'old observation cannot send a slate into a replacement connection',
    () async {
      loadGate = Completer<void>();
      loadStarted = Completer<void>();
      final observation = coordinator.observe();
      await loadStarted!.future;
      coordinator.endConnectionSession();
      coordinator.beginConnectionSession();
      loadGate!.complete();
      await observation;
      expect(transport.slates, isEmpty);
      expect(transport.matchups, isEmpty);
    },
  );

  for (final background in [false, true]) {
    test(
      '${background ? 'FCM' : 'BLE WAKE'} preserves the complete startup slate',
      () async {
        await save('c', provider: FantasyProvider.espn);
        await coordinator.syncStartupCategory();
        loads.clear();
        var sportsRuns = 0;
        var fantasyRuns = 0;
        var completions = 0;
        Future<void> refresh() => runIsolatedWakeDomains(
          refreshSports: () async {
            sportsRuns++;
          },
          observeFantasy: () async {
            fantasyRuns++;
            await coordinator.observe();
          },
        );
        if (background) {
          await runBackgroundScoreRefresh(
            refresh: refresh,
            complete: () {
              completions++;
            },
          );
        } else {
          await refresh();
        }
        expect(sportsRuns, 1);
        expect(fantasyRuns, 1);
        expect(completions, background ? 1 : 0);
        expect(loads, ['a', 'b']);
        expect(transport.slates, hasLength(2));
        expect(
          transport.slates.last.map((e) => e.identity),
          transport.slates.first.map((e) => e.identity),
        );
        expect(transport.slates.last, hasLength(3));
        expect(transport.matchups, isEmpty);
        expect(transport.alerts, isEmpty);
      },
    );
  }

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
      expect(transport.slates.last.first.matchup.leagueName, 'League a');
      await coordinator.setPrimaryLeague('sleeper:c');
      await coordinator.observe();
      expect(transport.slates.last.first.matchup.leagueName, 'League c');
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

class _Transport
    implements
        DeviceTransport,
        FantasyAlertTransport,
        FantasyMatchupTransport,
        FantasySlateTransport {
  bool connected = true;
  bool failSlate = false;
  int clearCount = 0;
  final failTeams = <String>{};
  final alerts = <FantasyPointAlert>[];
  final matchups = <FantasyMatchupDisplayData>[];
  final slates = <List<FantasyMatchupSlateEntry>>[];
  Completer<void>? projectedSlateSent;

  @override
  Future<void> sendFantasyAlert(FantasyPointAlert alert) async {
    if (failTeams.contains(alert.userName)) throw StateError('BLE send failed');
    alerts.add(alert);
  }

  @override
  Future<void> sendControlCommand(String command) async {}

  @override
  Future<void> sendGameData(GameData gameData) async {}

  @override
  Future<void> sendGameSlate(List<GameData> games) async {}

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {}

  @override
  Future<void> sendFantasyMatchup(FantasyMatchupDisplayData data) async =>
      matchups.add(data);

  @override
  Future<void> sendFantasySlate(List<FantasyMatchupSlateEntry> entries) async {
    if (failSlate) throw StateError('Fantasy slate send failed');
    slates.add(List.unmodifiable(entries));
    if (entries.any((entry) => entry.matchup.userProjectedScore != null)) {
      projectedSlateSent?.complete();
      projectedSlateSent = null;
    }
  }

  @override
  Future<void> clearFantasyMatchup() async {
    clearCount++;
  }
}

class _LegacyMatchupTransport implements FantasyMatchupTransport {
  final matchups = <FantasyMatchupDisplayData>[];

  @override
  Future<void> clearFantasyMatchup() async {}

  @override
  Future<void> sendFantasyMatchup(FantasyMatchupDisplayData matchup) async {
    matchups.add(matchup);
  }
}

class _ProjectionEnricher implements SleeperProjectionEnricher {
  final userProjections = <String, double>{};
  final opponentProjections = <String, double>{};
  bool failApply = false;
  bool failRefresh = false;
  bool populateOnRefresh = false;

  @override
  Future<SleeperFantasyMatchup> applyCached(
    SleeperFantasyMatchup matchup,
  ) async {
    if (failApply) throw StateError('projection cache unavailable');
    return matchup.withProjectedTotals(
      teamProjection: userProjections[matchup.league.leagueId],
      opponentProjection: opponentProjections[matchup.league.leagueId],
    );
  }

  @override
  Future<bool> refresh(SleeperFantasyMatchup matchup) async {
    if (failRefresh) throw StateError('projection API unavailable');
    if (!populateOnRefresh) return false;
    userProjections[matchup.league.leagueId] = 123;
    opponentProjections[matchup.league.leagueId] = 99;
    return true;
  }
}

class _GatedRuntimeProjectionSource implements SleeperProjectionSource {
  final started = Completer<void>();
  final gate = Completer<void>();
  final calls = <String, int>{};

  @override
  Future<SleeperPlayerProjection?> fetchPlayerProjection({
    required String playerId,
    required String season,
    required int week,
    required String seasonType,
  }) async {
    calls.update(playerId, (value) => value + 1, ifAbsent: () => 1);
    if (!started.isCompleted) started.complete();
    await gate.future;
    return SleeperPlayerProjection(
      playerId: playerId,
      season: season,
      week: week,
      seasonType: seasonType,
      team: playerId == 'qb' ? 'BUF' : 'KC',
      gameId: 'game-$playerId',
      gameDate: DateTime(2026, 9, 27),
      stats: playerId == 'qb' ? const {'pass_yd': 250} : const {'rush_yd': 80},
    );
  }
}

class _RuntimeStatusSource implements SleeperNflGameStatusSource {
  @override
  Future<Map<String, SleeperNflGamePhase>> statusesForDates(
    Iterable<DateTime> dates,
  ) async => const {
    'BUF': SleeperNflGamePhase.upcoming,
    'KC': SleeperNflGamePhase.upcoming,
  };
}

class _RuntimeBaselineStore implements SleeperProjectionBaselineStore {
  SleeperProjectionBaselineSnapshot? snapshot;

  @override
  Future<SleeperProjectionBaselineSnapshot?> read() async => snapshot;

  @override
  Future<void> write(SleeperProjectionBaselineSnapshot value) async {
    snapshot = value;
  }
}

SleeperLeagueSnapshot _projectionRuntimeSnapshot() => SleeperLeagueSnapshot(
  league: const SleeperLeague(
    leagueId: 'runtime',
    name: 'Runtime League',
    season: '2026',
    status: 'in_season',
    scoringSettings: {
      'pass_yd': 0.04,
      'rush_yd': 0.1,
      'fum_rec_td': 6,
      'pts_allow_0': 10,
    },
    rosterPositions: [],
  ),
  week: 3,
  seasonType: 'regular',
  users: const [
    SleeperUser(userId: 'home', displayName: 'Runtime Home'),
    SleeperUser(userId: 'away', displayName: 'Runtime Away'),
  ],
  rosters: const [
    SleeperRoster(
      rosterId: 1,
      ownerId: 'home',
      players: ['qb'],
      starters: ['qb'],
    ),
    SleeperRoster(
      rosterId: 2,
      ownerId: 'away',
      players: ['rb'],
      starters: ['rb'],
    ),
  ],
  matchups: const [
    SleeperMatchup(
      rosterId: 1,
      matchupId: 1,
      points: 0,
      starters: ['qb'],
      playerPoints: {'qb': 0},
    ),
    SleeperMatchup(
      rosterId: 2,
      matchupId: 1,
      points: 0,
      starters: ['rb'],
      playerPoints: {'rb': 0},
    ),
  ],
);

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

FantasyMatchupSnapshot _espnMatchup(String id, double points) {
  const home = FantasyTeamDetails(id: '1', name: 'ESPN Home');
  const away = FantasyTeamDetails(id: '2', name: 'ESPN Away');
  return FantasyMatchupSnapshot(
    league: FantasyLeagueDetails(
      provider: FantasyProvider.espn,
      leagueId: id,
      season: 2026,
      name: 'ESPN League',
      scoringPeriod: 1,
      matchupPeriod: 1,
      teams: [home, away],
    ),
    team: FantasyScoringTeam(
      team: home,
      totalPoints: points,
      starters: [
        FantasyScoringPlayer(id: '-16001', name: 'ESPN D/ST', points: points),
      ],
    ),
    opponent: const FantasyScoringTeam(
      team: away,
      totalPoints: 0,
      starters: [],
    ),
  );
}

SleeperFantasyPlayer _player(String id, {String? espnId}) =>
    SleeperFantasyPlayer(
      sleeperPlayerId: id,
      fullName: 'Shared player',
      firstName: 'Shared',
      lastName: 'Player',
      position: 'WR',
      nflTeam: 'TEAM',
      espnPlayerId: espnId,
    );
