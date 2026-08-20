import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sports_hub_mobile/espn_data_source.dart';
import 'package:sports_hub_mobile/sports_data_provider.dart';
import 'package:sports_hub_mobile/sports_league.dart';

void main() {
  test('provider selection defaults to SportsDataIO', () {
    expect(selectSportsDataProvider(''), SportsDataProvider.sportsDataIO);
    expect(
      selectSportsDataProvider('unknown'),
      SportsDataProvider.sportsDataIO,
    );
  });

  test('provider selection accepts ESPN case-insensitively', () {
    expect(selectSportsDataProvider(' ESPN '), SportsDataProvider.espn);
  });

  test(
    'ESPN team request uses selected date and requires no API key',
    () async {
      late http.Request request;
      final source = EspnDataSource(
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(jsonEncode({'events': []}), 200);
        }),
      );

      expect(
        await source.fetchGamesForDate(SportsLeague.nfl, DateTime(2026, 8, 10)),
        isEmpty,
      );
      expect(request.url.queryParameters['dates'], '20260810');
      expect(request.url.path, contains('/football/nfl/scoreboard'));
      expect(request.headers, isNot(contains('Ocp-Apim-Subscription-Key')));
    },
  );

  test('PGA refresh reuses tournament event ID', () async {
    final requests = <http.Request>[];
    final source = EspnDataSource(
      client: MockClient((incoming) async {
        requests.add(incoming);
        return http.Response(jsonEncode(_emptyTournament), 200);
      }),
    );
    await source.fetchGolfLeaderboardForDate(DateTime(2026, 8, 20));
    final leaderboard = await source.fetchGolfLeaderboardByTournamentId('401');
    expect(requests, hasLength(2));
    expect(requests.last.url.queryParameters['dates'], '20260820');
    expect(leaderboard.tournamentId, '401');
  });

  test(
    'PGA refresh cannot silently switch an undiscovered tournament',
    () async {
      final source = EspnDataSource(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await expectLater(
        source.fetchGolfLeaderboardByTournamentId('unknown'),
        throwsA(isA<EspnDataException>()),
      );
    },
  );
}

final _emptyTournament = {
  'events': [
    {
      'id': '401',
      'name': 'Test Open',
      'date': '2026-08-20T04:00:00Z',
      'endDate': '2026-08-23T04:00:00Z',
      'status': {
        'type': {'state': 'pre', 'completed': false},
      },
      'competitions': [
        {
          'status': {'period': 1},
          'competitors': <Object>[],
        },
      ],
    },
  ],
};
