import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports_hub_mobile/espn_team_sports.dart';
import 'package:sports_hub_mobile/favorite_game_prioritizer.dart';
import 'package:sports_hub_mobile/favorites_store.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/sports_data_io_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/team_catalog.dart';

void main() {
  group('canonical team identity', () {
    test('ESPN representation resolves to canonical identity', () {
      final games = parseEspnTeamScoreboard(
        SportsLeague.nfl,
        _espnGame('CAR', 'NO'),
      );
      expect(games.single.awayTeamKey, 'CAR');
      expect(games.single.homeTeamKey, 'NO');
    });

    test('SportsDataIO representation resolves to canonical identity', () {
      final game = SportsDataIOGame.fromJson(SportsLeague.mlb, {
        'AwayTeam': 'BOS',
        'HomeTeam': 'NYY',
        'Status': 'Scheduled',
      }).toSportsGame(SportsLeague.mlb);
      expect(game.awayTeamKey, 'BOS');
      expect(game.homeTeamKey, 'NYY');
    });

    test('known aliases are exact and deterministic', () {
      expect(TeamCatalog.canonicalKey(SportsLeague.nfl, 'JAC'), 'JAX');
      expect(TeamCatalog.canonicalKey(SportsLeague.mlb, 'CHW'), 'CWS');
      expect(
        TeamCatalog.canonicalKey(SportsLeague.mlb, 'Oakland Athletics'),
        'ATH',
      );
    });

    test('unknown team text is not fuzzy matched', () {
      expect(
        TeamCatalog.canonicalKey(SportsLeague.nfl, 'Carolina Panther'),
        isNull,
      );
      expect(
        TeamCatalog.canonicalKey(SportsLeague.mlb, 'Bostn Red Sox'),
        isNull,
      );
    });
  });

  group('favorites persistence', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('favorite persists and reloads', () async {
      final car = TeamCatalog.forLeague(
        SportsLeague.nfl,
      ).firstWhere((team) => team.key == 'CAR');
      final store = await SharedPreferencesFavoritesStore.create();
      await store.setFavorite(car, true);
      final reloaded = await SharedPreferencesFavoritesStore.create();
      expect(reloaded.isFavorite(SportsLeague.nfl, 'CAR'), isTrue);
    });

    test('favorite removal persists', () async {
      final bos = TeamCatalog.forLeague(
        SportsLeague.mlb,
      ).firstWhere((team) => team.key == 'BOS');
      final store = await SharedPreferencesFavoritesStore.create();
      await store.setFavorite(bos, true);
      await store.setFavorite(bos, false);
      final reloaded = await SharedPreferencesFavoritesStore.create();
      expect(reloaded.readFavorites(), isEmpty);
    });
  });

  group('stable game priority', () {
    final car = TeamCatalog.forLeague(
      SportsLeague.nfl,
    ).firstWhere((team) => team.key == 'CAR');
    final no = TeamCatalog.forLeague(
      SportsLeague.nfl,
    ).firstWhere((team) => team.key == 'NO');
    const prioritizer = FavoriteGamePrioritizer();

    test('no favorites returns unchanged copy', () {
      final games = [_game('A'), _game('B')];
      final result = prioritizer.prioritize(SportsLeague.nfl, games, const []);
      expect(result.map((game) => game.eventId), ['A', 'B']);
      expect(identical(result, games), isFalse);
    });

    test('away and home favorites move first with stable partitions', () {
      final games = [
        _game('A'),
        _game('B', away: 'CAR'),
        _game('C'),
        _game('D', home: 'NO'),
        _game('E'),
      ];
      final result = prioritizer.prioritize(SportsLeague.nfl, games, [car, no]);
      expect(result.map((game) => game.eventId), ['B', 'D', 'A', 'C', 'E']);
      expect(result.toSet(), games.toSet());
      expect(result, hasLength(games.length));
      expect(games.map((game) => game.eventId), ['A', 'B', 'C', 'D', 'E']);
    });
  });
}

GameData _game(String id, {String? away, String? home}) => GameData(
  eventId: id,
  league: 'NFL',
  awayTeam: away ?? 'A',
  homeTeam: home ?? 'H',
  awayTeamKey: away,
  homeTeamKey: home,
  awayScore: 0,
  homeScore: 0,
  status: 'UPCOMING',
  clock: '1:00 PM',
);

Map<String, dynamic> _espnGame(String away, String home) => {
  'events': [
    {
      'id': '1',
      'competitions': [
        {
          'competitors': [
            {
              'homeAway': 'away',
              'score': '0',
              'team': {'abbreviation': away},
            },
            {
              'homeAway': 'home',
              'score': '0',
              'team': {'abbreviation': home},
            },
          ],
          'status': {
            'type': {'state': 'pre', 'shortDetail': '1:00 PM'},
          },
        },
      ],
    },
  ],
};
