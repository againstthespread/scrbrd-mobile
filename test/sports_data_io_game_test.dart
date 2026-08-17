import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/sports_data_io_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';

void main() {
  group('SportsDataIOGame score mapping', () {
    test('maps NFL final scores from AwayScore and HomeScore', () {
      final game = SportsDataIOGame.fromJson(SportsLeague.nfl, {
        'AwayTeam': 'BUF',
        'HomeTeam': 'NE',
        'AwayScore': 17,
        'HomeScore': 24,
        'Status': 'Final',
        'Quarter': 'F',
      });

      expect(game.awayScore, 17);
      expect(game.homeScore, 24);
      expect(game.status, 'FINAL');
    });

    test('maps NBA live scores from AwayTeamScore and HomeTeamScore', () {
      final game = SportsDataIOGame.fromJson(SportsLeague.nba, {
        'AwayTeam': 'BOS',
        'HomeTeam': 'NY',
        'AwayTeamScore': '88',
        'HomeTeamScore': '91',
        'AwayScore': 22,
        'HomeScore': 19,
        'Status': 'InProgress',
        'Quarter': 4,
        'TimeRemaining': '5:12',
      });

      expect(game.awayScore, 88);
      expect(game.homeScore, 91);
      expect(game.clock, 'Q4 5:12');
      expect(game.status, 'LIVE');
    });

    test('maps MLB final runs from AwayTeamRuns and HomeTeamRuns', () {
      final game = SportsDataIOGame.fromJson(SportsLeague.mlb, {
        'AwayTeam': 'NYY',
        'HomeTeam': 'BOS',
        'AwayTeamRuns': 5.0,
        'HomeTeamRuns': 3.0,
        'AwayTeamScore': 99,
        'HomeTeamScore': 98,
        'Status': 'Final',
        'Inning': 9,
        'InningHalf': 'B',
      });

      expect(game.awayScore, 5);
      expect(game.homeScore, 3);
      expect(game.status, 'FINAL');
    });

    test('preserves a legitimate zero score', () {
      final game = SportsDataIOGame.fromJson(SportsLeague.nfl, {
        'AwayTeam': 'DAL',
        'HomeTeam': 'PHI',
        'AwayScore': 0,
        'HomeScore': 14,
        'Status': 'InProgress',
        'Quarter': 2,
        'TimeRemaining': '10:00',
      });

      expect(game.awayScore, 0);
      expect(game.homeScore, 14);
    });

    test('maps null upcoming scores to zero', () {
      final game = SportsDataIOGame.fromJson(SportsLeague.nba, {
        'AwayTeam': 'LAL',
        'HomeTeam': 'GS',
        'AwayTeamScore': null,
        'HomeTeamScore': null,
        'Status': 'Scheduled',
        'DateTime': '2026-08-03T19:30:00',
      });

      expect(game.awayScore, 0);
      expect(game.homeScore, 0);
      expect(game.status, 'UPCOMING');
    });

    test('does not reverse home and away values', () {
      final game = SportsDataIOGame.fromJson(SportsLeague.mlb, {
        'AwayTeam': 'SEA',
        'HomeTeam': 'HOU',
        'AwayTeamRuns': '1',
        'HomeTeamRuns': '8',
        'Status': 'Final',
      });

      expect(game.awayTeam, 'SEA');
      expect(game.homeTeam, 'HOU');
      expect(game.awayScore, 1);
      expect(game.homeScore, 8);
    });

    test('maps a stable SportsDataIO event identifier', () {
      final game = SportsDataIOGame.fromJson(SportsLeague.nfl, {
        'GlobalGameID': 18452,
        'AwayTeam': 'BUF',
        'HomeTeam': 'NE',
        'AwayScore': 0,
        'HomeScore': 0,
        'Status': 'Scheduled',
      });

      expect(game.eventId, '18452');
    });
  });
}
