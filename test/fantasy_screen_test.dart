import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sports_hub_mobile/fantasy_alert_transport.dart';
import 'package:sports_hub_mobile/fantasy_live_observation_coordinator.dart';
import 'package:sports_hub_mobile/fantasy_point_alert.dart';
import 'package:sports_hub_mobile/fantasy_screen.dart';
import 'package:sports_hub_mobile/sleeper_api_client.dart';
import 'package:sports_hub_mobile/sleeper_fantasy_config.dart';
import 'package:sports_hub_mobile/sleeper_fantasy_repository.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';
import 'package:sports_hub_mobile/sleeper_player_repository.dart';

void main() {
  testWidgets('not-configured screen is consumer-facing', (tester) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Connect your Sleeper league to get live fantasy scoring alerts on SCRBRD.',
      ),
      findsOneWidget,
    );
    expect(find.text('Sleeper League ID'), findsOneWidget);
    expect(find.text('CONNECT LEAGUE'), findsOneWidget);
    expect(find.textContaining('diagnostic'), findsNothing);
    expect(find.textContaining('pending'), findsNothing);
    expect(find.textContaining('baseline'), findsNothing);
  });

  testWidgets('invalid league shows a friendly consumer error', (tester) async {
    final harness = _Harness(
      setupError: const SleeperFantasyException('not found'),
    );
    await tester.pumpWidget(harness.app());
    await tester.enterText(find.byType(TextField), 'bad');
    await tester.tap(find.text('CONNECT LEAGUE'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        "We couldn't find that Sleeper league. Check the league ID and try again.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('league loads friendly team names and selection persists', (
    tester,
  ) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.app());
    await tester.enterText(find.byType(TextField), 'league-1');
    await tester.tap(find.text('CONNECT LEAGUE'));
    await tester.pumpAndSettle();

    expect(find.text('Sunday Heroes'), findsOneWidget);
    expect(find.text('Choose your team'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    expect(find.text("Peter's Team"), findsWidgets);
    expect(find.text("Mike's Team"), findsWidgets);
    await tester.tap(find.text("Peter's Team").last);
    await tester.pumpAndSettle();

    expect((await harness.config.read())!.rosterId, 1);
    expect((await harness.config.read())!.alertsEnabled, isTrue);
    expect(find.text('ACTIVE'), findsOneWidget);
  });

  testWidgets(
    'configured view shows matchup, named starters, and ID fallback',
    (tester) async {
      final harness = _Harness(
        initialConfig: const SleeperFantasyConfig(
          leagueId: 'league-1',
          rosterId: 1,
        ),
      );
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();

      expect(find.text('Fantasy Alerts'), findsOneWidget);
      expect(find.text('Sunday Heroes'), findsOneWidget);
      expect(find.text("Peter's Team"), findsWidgets);
      expect(find.text("Mike's Team"), findsWidgets);
      expect(find.text('104.7'), findsOneWidget);
      expect(find.text('97.2'), findsOneWidget);
      expect(find.text('NFL Week 3'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text("Ja'Marr Chase"),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text("Ja'Marr Chase"), findsOneWidget);
      expect(find.text('opponent-player'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('How fantasy alerts work'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('How fantasy alerts work'), findsOneWidget);
    },
  );

  testWidgets(
    'missing saved roster returns to team choice with friendly error',
    (tester) async {
      final harness = _Harness(
        initialConfig: const SleeperFantasyConfig(
          leagueId: 'league-1',
          rosterId: 99,
        ),
      );
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();

      expect(find.text('Choose your team'), findsOneWidget);
      expect(
        find.text(
          'That team is no longer available in this league. '
          'Please choose your team again.',
        ),
        findsOneWidget,
      );
      expect((await harness.config.read())!.rosterId, isNull);
    },
  );

  testWidgets('toggle persists and disconnected test alert is friendly', (
    tester,
  ) async {
    final harness = _Harness(
      initialConfig: const SleeperFantasyConfig(
        leagueId: 'league-1',
        rosterId: 1,
      ),
      connected: false,
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect((await harness.config.read())!.alertsEnabled, isFalse);

    await tester.scrollUntilVisible(
      find.text('SEND TEST ALERT'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('SEND TEST ALERT'));
    await tester.pumpAndSettle();
    expect(
      find.text('Connect to SCRBRD before sending a test alert.'),
      findsOneWidget,
    );
    expect(harness.transport.alerts, isEmpty);
  });
}

class _Harness {
  _Harness({this.initialConfig, this.setupError, this.connected = true})
    : config = _ConfigStore(initialConfig),
      transport = _Transport();

  final SleeperFantasyConfig? initialConfig;
  final Object? setupError;
  final bool connected;
  final _ConfigStore config;
  final _Transport transport;

  Widget app() {
    final api = SleeperApiClient(
      client: MockClient((_) async => throw 'unused'),
    );
    final players = SleeperPlayerRepository(
      apiClient: api,
      cache: _PlayerCache(
        CachedSleeperPlayers(
          fetchedAt: DateTime.now(),
          players: const {'user-player': _chase},
        ),
      ),
    );
    final repository = SleeperFantasyRepository(api);
    final coordinator = FantasyLiveObservationCoordinator(
      configStore: config,
      repository: repository,
      playerRepository: players,
      transport: transport,
      isBleConnected: () => connected,
      setupLoader: (_) async {
        if (setupError case final error?) throw error;
        return _snapshot;
      },
      matchupLoader: (_) async => _snapshot,
      metadataResolver: (_) async => const {'user-player': _chase},
    );
    return MaterialApp(
      home: FantasyScreen(
        coordinator: coordinator,
        configStore: config,
        playerRepository: players,
      ),
    );
  }
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

class _Transport implements FantasyAlertTransport {
  final alerts = <FantasyPointAlert>[];

  @override
  Future<void> sendFantasyAlert(FantasyPointAlert alert) async =>
      alerts.add(alert);
}

class _PlayerCache implements SleeperPlayerCache {
  _PlayerCache(this.value);
  CachedSleeperPlayers? value;

  @override
  Future<CachedSleeperPlayers?> read() async => value;

  @override
  Future<void> write(CachedSleeperPlayers cache) async => value = cache;
}

final _snapshot = SleeperLeagueSnapshot(
  league: const SleeperLeague(
    leagueId: 'league-1',
    name: 'Sunday Heroes',
    season: '2026',
    status: 'in_season',
    scoringSettings: {},
    rosterPositions: [],
  ),
  week: 3,
  users: const [
    SleeperUser(userId: 'user', displayName: 'Peter', teamName: "Peter's Team"),
    SleeperUser(
      userId: 'opponent',
      displayName: 'Mike',
      teamName: "Mike's Team",
    ),
  ],
  rosters: const [
    SleeperRoster(
      rosterId: 1,
      ownerId: 'user',
      players: ['user-player'],
      starters: ['user-player'],
    ),
    SleeperRoster(
      rosterId: 2,
      ownerId: 'opponent',
      players: ['opponent-player'],
      starters: ['opponent-player'],
    ),
  ],
  matchups: const [
    SleeperMatchup(
      rosterId: 1,
      matchupId: 9,
      points: 104.7,
      starters: ['user-player'],
      playerPoints: {'user-player': 23.4},
    ),
    SleeperMatchup(
      rosterId: 2,
      matchupId: 9,
      points: 97.2,
      starters: ['opponent-player'],
      playerPoints: {'opponent-player': 19.8},
    ),
  ],
);

const _chase = SleeperFantasyPlayer(
  sleeperPlayerId: 'user-player',
  fullName: "Ja'Marr Chase",
  firstName: "Ja'Marr",
  lastName: 'Chase',
  position: 'WR',
  nflTeam: 'CIN',
  espnPlayerId: null,
);
