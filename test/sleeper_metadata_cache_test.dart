import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports_hub_mobile/fantasy_alert_transport.dart';
import 'package:sports_hub_mobile/fantasy_league_config.dart';
import 'package:sports_hub_mobile/fantasy_live_observation_coordinator.dart';
import 'package:sports_hub_mobile/sleeper_player_repository.dart';
import 'package:sports_hub_mobile/sleeper_projection.dart';
import 'package:sports_hub_mobile/sleeper_api_client.dart';
import 'package:sports_hub_mobile/sleeper_fantasy_repository.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';

void main() {
  test(
    'F22 expired metadata updates league, scoring, names and ownership atomically',
    () async {
      final h = Fixture();
      await h.repository.loadLeague('league');
      h.api.version = 2;
      h.now = h.now.add(const Duration(hours: 1));
      final result = await h.repository.refreshMatchups('league');
      expect(result.league.name, 'League 2');
      expect(result.league.scoringSettings, {'rush_yd': 2.0});
      expect(result.rosters.first.ownerId, 'owner2');
      expect(result.matchupForRoster(1).team.name, 'Team 2');
      expect(result.matchups.first.points, 12);
      expect(h.api.metadataRequests, 6);
      await h.repository.refreshMatchups('league');
      expect(h.api.metadataRequests, 6);
    },
  );
  test(
    'F22 week transition refreshes metadata alongside the new matchups',
    () async {
      final h = Fixture();
      await h.repository.loadLeague('league');
      h.api
        ..week = 2
        ..version = 2;
      h.now = h.now.add(const Duration(hours: 7));
      final result = await h.repository.refreshMatchups('league');
      expect(result.week, 2);
      expect(result.league.name, 'League 2');
      expect(result.matchupForRoster(1).team.name, 'Team 2');
    },
  );
  test(
    'F22 failed metadata refresh retains a coherent cache and retries with bounded polling',
    () async {
      final h = Fixture();
      await h.repository.loadLeague('league');
      h.now = h.now.add(const Duration(hours: 1));
      h.api
        ..version = 2
        ..failUsers = true
        ..points = 15;
      final result = await h.repository.refreshMatchups('league');
      expect(h.api.metadataRequests, 6);
      expect(result.league.name, 'League 1');
      expect(result.rosters.first.ownerId, 'owner1');
      expect(result.matchupForRoster(1).team.name, 'Team 1');
      expect(result.matchups.first.points, 15);
      await h.repository.refreshMatchups('league');
      expect(h.api.metadataRequests, 6);
      h.api.failUsers = false;
      h.now = h.now.add(const Duration(minutes: 1));
      expect(
        (await h.repository.refreshMatchups('league')).league.name,
        'League 2',
      );
      expect(h.api.metadataRequests, 9);
    },
  );
  test(
    'F22 ordinary matchup refresh does not poll metadata before expiration',
    () async {
      final h = Fixture();
      await h.repository.loadLeague('league');
      for (var i = 0; i < 20; i++) {
        h.now = h.now.add(const Duration(seconds: 20));
        await h.repository.refreshMatchups('league');
      }
      expect(h.api.metadataRequests, 3);
      expect(h.api.stateRequests, 1);
      expect(h.api.matchupRequests, 21);
    },
  );
  test(
    'F22 configuration edits expire only the affected cached league',
    () async {
      SharedPreferences.setMockInitialValues({});
      final h = Fixture();
      await h.repository.loadLeague('league');
      await h.repository.loadLeague('peer');
      final store = SharedPreferencesFantasyLeagueConfigStore();
      await store.upsert(
        const FantasyLeagueConfig(
          provider: FantasyProvider.sleeper,
          leagueId: 'league',
          teamId: '1',
        ),
      );
      final coordinator = FantasyLiveObservationCoordinator(
        leagueConfigStore: store,
        repository: h.repository,
        playerRepository: SleeperPlayerRepository(apiClient: h.api),
        transport: Alerts(),
        isBleConnected: () => false,
      );
      addTearDown(coordinator.dispose);
      await coordinator.loadConfigurationStatus();
      h.api.version = 2;
      await store.upsert(
        const FantasyLeagueConfig(
          provider: FantasyProvider.sleeper,
          leagueId: 'league',
          teamId: '2',
        ),
      );
      await coordinator.loadConfigurationStatus();
      expect(
        (await h.repository.refreshMatchups('league')).league.name,
        'League 2',
      );
      expect(h.api.metadataRequests, 9);
      await coordinator.loadConfigurationStatus();
      expect(
        (await h.repository.refreshMatchups('peer')).league.name,
        'League 1',
      );
      await h.repository.refreshMatchups('league');
      expect(h.api.metadataRequests, 9);
      await store.remove(FantasyProvider.sleeper, 'league');
      await coordinator.loadConfigurationStatus();
      h.api.version = 3;
      await store.upsert(
        const FantasyLeagueConfig(
          provider: FantasyProvider.sleeper,
          leagueId: 'league',
          teamId: '2',
        ),
      );
      await coordinator.loadConfigurationStatus();
      expect(
        (await h.repository.refreshMatchups('league')).league.name,
        'League 3',
      );
      expect(h.api.metadataRequests, 12);
    },
  );
  test(
    'F22 refreshed scoring settings recalculate pregame projections without changing actual totals',
    () async {
      final h = Fixture();
      final statuses = Statuses();
      final projection = SleeperSettlingProjectionService(
        projectionSource: Projections(),
        baselineStore: Baselines(),
        gameStatusSource: statuses,
        metadataResolver: (ids) async => {
          for (final id in ids)
            id: SleeperFantasyPlayer(
              sleeperPlayerId: id,
              fullName: id,
              firstName: id,
              lastName: '',
              position: 'RB',
              nflTeam: id == 'a' ? 'BUF' : 'KC',
              espnPlayerId: null,
            ),
        },
      );
      final first = (await h.repository.loadLeague(
        'league',
      )).matchupForRoster(1);
      await projection.refresh(first);
      expect(
        (await projection.applyCached(first)).team.projectedTotalPoints,
        10,
      );
      h.api.version = 2;
      h.now = h.now.add(const Duration(hours: 1));
      final updated = (await h.repository.refreshMatchups(
        'league',
      )).matchupForRoster(1);
      await projection.refresh(updated);
      final enriched = await projection.applyCached(updated);
      expect(enriched.team.projectedTotalPoints, 20);
      expect(enriched.team.matchup.points, first.team.matchup.points);
      expect(updated.league.leagueId, first.league.leagueId);
      statuses.phase = SleeperNflGamePhase.live;
      h.api.version = 3;
      h.now = h.now.add(const Duration(hours: 1));
      final live = (await h.repository.refreshMatchups(
        'league',
      )).matchupForRoster(1);
      // A new rules signature must never use the old frozen points. Without a
      // new pregame baseline the existing projection policy stays unavailable.
      expect(
        (await projection.applyCached(live)).team.projectedTotalPoints,
        isNull,
      );
      await projection.refresh(live);
      expect(
        (await projection.applyCached(live)).team.projectedTotalPoints,
        isNull,
      );
      statuses.phase = SleeperNflGamePhase.finalStatus;
      await projection.refresh(live);
      expect(
        (await projection.applyCached(live)).team.projectedTotalPoints,
        12,
      );
      expect(live.team.matchup.points, first.team.matchup.points);
    },
  );
  test(
    'F22 period change refreshes even unexpired metadata and catches season-type changes',
    () async {
      final h = Fixture(metadataInterval: const Duration(days: 1));
      h.api.seasonType = 'pre';
      await h.repository.loadLeague('league');
      h.api
        ..version = 2
        ..seasonType = 'regular';
      h.now = h.now.add(const Duration(hours: 7));
      final result = await h.repository.refreshMatchups('league');
      expect(result.week, 1);
      expect(result.seasonType, 'regular');
      expect(result.league.name, 'League 2');
    },
  );
  test(
    'F22 metadata failure during a week change remains retryable after week commits',
    () async {
      final h = Fixture(metadataInterval: const Duration(days: 1));
      await h.repository.loadLeague('league');
      h.api
        ..version = 2
        ..week = 2
        ..failUsers = true;
      h.now = h.now.add(const Duration(hours: 7));
      final failed = await h.repository.refreshMatchups('league');
      expect(failed.week, 2);
      expect(failed.league.name, 'League 1');
      h.api.failUsers = false;
      h.now = h.now.add(const Duration(minutes: 1));
      final recovered = await h.repository.refreshMatchups('league');
      expect(recovered.week, 2);
      expect(recovered.league.name, 'League 2');
      expect(h.api.stateRequests, 2);
    },
  );
  test(
    'F22 overlapping refreshes coalesce and release ownership after failure',
    () async {
      final h = Fixture();
      await h.repository.loadLeague('league');
      h.now = h.now.add(const Duration(hours: 1));
      h.api.matchupGate = Completer<void>();
      final first = h.repository.refreshMatchups('league');
      final second = h.repository.refreshMatchups('league');
      expect(identical(first, second), isTrue);
      h.api.matchupGate!.complete();
      await Future.wait([first, second]);
      expect(h.api.matchupRequests, 2);
      expect(h.api.metadataRequests, 6);
      h.api
        ..matchupGate = null
        ..failMatchups = true;
      await expectLater(
        h.repository.refreshMatchups('league'),
        throwsA(isA<SleeperApiException>()),
      );
      h.api.failMatchups = false;
      await h.repository.refreshMatchups('league');
      expect(h.api.matchupRequests, 4);
    },
  );
  test('F22 configuration invalidation during a fetch is not lost', () async {
    final h = Fixture();
    await h.repository.loadLeague('league');
    h.now = h.now.add(const Duration(hours: 1));
    h.api
      ..version = 2
      ..usersGate = Completer<void>();
    final pending = h.repository.refreshMatchups('league');
    for (var i = 0; i < 20 && h.api.metadataRequests < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(h.api.metadataRequests, 6);
    h.repository.expireMetadata('league');
    h.api.version = 3;
    h.api.usersGate!.complete();
    await pending;
    h.api.usersGate = null;
    final next = await h.repository.refreshMatchups('league');
    expect(next.league.name, 'League 3');
    expect(h.api.metadataRequests, 9);
  });
  test(
    'F22 mismatched provider league identity cannot replace cached metadata',
    () async {
      final h = Fixture();
      await h.repository.loadLeague('league');
      h.now = h.now.add(const Duration(hours: 1));
      h.api
        ..wrongLeague = true
        ..version = 2;
      final result = await h.repository.refreshMatchups('league');
      expect(result.league.leagueId, 'league');
      expect(result.league.name, 'League 1');
      expect(result.rosters.first.ownerId, 'owner1');
    },
  );
  test(
    'F22 failed explicit reload preserves cached metadata and cold failure is not cached',
    () async {
      final h = Fixture();
      h.api.failUsers = true;
      await expectLater(h.repository.loadLeague('league'), throwsA(anything));
      h.api.failUsers = false;
      expect(
        (await h.repository.refreshMatchups('league')).league.name,
        'League 1',
      );
      h.api.failUsers = true;
      await expectLater(h.repository.loadLeague('league'), throwsA(anything));
      h.api.failUsers = false;
      expect(
        (await h.repository.refreshMatchups('league')).league.name,
        'League 1',
      );
      expect(h.api.metadataRequests, 9);
    },
  );
}

class Fixture {
  Fixture({Duration metadataInterval = const Duration(hours: 1)}) {
    repository = SleeperFantasyRepository(
      api,
      clock: () => now,
      metadataRefreshInterval: metadataInterval,
    );
  }
  DateTime now = DateTime(2026, 10, 15, 12);
  final api = Api();
  late final SleeperFantasyRepository repository;
}

class Api extends SleeperApiClient {
  int version = 1;
  int week = 1;
  double points = 12;
  bool failUsers = false;
  bool failMatchups = false;
  bool wrongLeague = false;
  String seasonType = 'regular';
  Completer<void>? matchupGate;
  Completer<void>? usersGate;
  int metadataRequests = 0;
  int stateRequests = 0;
  int matchupRequests = 0;
  @override
  Future<SleeperLeague> fetchLeague(String leagueId) async {
    metadataRequests++;
    return SleeperLeague(
      leagueId: wrongLeague ? 'other-league' : leagueId,
      name: 'League $version',
      season: '2026',
      status: 'in_season',
      scoringSettings: {'rush_yd': version.toDouble()},
      rosterPositions: ['RB'],
    );
  }

  @override
  Future<List<SleeperUser>> fetchLeagueUsers(String leagueId) async {
    metadataRequests++;
    if (failUsers) throw const SleeperApiException('provider unavailable');
    final result = [
      SleeperUser(userId: 'owner$version', displayName: 'Team $version'),
      const SleeperUser(userId: 'other', displayName: 'Other'),
    ];
    await usersGate?.future;
    return result;
  }

  @override
  Future<List<SleeperRoster>> fetchLeagueRosters(String leagueId) async {
    metadataRequests++;
    return [
      SleeperRoster(
        rosterId: 1,
        ownerId: 'owner$version',
        players: ['a'],
        starters: ['a'],
      ),
      const SleeperRoster(
        rosterId: 2,
        ownerId: 'other',
        players: ['b'],
        starters: ['b'],
      ),
    ];
  }

  @override
  Future<SleeperNflState> fetchNflState() async {
    stateRequests++;
    return SleeperNflState(week: week, season: '2026', seasonType: seasonType);
  }

  @override
  Future<List<SleeperMatchup>> fetchMatchups(String leagueId, int week) async {
    matchupRequests++;
    await matchupGate?.future;
    if (failMatchups) throw const SleeperApiException('matchups unavailable');
    return [
      SleeperMatchup(
        rosterId: 1,
        matchupId: 1,
        points: points,
        starters: ['a'],
        playerPoints: {'a': points},
      ),
      const SleeperMatchup(
        rosterId: 2,
        matchupId: 1,
        points: 0,
        starters: ['b'],
        playerPoints: {'b': 0},
      ),
    ];
  }
}

class Alerts extends Fake implements FantasyAlertTransport {}

class Projections implements SleeperProjectionSource {
  @override
  Future<SleeperPlayerProjection?> fetchPlayerProjection({
    required String playerId,
    required String season,
    required int week,
    required String seasonType,
  }) async => SleeperPlayerProjection(
    playerId: playerId,
    season: season,
    week: week,
    seasonType: seasonType,
    team: playerId == 'a' ? 'BUF' : 'KC',
    gameId: 'game-$playerId',
    gameDate: DateTime(2026, 10, 15),
    stats: {'rush_yd': 10},
  );
}

class Baselines implements SleeperProjectionBaselineStore {
  SleeperProjectionBaselineSnapshot? snapshot;
  @override
  Future<SleeperProjectionBaselineSnapshot?> read() async => snapshot;
  @override
  Future<void> write(SleeperProjectionBaselineSnapshot value) async {
    snapshot = value;
  }
}

class Statuses implements SleeperNflGameStatusSource {
  SleeperNflGamePhase phase = SleeperNflGamePhase.upcoming;
  @override
  Future<Map<String, SleeperNflGamePhase>> statusesForDates(
    Iterable<DateTime> dates,
  ) async => {'BUF': phase, 'KC': phase};
}
