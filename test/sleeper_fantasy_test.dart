import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sports_hub_mobile/sleeper_api_client.dart';
import 'package:sports_hub_mobile/sleeper_fantasy_repository.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';

void main() {
  group('Sleeper JSON parsing', () {
    test('parses league information and scoring settings', () {
      final league = SleeperLeague.fromJson({
        'league_id': 'league-1',
        'name': 'Sunday Heroes',
        'season': '2026',
        'status': 'in_season',
        'scoring_settings': {'pass_td': 4, 'rec': 0.5},
        'roster_positions': ['QB', 'RB', 'WR', 'FLEX', 'BN'],
      });

      expect(league.leagueId, 'league-1');
      expect(league.name, 'Sunday Heroes');
      expect(league.scoringSettings, {'pass_td': 4.0, 'rec': 0.5});
      expect(league.rosterPositions, contains('FLEX'));
    });

    test('parses users and rosters into owned models', () {
      final user = SleeperUser.fromJson({
        'user_id': 'user-1',
        'display_name': 'Peter',
        'metadata': {'team_name': 'SCRBRD FC'},
      });
      final roster = SleeperRoster.fromJson({
        'roster_id': 7,
        'owner_id': 'user-1',
        'players': ['p1', 'p2', 'p3'],
        'starters': ['p1', 'p2'],
      });

      expect(user.label, 'SCRBRD FC');
      expect(roster.ownerId, user.userId);
      expect(roster.starters, ['p1', 'p2']);
    });

    test('parses matchup total and per-player points', () {
      final matchup = SleeperMatchup.fromJson({
        'roster_id': 7,
        'matchup_id': 3,
        'points': 84.25,
        'starters': ['p1', 'p2'],
        'players_points': {'p1': 20.5, 'p2': 8},
      });

      expect(matchup.points, 84.25);
      expect(matchup.playerPoints, {'p1': 20.5, 'p2': 8.0});
    });

    test('falls back to positional starter points when needed', () {
      final matchup = SleeperMatchup.fromJson({
        'roster_id': 7,
        'matchup_id': 3,
        'points': 28,
        'starters': ['p1', 'p2'],
        'starters_points': [20, 8],
      });

      expect(matchup.playerPoints, {'p1': 20.0, 'p2': 8.0});
    });

    test('parses current NFL week', () {
      final state = SleeperNflState.fromJson({
        'week': 8,
        'season': '2026',
        'season_type': 'regular',
      });
      expect(state.week, 8);
      expect(state.season, '2026');
      expect(state.seasonType, 'regular');
    });

    test('preseason Weeks 2 and 3 resolve to fantasy Week 1', () {
      for (final week in [2, 3]) {
        final state = SleeperNflState.fromJson({
          'week': week,
          'season': '2026',
          'season_type': 'pre',
        });
        expect(state.fantasyWeek, 1);
      }
    });

    test('regular-season Week 2 remains fantasy Week 2', () {
      final state = SleeperNflState.fromJson({
        'week': 2,
        'season': '2026',
        'season_type': 'regular',
      });
      expect(state.fantasyWeek, 2);
    });
  });

  test('matches a selected roster to its opponent and starter points', () {
    final snapshot = _snapshot();

    final matchup = snapshot.matchupForRoster(1);

    expect(matchup.team.name, 'My Team');
    expect(matchup.opponent.name, 'Opponent Team');
    expect(matchup.team.matchup.points, 101.4);
    expect(matchup.opponent.matchup.points, 98.2);
    expect(matchup.team.starters.first.playerId, 'my-qb');
    expect(matchup.team.starters.first.points, 22.4);
    expect(matchup.opponent.starters.first.playerId, 'their-qb');
  });

  test('reports a roster without a paired opponent', () {
    final base = _snapshot();
    final snapshot = SleeperLeagueSnapshot(
      league: base.league,
      week: base.week,
      users: base.users,
      rosters: base.rosters,
      matchups: [base.matchups.first],
    );

    expect(
      () => snapshot.matchupForRoster(1),
      throwsA(isA<SleeperFantasyException>()),
    );
  });

  test('API client requests current week matchup resources', () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      final body = switch (request.url.path) {
        '/v1/league/league-1' => {
          'league_id': 'league-1',
          'name': 'League',
          'season': '2026',
          'status': 'in_season',
          'scoring_settings': <String, dynamic>{},
          'roster_positions': <String>[],
        },
        '/v1/league/league-1/users' => <Object>[],
        '/v1/league/league-1/rosters' => <Object>[],
        '/v1/state/nfl' => {'week': 6, 'season': '2026'},
        '/v1/league/league-1/matchups/6' => <Object>[],
        _ => throw StateError('Unexpected URL: ${request.url}'),
      };
      return http.Response(jsonEncode(body), 200);
    });
    final apiClient = SleeperApiClient(client: client);
    final repository = SleeperFantasyRepository(apiClient);

    final result = await repository.loadLeague('league-1');

    expect(result.week, 6);
    expect(paths, contains('/v1/league/league-1/matchups/6'));
  });

  test('ordinary refresh requests only current-week matchups', () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      final body = switch (request.url.path) {
        '/v1/league/league-1' => {
          'league_id': 'league-1',
          'name': 'League',
          'scoring_settings': <String, dynamic>{},
        },
        '/v1/league/league-1/users' => <Object>[],
        '/v1/league/league-1/rosters' => <Object>[],
        '/v1/state/nfl' => {'week': 6, 'season': '2026'},
        '/v1/league/league-1/matchups/6' => <Object>[],
        _ => throw StateError('Unexpected URL: ${request.url}'),
      };
      return http.Response(jsonEncode(body), 200);
    });
    final repository = SleeperFantasyRepository(
      SleeperApiClient(client: client),
    );
    await repository.loadLeague('league-1');
    paths.clear();

    await repository.refreshMatchups('league-1');

    expect(paths, ['/v1/league/league-1/matchups/6']);
  });

  test('load and refresh share preseason fantasy Week 1 resolution', () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      final body = switch (request.url.path) {
        '/v1/league/league-1' => {
          'league_id': 'league-1',
          'name': 'League',
          'status': 'in_season',
          'scoring_settings': <String, dynamic>{},
        },
        '/v1/league/league-1/users' => <Object>[],
        '/v1/league/league-1/rosters' => <Object>[],
        '/v1/state/nfl' => {'week': 2, 'season': '2026', 'season_type': 'pre'},
        '/v1/league/league-1/matchups/1' => <Object>[],
        _ => throw StateError('Unexpected URL: ${request.url}'),
      };
      return http.Response(jsonEncode(body), 200);
    });
    final repository = SleeperFantasyRepository(
      SleeperApiClient(client: client),
      weekRefreshInterval: Duration.zero,
    );

    final loaded = await repository.loadLeague('league-1');
    final refreshed = await repository.refreshMatchups('league-1');

    expect(loaded.week, 1);
    expect(refreshed.week, 1);
    expect(paths.where((path) => path.endsWith('/matchups/1')), hasLength(2));
    expect(paths, isNot(contains('/v1/league/league-1/matchups/2')));
  });
}

SleeperLeagueSnapshot _snapshot() => SleeperLeagueSnapshot(
  league: const SleeperLeague(
    leagueId: 'league-1',
    name: 'Sunday Heroes',
    season: '2026',
    status: 'in_season',
    scoringSettings: {},
    rosterPositions: [],
  ),
  week: 8,
  users: const [
    SleeperUser(userId: 'me', displayName: 'Peter', teamName: 'My Team'),
    SleeperUser(userId: 'them', displayName: 'Alex', teamName: 'Opponent Team'),
  ],
  rosters: const [
    SleeperRoster(
      rosterId: 1,
      ownerId: 'me',
      players: ['my-qb'],
      starters: ['my-qb'],
    ),
    SleeperRoster(
      rosterId: 2,
      ownerId: 'them',
      players: ['their-qb'],
      starters: ['their-qb'],
    ),
  ],
  matchups: const [
    SleeperMatchup(
      rosterId: 1,
      matchupId: 9,
      points: 101.4,
      starters: ['my-qb'],
      playerPoints: {'my-qb': 22.4},
    ),
    SleeperMatchup(
      rosterId: 2,
      matchupId: 9,
      points: 98.2,
      starters: ['their-qb'],
      playerPoints: {'their-qb': 18.2},
    ),
  ],
);
