import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports_hub_mobile/espn_fantasy_client.dart';
import 'package:sports_hub_mobile/espn_fantasy_credentials.dart';
import 'package:sports_hub_mobile/espn_fantasy_setup.dart';
import 'package:sports_hub_mobile/fantasy_alert_transport.dart';
import 'package:sports_hub_mobile/fantasy_league_config.dart';
import 'package:sports_hub_mobile/fantasy_live_observation_coordinator.dart';
import 'package:sports_hub_mobile/fantasy_matchup_display_data.dart';
import 'package:sports_hub_mobile/fantasy_matchup_transport.dart';
import 'package:sports_hub_mobile/fantasy_point_alert.dart';
import 'package:sports_hub_mobile/fantasy_provider_models.dart';
import 'package:sports_hub_mobile/fantasy_screen.dart';
import 'package:sports_hub_mobile/sleeper_api_client.dart';
import 'package:sports_hub_mobile/sleeper_fantasy_repository.dart';
import 'package:sports_hub_mobile/sleeper_player_repository.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'provider choice offers Sleeper and ESPN; no credentials prompts',
    (tester) async {
      final h = _Harness();
      await h.pump(tester);
      await _openEspn(tester);
      expect(find.text('SWID'), findsOneWidget);
      expect(find.text('espn_s2'), findsOneWidget);
      expect(find.textContaining('stored securely'), findsOneWidget);
      expect(find.text('ESPN League ID'), findsOneWidget);
      expect(find.byKey(const ValueKey('provider-sleeper')), findsNothing);
    },
  );

  testWidgets('invalid credentials are rejected without saving or leaking', (
    tester,
  ) async {
    final h = _Harness();
    h.gateway.failure = EspnFantasyFailure.unauthorized;
    await h.pump(tester);
    await _openEspn(tester);
    await _enterCredentials(tester);
    await tester.enterText(
      find.byKey(const ValueKey('espn-league-id')),
      '12345',
    );
    await tester.tap(find.text('Connect and Load League'));
    await tester.pumpAndSettle();
    expect(find.textContaining('rejected these cookies'), findsOneWidget);
    expect(h.credentials.value, isNull);
    expect(await h.store.readAll(), isEmpty);
  });

  testWidgets('league schema diagnostics show safe structure only', (
    tester,
  ) async {
    final h = _Harness();
    h.gateway.failure = EspnFantasyFailure.invalidResponse;
    h.gateway.diagnostic =
        'league.status; id=number, status=null, teams=list(12)';
    await h.pump(tester);
    await _openEspn(tester);
    await _enterCredentials(tester);
    await tester.enterText(
      find.byKey(const ValueKey('espn-league-id')),
      '12345',
    );
    await tester.tap(find.text('Connect and Load League'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Safe ESPN diagnostic: league.status'),
      findsOneWidget,
    );
    expect(await h.store.readAll(), isEmpty);
    expect(h.credentials.value, isNull);
  });

  testWidgets(
    'matchup validation shows sanitized details without saving league',
    (tester) async {
      final h = _Harness();
      await h.credentials.save(
        const EspnFantasyCredentials(swid: '{FAKE}', espnS2: 'fake-espn-s2'),
      );
      h.gateway.matchupFailure = EspnFantasyFailure.invalidResponse;
      h.gateway.diagnostic =
          'matchup.side.rosterForCurrentScoringPeriod.entries; roster=null';
      await h.pump(tester);
      await _openEspn(tester);
      await tester.enterText(
        find.byKey(const ValueKey('espn-league-id')),
        '12345',
      );
      await tester.tap(find.text('Load League'));
      await tester.pumpAndSettle();
      await _selectTeam(tester, 'Home 12345');
      await tester.tap(find.text('Add League'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Safe ESPN diagnostic: matchup.side'),
        findsOneWidget,
      );
      expect(await h.store.readAll(), isEmpty);
    },
  );

  testWidgets(
    'add three ESPN leagues with one secure account and a Sleeper peer',
    (tester) async {
      final h = _Harness();
      await h.store.upsert(
        const FantasyLeagueConfig(
          provider: FantasyProvider.sleeper,
          leagueId: '12345',
          teamId: '1',
          displayName: 'Sleeper peer',
          teamDisplayName: 'Sleeper team',
        ),
      );
      await h.pump(tester);
      for (final id in ['12345', '67890', '54321']) {
        await _openEspn(tester);
        if (id == '12345') {
          await _enterCredentials(tester);
        } else {
          expect(find.byKey(const ValueKey('espn-swid')), findsNothing);
        }
        await tester.enterText(
          find.byKey(const ValueKey('espn-league-id')),
          id,
        );
        await tester.tap(
          find.text(id == '12345' ? 'Connect and Load League' : 'Load League'),
        );
        await tester.pumpAndSettle();
        expect(find.text('ESPN League $id'), findsOneWidget);
        await _selectTeam(tester, 'Away $id');
        await tester.tap(find.text('Add League'));
        await tester.pumpAndSettle();
      }
      final configs = await h.store.readAll();
      expect(configs.length, 4);
      expect(configs.map((c) => c.id).toSet(), {
        'sleeper:12345',
        'espn:12345',
        'espn:67890',
        'espn:54321',
      });
      expect(
        configs
            .where((c) => c.provider == FantasyProvider.espn)
            .every(
              (c) => c.teamId == '8' && c.teamDisplayName!.startsWith('Away '),
            ),
        isTrue,
      );
      expect(h.credentials.saves, 1);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getKeys().join(' '), isNot(contains('fake-espn-s2')));
      expect(
        preferences.getString(
          SharedPreferencesFantasyLeagueConfigStore.storageKey,
        ),
        isNot(contains('fake-espn-s2')),
      );
      expect(h.gateway.validations, 1);
    },
  );

  testWidgets(
    'ESPN primary sends normalized matchup and later enters observation',
    (tester) async {
      final h = _Harness();
      await h.credentials.save(
        const EspnFantasyCredentials(swid: '{FAKE}', espnS2: 'fake-espn-s2'),
      );
      await h.store.upsert(_espnConfig('12345'));
      await h.store.upsert(_espnConfig('11111'));
      await h.pump(tester);
      await tester.tap(find.byKey(const ValueKey('primary-espn:12345')));
      await tester.pumpAndSettle();
      expect(h.coordinator.primaryLeagueId, 'espn:12345');
      expect(h.transport.matchups.single.userName, 'Home 12345');
      expect(h.transport.matchups.single.userScore, 102.375);
      expect(h.transport.matchups.single.week, 3);
      expect(h.transport.alerts, isEmpty);
      expect(h.gateway.matchupLoads, greaterThan(0));
      expect(h.sleeperLoads, 0);
      expect(await h.coordinator.syncStartupCategory(), isTrue);
      final displayLoads = h.gateway.matchupLoads;
      final observation = await h.coordinator.observe();
      expect(observation.alerts, isEmpty);
      expect(h.gateway.matchupLoads, displayLoads + 2);
      expect(h.transport.alerts, isEmpty);
      expect(h.transport.matchups, isNotEmpty);
      await tester.tap(find.byKey(const ValueKey('view-espn:12345')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Quarterback: 12.345'), 150);
      expect(find.text('Quarterback: 12.345'), findsOneWidget);
      expect(find.textContaining('Bench'), findsNothing);
      expect(find.textContaining('Scoring period 4'), findsOneWidget);
      await tester.tap(find.text('REFRESH MATCHUP'));
      await tester.pumpAndSettle();
      expect(h.transport.alerts, isEmpty);
    },
  );

  testWidgets('disconnect keeps configs; reconnect restores matchup access', (
    tester,
  ) async {
    final h = _Harness();
    await h.credentials.save(
      const EspnFantasyCredentials(swid: '{FAKE}', espnS2: 'fake-espn-s2'),
    );
    await h.store.upsert(_espnConfig('12345'));
    await h.pump(tester);
    await h.coordinator.syncPrimaryEspnMatchup();
    expect(h.transport.matchups, isNotEmpty);
    await tester.tap(find.text('ESPN Connection'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect ESPN'));
    await tester.pumpAndSettle();
    expect(h.credentials.value, isNull);
    expect(h.transport.matchups, isEmpty);
    expect((await h.store.readAll()).single.id, 'espn:12345');
    expect(find.text('ESPN needs reconnection'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('view-espn:12345')));
    await tester.pumpAndSettle();
    expect(find.textContaining('needs reconnection'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('ESPN Connection'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('manage-espn-swid')),
      '{NEW-FAKE}',
    );
    await tester.enterText(
      find.byKey(const ValueKey('manage-espn-s2')),
      'new-fake-s2',
    );
    await tester.tap(find.text('Reconnect ESPN'));
    await tester.pumpAndSettle();
    expect(h.credentials.value!.swid, '{NEW-FAKE}');
    expect(h.transport.matchups, isNotEmpty);
    expect(find.text('ESPN needs reconnection'), findsNothing);
    expect((await h.store.readAll()).single.id, 'espn:12345');
  });

  testWidgets('edit and remove ESPN preserve peers, credentials and fallback', (
    tester,
  ) async {
    final h = _Harness();
    await h.credentials.save(
      const EspnFantasyCredentials(swid: '{FAKE}', espnS2: 'fake-espn-s2'),
    );
    await h.store.upsert(_espnConfig('12345'));
    await h.store.upsert(_espnConfig('67890'));
    await h.pump(tester);
    await tester.tap(find.byKey(const ValueKey('team-espn:12345')));
    await tester.pumpAndSettle();
    await _selectTeam(tester, 'Away 12345');
    await tester.tap(find.text('Save Team'));
    await tester.pumpAndSettle();
    expect(
      (await h.store.readAll()).firstWhere((c) => c.id == 'espn:12345').teamId,
      '8',
    );
    expect(
      (await h.store.readAll()).firstWhere((c) => c.id == 'espn:67890').teamId,
      '7',
    );
    await tester.tap(find.byKey(const ValueKey('remove-espn:12345')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect((await h.store.readAll()).single.id, 'espn:67890');
    expect(h.coordinator.primaryLeagueId, 'espn:67890');
    expect(h.credentials.value, isNotNull);
  });

  testWidgets('auth and network failures leave saved ESPN configs intact', (
    tester,
  ) async {
    final h = _Harness();
    await h.credentials.save(
      const EspnFantasyCredentials(swid: '{FAKE}', espnS2: 'fake-espn-s2'),
    );
    await h.store.upsert(_espnConfig('12345'));
    h.gateway.failure = EspnFantasyFailure.network;
    await h.pump(tester);
    await tester.tap(find.byKey(const ValueKey('view-espn:12345')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not reach ESPN'), findsOneWidget);
    expect((await h.store.readAll()).single.id, 'espn:12345');
    expect(h.transport.alerts, isEmpty);
  });
}

Future<void> _openEspn(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Add Fantasy League'));
  await tester.tap(find.text('Add Fantasy League'));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('provider-sleeper')), findsOneWidget);
  expect(find.byKey(const ValueKey('provider-espn')), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('provider-espn')));
  await tester.pumpAndSettle();
}

Future<void> _enterCredentials(WidgetTester tester) async {
  await tester.enterText(find.byKey(const ValueKey('espn-swid')), '{FAKE}');
  await tester.enterText(find.byKey(const ValueKey('espn-s2')), 'fake-espn-s2');
}

Future<void> _selectTeam(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const ValueKey('espn-team')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

FantasyLeagueConfig _espnConfig(String id) => FantasyLeagueConfig(
  provider: FantasyProvider.espn,
  leagueId: id,
  teamId: '7',
  displayName: 'ESPN League $id',
  teamDisplayName: 'Home $id',
);

class _Harness {
  _Harness() {
    final api = SleeperApiClient(
      client: MockClient((_) async => throw StateError('No live requests')),
    );
    players = SleeperPlayerRepository(apiClient: api);
    coordinator = FantasyLiveObservationCoordinator(
      leagueConfigStore: store,
      repository: SleeperFantasyRepository(api),
      playerRepository: players,
      transport: transport,
      isBleConnected: () => true,
      setupLoader: (_) async {
        sleeperLoads++;
        throw StateError('Sleeper setup called');
      },
      matchupLoader: (_) async {
        sleeperLoads++;
        throw StateError('Sleeper observation called');
      },
      espnMatchupLoader: gateway.loadMatchup,
    );
  }
  final store = SharedPreferencesFantasyLeagueConfigStore();
  final credentials = _Credentials();
  final gateway = _Gateway();
  final transport = _Transport();
  late final SleeperPlayerRepository players;
  late final FantasyLiveObservationCoordinator coordinator;
  int sleeperLoads = 0;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    gateway.credentials = credentials;
    await tester.pumpWidget(
      MaterialApp(
        home: FantasyScreen(
          coordinator: coordinator,
          playerRepository: players,
          espnCredentialsStore: credentials,
          espnGateway: gateway,
          espnSeason: 2030,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

class _Credentials implements EspnFantasyCredentialsStore {
  EspnFantasyCredentials? value;
  int saves = 0;
  @override
  Future<EspnFantasyCredentials?> read() async => value;
  @override
  Future<bool> hasCredentials() async => value != null;
  @override
  Future<void> save(EspnFantasyCredentials credentials) async {
    value = credentials;
    saves++;
  }

  @override
  Future<void> clear() async => value = null;
}

class _Gateway implements EspnFantasySetupGateway {
  late _Credentials credentials;
  EspnFantasyFailure? failure;
  EspnFantasyFailure? matchupFailure;
  String? diagnostic;
  int validations = 0;
  int matchupLoads = 0;

  void _check() {
    if (failure case final value?) {
      throw EspnFantasyException(value, diagnostic: diagnostic);
    }
  }

  @override
  Future<FantasyLeagueDetails> validateAndLoadLeague(
    EspnFantasyCredentials candidate,
    int season,
    String id,
  ) async {
    validations++;
    _check();
    if (!candidate.isValid) {
      throw const EspnFantasyException(EspnFantasyFailure.unauthorized);
    }
    return _league(id);
  }

  @override
  Future<FantasyLeagueDetails> loadLeague(int season, String id) async {
    _check();
    if (credentials.value == null) {
      throw const EspnFantasyException(EspnFantasyFailure.missingCredentials);
    }
    return _league(id);
  }

  @override
  Future<FantasyMatchupSnapshot> loadMatchup(
    int season,
    String id,
    String teamId,
  ) async {
    matchupLoads++;
    if (matchupFailure case final value?) {
      throw EspnFantasyException(value, diagnostic: diagnostic);
    }
    _check();
    if (credentials.value == null) {
      throw const EspnFantasyException(EspnFantasyFailure.missingCredentials);
    }
    if (teamId != '7' && teamId != '8') {
      throw const EspnFantasyException(EspnFantasyFailure.teamUnavailable);
    }
    final league = _league(id);
    final home = FantasyScoringTeam(
      team: league.teams.first,
      totalPoints: 102.375,
      starters: const [
        FantasyScoringPlayer(id: '101', name: 'Quarterback', points: 12.345),
      ],
    );
    final away = FantasyScoringTeam(
      team: league.teams.last,
      totalPoints: 97.125,
      starters: const [
        FantasyScoringPlayer(id: '201', name: 'Receiver', points: 7.125),
      ],
    );
    return FantasyMatchupSnapshot(
      league: league,
      team: teamId == '7' ? home : away,
      opponent: teamId == '7' ? away : home,
    );
  }

  FantasyLeagueDetails _league(String id) => FantasyLeagueDetails(
    provider: FantasyProvider.espn,
    leagueId: id,
    season: 2030,
    name: 'ESPN League $id',
    scoringPeriod: 4,
    matchupPeriod: 3,
    teams: [
      FantasyTeamDetails(id: '7', name: 'Home $id'),
      FantasyTeamDetails(id: '8', name: 'Away $id'),
    ],
  );
}

class _Transport implements FantasyAlertTransport, FantasyMatchupTransport {
  final alerts = <FantasyPointAlert>[];
  final matchups = <FantasyMatchupDisplayData>[];
  @override
  Future<void> sendFantasyAlert(FantasyPointAlert alert) async =>
      alerts.add(alert);
  @override
  Future<void> sendFantasyMatchup(FantasyMatchupDisplayData matchup) async =>
      matchups.add(matchup);
  @override
  Future<void> clearFantasyMatchup() async => matchups.clear();
}
