import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports_hub_mobile/college_football.dart';
import 'package:sports_hub_mobile/college_football_preferences_store.dart';
import 'package:sports_hub_mobile/device_content_preferences.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/power_four_game_filter.dart';
import 'package:sports_hub_mobile/power_four_team_catalog.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/espn_team_sports.dart';
import 'package:sports_hub_mobile/sports_game.dart';

void main() {
  group('Power 4 domain', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('NCAAF is a football sports league and device category', () {
      expect(SportsLeague.ncaaf.label, 'NCAAF');
      expect(SportsLeague.ncaaf.isFootball, isTrue);
      expect(DeviceContentCategory.ncaaf.sportsLeague, SportsLeague.ncaaf);
      expect(DeviceContentCategory.fantasy.sportsLeague, isNull);
    });

    test('all conferences default selected and persist', () async {
      final store =
          await SharedPreferencesCollegeFootballPreferencesStore.create();
      expect(store.read().conferences, NcaafConference.values.toSet());
      await store.save(
        CollegeFootballPreferences([NcaafConference.sec, NcaafConference.acc]),
      );
      final reloaded =
          await SharedPreferencesCollegeFootballPreferencesStore.create();
      expect(reloaded.read().conferences, {
        NcaafConference.sec,
        NcaafConference.acc,
      });
    });

    test('empty conference selection is rejected', () {
      expect(() => CollegeFootballPreferences(const []), throwsArgumentError);
    });

    test('catalog has exactly 67 uniquely classified teams', () {
      expect(PowerFourTeamCatalog.teams, hasLength(67));
      expect(
        PowerFourTeamCatalog.teams.map((team) => team.key).toSet(),
        hasLength(67),
      );
      expect(
        PowerFourTeamCatalog.teams.where(
          (team) => team.conference == NcaafConference.acc,
        ),
        hasLength(17),
      );
      expect(
        PowerFourTeamCatalog.teams.where(
          (team) => team.conference == NcaafConference.bigTen,
        ),
        hasLength(18),
      );
      expect(
        PowerFourTeamCatalog.teams.where(
          (team) => team.conference == NcaafConference.big12,
        ),
        hasLength(16),
      );
      expect(
        PowerFourTeamCatalog.teams.where(
          (team) => team.conference == NcaafConference.sec,
        ),
        hasLength(16),
      );
      expect(PowerFourTeamCatalog.canonicalKey('Notre Dame'), isNull);
      expect(PowerFourTeamCatalog.canonicalKey('South Carolin'), isNull);
    });

    test('ESPN NCAAF live game maps canonical teams and football state', () {
      final game = parseEspnTeamScoreboard(SportsLeague.ncaaf, {
        'events': [
          {
            'id': 'cfb-1',
            'competitions': [
              {
                'competitors': [
                  {
                    'id': '1',
                    'homeAway': 'away',
                    'score': '14',
                    'team': {'id': '1', 'abbreviation': 'SC'},
                  },
                  {
                    'id': '2',
                    'homeAway': 'home',
                    'score': '10',
                    'team': {'id': '2', 'abbreviation': 'CLEM'},
                  },
                ],
                'status': {
                  'period': 3,
                  'displayClock': '8:42',
                  'type': {'state': 'in'},
                },
                'situation': {
                  'possession': '1',
                  'down': 2,
                  'distance': 7,
                  'shortDownDistanceText': '2nd & 7',
                },
              },
            ],
          },
        ],
      }).single;
      expect(game.awayTeamKey, 'SC');
      expect(game.homeTeamKey, 'CLEM');
      expect(game.footballState?.possession, FootballPossession.away);
      expect(game.footballState?.down, 2);
    });
  });

  group('PowerFourGameFilter', () {
    const filter = PowerFourGameFilter();
    test('includes either-side selected teams and preserves source order', () {
      final source = [
        _game('sc-clem', away: 'SC', home: 'CLEM'),
        _game('osu-mich', away: 'OSU', home: 'MICH'),
        _game('unknown-sc', away: null, home: 'SC'),
        _game('nd-navy', away: null, home: null),
      ];
      final result = filter.filter(source, const [NcaafConference.sec]);
      expect(result.map((game) => game.eventId), ['sc-clem', 'unknown-sc']);
      expect(source, hasLength(4));
    });

    test('cross-conference duplicate event appears once', () {
      final source = [
        _game('rivalry', away: 'SC', home: 'CLEM'),
        _game('rivalry', away: 'SC', home: 'CLEM'),
      ];
      expect(
        filter.filter(source, const [NcaafConference.sec, NcaafConference.acc]),
        hasLength(1),
      );
    });

    test('representative Big Ten and Big 12 games qualify', () {
      expect(
        filter.filter(
          [_game('ore', away: 'ORE')],
          const [NcaafConference.bigTen],
        ),
        hasLength(1),
      );
      expect(
        filter.filter(
          [_game('utah', home: 'BYU')],
          const [NcaafConference.big12],
        ),
        hasLength(1),
      );
    });
  });
}

GameData _game(String id, {String? away, String? home}) => GameData(
  eventId: id,
  league: 'NCAAF',
  awayTeam: away ?? 'UNKNOWN A',
  homeTeam: home ?? 'UNKNOWN B',
  awayTeamKey: away,
  homeTeamKey: home,
  awayScore: 0,
  homeScore: 0,
  status: 'UPCOMING',
  clock: '1:00 PM',
);
