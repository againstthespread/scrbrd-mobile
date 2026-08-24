import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/sports_data_io_data_source.dart';
import 'package:sports_hub_mobile/sports_data_io_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('SportsDataIO NCAAF uses verified CFB GamesByDate endpoint', () {
    expect(
      SportsDataIODataSource().endpointPathForTesting(
        SportsLeague.ncaaf,
        DateTime(2026, 9, 12),
      ),
      '/v3/cfb/scores/json/GamesByDate/2026-09-12',
    );
  });

  test('SportsDataIO NCAAF normalizes teams and live football state', () {
    final game = SportsDataIOGame.fromJson(SportsLeague.ncaaf, {
      'AwayTeam': 'SCAR',
      'HomeTeam': 'CLEM',
      'AwayTeamScore': 14,
      'HomeTeamScore': 10,
      'Status': 'InProgress',
      'Quarter': 3,
      'TimeRemaining': '08:42',
      'Possession': 'SCAR',
      'Down': 2,
      'Distance': 7,
      'IsGoalToGo': false,
      'GameID': 123,
    }).toSportsGame(SportsLeague.ncaaf);
    expect(game.awayTeamKey, 'SC');
    expect(game.homeTeamKey, 'CLEM');
    expect(game.footballState?.possession, FootballPossession.away);
    expect(game.footballState?.down, 2);
    expect(game.footballState?.distance, 7);
  });

  test(
    'CFB authorization failure is a provider failure, not an empty slate',
    () async {
      var requests = 0;
      final source = SportsDataIODataSource(
        apiKey: 'test-key',
        client: MockClient((request) async {
          requests++;
          return http.Response('not entitled', 403);
        }),
      );
      await expectLater(
        source.fetchGamesForDate(SportsLeague.ncaaf, DateTime(2026, 9, 12)),
        throwsA(
          isA<SportsDataException>().having(
            (error) => error.message,
            'message',
            contains('College Football provider access is unavailable'),
          ),
        ),
      );
      expect(requests, 1);
    },
  );
}
