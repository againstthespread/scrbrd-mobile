import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports_hub_mobile/fantasy_alert_transport.dart';
import 'package:sports_hub_mobile/fantasy_league_config.dart';
import 'package:sports_hub_mobile/fantasy_live_observation_coordinator.dart';
import 'package:sports_hub_mobile/fantasy_point_alert.dart';
import 'package:sports_hub_mobile/fantasy_primary_league_store.dart';
import 'package:sports_hub_mobile/fantasy_screen.dart';
import 'package:sports_hub_mobile/sleeper_api_client.dart';
import 'package:sports_hub_mobile/sleeper_fantasy_repository.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';
import 'package:sports_hub_mobile/sleeper_player_repository.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('no leagues shows empty state and Add Fantasy League', (
    tester,
  ) async {
    final h = _Harness();
    await _pump(tester, h);
    expect(find.text('My Leagues'), findsOneWidget);
    expect(find.text('No fantasy leagues connected.'), findsOneWidget);
    expect(find.text('Add Fantasy League'), findsOneWidget);
    expect(find.text('Sleeper League ID'), findsNothing);
    expect(find.text('SEND TEST ALERT'), findsNothing);
  });

  testWidgets(
    'migrated legacy league loads friendly names without deleting legacy values',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'sleeper_fantasy_league_id': 'a',
        'sleeper_fantasy_roster_id': 1,
        'sleeper_fantasy_alerts_enabled': false,
      });
      final h = _Harness();
      await _pump(tester, h);
      expect(find.text('League a'), findsOneWidget);
      expect(find.text('Home a'), findsOneWidget);
      expect(find.text('Alerts Off'), findsOneWidget);
      expect(find.text('Primary'), findsOneWidget);
      final config = (await h.store.readAll()).single;
      expect(config.teamDisplayName, 'Home a');
      expect(config.teamId, '1');
      expect(config.alertsEnabled, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getInt(
          'sleeper_fantasy_roster_id',
        ),
        1,
      );
    },
  );

  testWidgets('multiple saved Sleeper leagues appear simultaneously', (
    tester,
  ) async {
    final h = _Harness();
    for (final id in ['a', 'b', 'c']) {
      await h.store.upsert(_config(id));
    }
    await _pump(tester, h);
    for (final id in ['a', 'b', 'c']) {
      expect(find.text('League $id'), findsOneWidget);
      expect(find.text('Home $id'), findsOneWidget);
    }
    expect(find.text('Sleeper'), findsNWidgets(3));
    expect(find.text('Primary'), findsOneWidget);
  });

  testWidgets(
    'adding second and third league preserves peers and existing primary',
    (tester) async {
      final h = _Harness();
      await h.store.upsert(_config('a'));
      await _pump(tester, h);
      await _add(tester, 'b');
      expect((await h.store.readAll()).map((c) => c.leagueId), ['a', 'b']);
      await _add(tester, 'c');
      expect((await h.store.readAll()).map((c) => c.leagueId), ['a', 'b', 'c']);
      expect(h.coordinator.primaryLeagueId, 'sleeper:a');
      expect(find.text('League a'), findsOneWidget);
      expect(find.text('League b'), findsOneWidget);
      expect(find.text('League c'), findsOneWidget);
    },
  );

  testWidgets(
    'alert toggle updates only selected league and runtime keeps peer enabled',
    (tester) async {
      final h = _Harness();
      await h.store.upsert(_config('a'));
      await h.store.upsert(_config('b'));
      await _pump(tester, h);
      await h.coordinator.observe();
      await tester.tap(find.byKey(const ValueKey('alerts-sleeper:a')));
      await tester.pumpAndSettle();
      final configs = await h.store.readAll();
      expect(configs.first.alertsEnabled, isFalse);
      expect(configs.last.alertsEnabled, isTrue);
      expect(find.text('Alerts Off'), findsOneWidget);
      expect(find.text('Alerts On'), findsOneWidget);
      h.points = 11;
      final result = await h.coordinator.observe();
      expect(result.leagues['sleeper:a']!.alerts, isEmpty);
      expect(result.leagues['sleeper:b']!.alertCount, 1);
    },
  );

  testWidgets('changing team saves names and resets only edited league', (
    tester,
  ) async {
    final h = _Harness();
    await h.store.upsert(_config('a'));
    await h.store.upsert(_config('b'));
    await _pump(tester, h);
    await h.coordinator.observe();
    await tester.tap(find.byKey(const ValueKey('team-sleeper:b')));
    await tester.pumpAndSettle();
    await _chooseTeam(tester, 'Away b');
    await tester.tap(find.text('Save Team'));
    await tester.pumpAndSettle();
    final configs = await h.store.readAll();
    expect(configs.first.teamId, '1');
    expect(configs.last.teamId, '2');
    expect(configs.last.teamDisplayName, 'Away b');
    h.points = 11;
    final result = await h.coordinator.observe();
    expect(result.leagues['sleeper:a']!.alertCount, 1);
    expect(result.leagues['sleeper:b']!.baselineReset, isTrue);
  });

  testWidgets(
    'remove confirms, preserves others, falls back and clears final primary',
    (tester) async {
      final h = _Harness();
      await h.store.upsert(_config('b'));
      await h.store.upsert(_config('a'));
      await _pump(tester, h);
      expect(h.coordinator.primaryLeagueId, 'sleeper:a');
      await tester.tap(find.byKey(const ValueKey('remove-sleeper:a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await h.store.readAll()).length, 2);
      await _remove(tester, 'a');
      expect((await h.store.readAll()).single.leagueId, 'b');
      expect(h.coordinator.primaryLeagueId, 'sleeper:b');
      expect(find.text('League a'), findsNothing);
      await _remove(tester, 'b');
      expect(find.text('No fantasy leagues connected.'), findsOneWidget);
      expect(find.text('League b'), findsNothing);
      expect(h.coordinator.primaryLeagueId, isNull);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          SharedPreferencesFantasyPrimaryLeagueStore.storageKey,
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'Make Primary persists across coordinator recreation without resetting baselines',
    (tester) async {
      final h = _Harness();
      await h.store.upsert(_config('a'));
      await h.store.upsert(_config('b'));
      await _pump(tester, h);
      await h.coordinator.observe();
      await tester.tap(find.byKey(const ValueKey('primary-sleeper:b')));
      await tester.pumpAndSettle();
      expect(h.coordinator.primaryLeagueId, 'sleeper:b');
      h.points = 11;
      final result = await h.coordinator.observe();
      expect(result.alertCount, 2);
      expect(result.matchup!.league.leagueId, 'b');
      expect(result.leagues.values.every((r) => !r.baselineReset), isTrue);
      final recreated = _Harness();
      await recreated.coordinator.loadConfigurationStatus();
      expect(recreated.coordinator.primaryLeagueId, 'sleeper:b');
      expect((await recreated.coordinator.observe()).leagues.length, 2);
    },
  );

  testWidgets(
    'failed add and cancelled team selection leave collection unchanged',
    (tester) async {
      final h = _Harness();
      await h.store.upsert(_config('a'));
      final before = (await h.store.readAll()).single.toJson();
      h.failures.add('bad');
      await _pump(tester, h);
      await tester.tap(find.text('Add Fantasy League'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('provider-sleeper')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add by League ID instead'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'bad');
      await tester.tap(find.text('Load League'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          "We couldn't find that Sleeper league. Check the league ID and try again.",
        ),
        findsOneWidget,
      );
      expect((await h.store.readAll()).single.toJson(), before);
      await tester.enterText(find.byType(TextField), 'b');
      await tester.tap(find.text('Load League'));
      await tester.pumpAndSettle();
      expect(find.text('Choose your team'), findsOneWidget);
      expect((await h.store.readAll()).single.toJson(), before);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('League a'), findsOneWidget);
      expect(find.text('League b'), findsNothing);
    },
  );

  testWidgets(
    'missing roster can be repaired without silently clearing saved config',
    (tester) async {
      final h = _Harness();
      await h.store.upsert(_config('a', team: '99'));
      await _pump(tester, h);
      await tester.tap(find.byKey(const ValueKey('team-sleeper:a')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'That team is no longer available in this league. Please choose your team again.',
        ),
        findsOneWidget,
      );
      expect((await h.store.readAll()).single.teamId, '99');
      await _chooseTeam(tester, 'Home a');
      await tester.tap(find.text('Save Team'));
      await tester.pumpAndSettle();
      expect((await h.store.readAll()).single.teamId, '1');
    },
  );

  testWidgets('a failed name load is scoped and preserves other league cards', (
    tester,
  ) async {
    final h = _Harness();
    await h.store.upsert(
      const FantasyLeagueConfig(
        provider: FantasyProvider.sleeper,
        leagueId: 'bad',
        teamId: '1',
      ),
    );
    await h.store.upsert(_config('a'));
    h.failures.add('bad');
    await _pump(tester, h);
    expect(find.text('League a'), findsOneWidget);
    expect(find.text('Sleeper league bad'), findsOneWidget);
    expect((await h.store.readAll()).length, 2);
    expect(
      find.text(
        "We couldn't find that Sleeper league. Check the league ID and try again.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('view matchup retains scores, named starters and ID fallback', (
    tester,
  ) async {
    final h = _Harness();
    await h.store.upsert(_config('a'));
    await _pump(tester, h);
    await tester.tap(find.byKey(const ValueKey('view-sleeper:a')));
    await tester.pumpAndSettle();
    expect(find.text('League a'), findsOneWidget);
    expect(find.text('Home a'), findsWidgets);
    expect(find.text('Away a'), findsWidgets);
    expect(find.text('NFL Week 3'), findsOneWidget);
    expect(find.text('Sample Player'), findsOneWidget);
    expect(find.text('opponent-player'), findsOneWidget);
    expect(find.text('How fantasy alerts work'), findsOneWidget);
    await tester.tap(find.text('REFRESH MATCHUP'));
    await tester.pumpAndSettle();
    expect(find.text('Sample Player'), findsOneWidget);
  });

  testWidgets('league controls remain usable at narrow phone width', (
    tester,
  ) async {
    final h = _Harness();
    await h.store.upsert(_config('a'));
    await _pump(tester, h);
    tester.view.physicalSize = const Size(320, 640);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('team-sleeper:a')),
      150,
    );
    await tester.tap(find.byKey(const ValueKey('team-sleeper:a')));
    await tester.pumpAndSettle();
    expect(find.text('Choose your team'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disconnected test alert keeps friendly guidance', (
    tester,
  ) async {
    final h = _Harness(connected: false);
    await h.store.upsert(_config('a'));
    await _pump(tester, h);
    await tester.tap(find.text('SEND TEST ALERT'));
    await tester.pumpAndSettle();
    expect(
      find.text('Connect to SCRBRD before sending a test alert.'),
      findsOneWidget,
    );
    expect(h.transport.alerts, isEmpty);
  });
}

Future<void> _pump(WidgetTester tester, _Harness h) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: FantasyScreen(
        coordinator: h.coordinator,
        playerRepository: h.players,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _chooseTeam(WidgetTester tester, String team) async {
  await tester.tap(find.byType(DropdownButtonFormField<int>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(team).last);
  await tester.pumpAndSettle();
}

Future<void> _add(WidgetTester tester, String id) async {
  await tester.ensureVisible(find.text('Add Fantasy League'));
  await tester.tap(find.text('Add Fantasy League'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('provider-sleeper')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Add by League ID instead'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), id);
  await tester.tap(find.text('Load League'));
  await tester.pumpAndSettle();
  await _chooseTeam(tester, 'Home $id');
  await tester.tap(find.text('Add League'));
  await tester.pumpAndSettle();
}

Future<void> _remove(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('remove-sleeper:$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
  await tester.pumpAndSettle();
}

FantasyLeagueConfig _config(String id, {String team = '1'}) =>
    FantasyLeagueConfig(
      provider: FantasyProvider.sleeper,
      leagueId: id,
      teamId: team,
      displayName: 'League $id',
      teamDisplayName: 'Home $id',
    );

class _Harness {
  _Harness({bool connected = true}) {
    final api = SleeperApiClient(
      client: MockClient(
        (_) async => throw StateError('No live network in tests'),
      ),
    );
    players = SleeperPlayerRepository(apiClient: api, cache: _PlayerCache());
    coordinator = FantasyLiveObservationCoordinator(
      leagueConfigStore: store,
      repository: SleeperFantasyRepository(api),
      playerRepository: players,
      transport: transport,
      isBleConnected: () => connected,
      setupLoader: (id) async {
        if (failures.contains(id)) {
          throw const SleeperFantasyException('not found');
        }
        return _snapshot(id, points);
      },
      matchupLoader: (id) async => _snapshot(id, points),
      metadataResolver: (_) async => {},
    );
  }
  final store = SharedPreferencesFantasyLeagueConfigStore();
  final transport = _Transport();
  final failures = <String>{};
  double points = 10;
  late final SleeperPlayerRepository players;
  late final FantasyLiveObservationCoordinator coordinator;
}

class _Transport implements FantasyAlertTransport {
  final alerts = <FantasyPointAlert>[];
  @override
  Future<void> sendFantasyAlert(FantasyPointAlert alert) async =>
      alerts.add(alert);
}

class _PlayerCache implements SleeperPlayerCache {
  @override
  Future<CachedSleeperPlayers?> read() async => CachedSleeperPlayers(
    fetchedAt: DateTime.now(),
    players: const {
      'user-player': SleeperFantasyPlayer(
        sleeperPlayerId: 'user-player',
        fullName: 'Sample Player',
        firstName: 'Sample',
        lastName: 'Player',
        position: 'WR',
        nflTeam: 'CIN',
        espnPlayerId: null,
      ),
    },
  );
  @override
  Future<void> write(CachedSleeperPlayers cache) async {}
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
      week: 3,
      users: [
        SleeperUser(userId: 'home', displayName: 'Home $id'),
        SleeperUser(userId: 'away', displayName: 'Away $id'),
      ],
      rosters: const [
        SleeperRoster(
          rosterId: 1,
          ownerId: 'home',
          players: ['user-player'],
          starters: ['user-player'],
        ),
        SleeperRoster(
          rosterId: 2,
          ownerId: 'away',
          players: ['opponent-player'],
          starters: ['opponent-player'],
        ),
      ],
      matchups: [
        SleeperMatchup(
          rosterId: 1,
          matchupId: 9,
          points: points,
          starters: const ['user-player'],
          playerPoints: {'user-player': points},
        ),
        const SleeperMatchup(
          rosterId: 2,
          matchupId: 9,
          points: 5,
          starters: ['opponent-player'],
          playerPoints: {'opponent-player': 5},
        ),
      ],
    );
