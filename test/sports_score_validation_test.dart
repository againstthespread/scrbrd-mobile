import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/espn_data_source.dart';
import 'package:sports_hub_mobile/espn_team_sports.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/live_refresh_coordinator.dart';
import 'package:sports_hub_mobile/sports_data_io_data_source.dart';
import 'package:sports_hub_mobile/sports_data_io_game.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';
import 'package:sports_hub_mobile/sports_score_validation.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

const leagues = [
  SportsLeague.nfl,
  SportsLeague.ncaaf,
  SportsLeague.nba,
  SportsLeague.mlb,
];

void main() {
  for (final league in leagues) {
    for (final status in ['LIVE', 'FINAL']) {
      for (final invalid in [
        null,
        '',
        'N/A',
        -1,
        '-1',
        1.5,
        '1.5',
        true,
        <String, Object>{},
      ]) {
        test('ESPN $league $status rejects score=$invalid', () {
          expect(
            () => parseEspnTeamScoreboard(league, {
              'events': [espnEvent('A', status, invalid, 7)],
            }),
            throwsA(isA<SportsScoreValidationException>()),
          );
        });
        test('SportsDataIO $league $status rejects score=$invalid', () {
          expect(
            () => SportsDataIOGame.fromJson(
              league,
              sdioGame(league, 'A', status, 7, invalid),
            ),
            throwsA(isA<SportsScoreValidationException>()),
          );
        });
      }
    }
    for (final status in ['LIVE', 'FINAL', 'UPCOMING']) {
      test('both providers preserve legitimate zeros $league $status', () {
        final espn = parseEspnTeamScoreboard(league, {
          'events': [espnEvent('A', status, 0, '0')],
        }).single;
        final sdio = SportsDataIOGame.fromJson(
          league,
          sdioGame(league, 'A', status, 0.0, '0'),
        );
        expect((espn.awayScore, espn.homeScore), (0, 0));
        expect((sdio.awayScore, sdio.homeScore), (0, 0));
      });
    }
    test('both providers allow absent scheduled scores $league', () {
      final espn = parseEspnTeamScoreboard(league, {
        'events': [espnEvent('A', 'UPCOMING', null, null)],
      }).single;
      final sdio = SportsDataIOGame.fromJson(
        league,
        sdioGame(league, 'A', 'UPCOMING', null, null),
      );
      expect((espn.awayScore, espn.homeScore), (0, 0));
      expect((sdio.awayScore, sdio.homeScore), (0, 0));
    });
  }
  for (final provider in ['ESPN', 'SportsDataIO']) {
    for (final status in ['LIVE', 'FINAL']) {
      test(
        '$provider incomplete $status slate never overwrites baseline; correction recovers',
        () async {
          var away = <Object?>[14, 7];
          var home = <Object?>[10, 3];
          final client = MockClient(
            (_) async => http.Response(
              jsonEncode(
                provider == 'ESPN'
                    ? {
                        'events': [
                          for (var i = 0; i < 2; i++)
                            espnEvent('$i', status, away[i], home[i]),
                        ],
                      }
                    : [
                        for (var i = 0; i < 2; i++)
                          sdioGame(
                            SportsLeague.nfl,
                            '$i',
                            status,
                            away[i],
                            home[i],
                          ),
                      ],
              ),
              200,
            ),
          );
          final SportsDataSource source = provider == 'ESPN'
              ? EspnDataSource(client: client)
              : SportsDataIODataSource(client: client, apiKey: 'test');
          final repository = SportsRepository(source);
          final baseline = await repository.fetchGamesForDate(
            SportsLeague.nfl,
            DateTime(2026, 10, 15),
          );
          final session = TrackedDeviceSession()
            ..recordTeamSlate(
              league: SportsLeague.nfl,
              selectedDate: DateTime(2026, 10, 15),
              games: baseline,
            );
          final transport = Transport();
          final coordinator = LiveRefreshCoordinator(
            repository: repository,
            transport: transport,
            session: session,
            isBleConnected: () => true,
          );
          // A valid peer update must not make an incomplete slate authoritative.
          away = [21, null];
          home = [10, 3];
          for (var i = 0; i < 3; i++) {
            await coordinator.refreshTrackedSessionOnce();
          }
          expect(transport.slates, isEmpty);
          expect(
            (session[SportsLeague.nfl] as TrackedTeamSlate).games.map(
              (g) => g.awayScore,
            ),
            [14, 7],
          );
          // Do not impose monotonic scores: a valid correction down to zero is real.
          away = [0, 6];
          home = [9, 3];
          await coordinator.refreshTrackedSessionOnce();
          expect(transport.slates, hasLength(1));
          expect(transport.slates.single.map((g) => g.eventId), ['0', '1']);
          expect(transport.slates.single.map((g) => g.awayScore), [0, 6]);
          expect(transport.slates.single.first.homeScore, 9);
          await coordinator.refreshTrackedSessionOnce();
          expect(transport.slates, hasLength(1));
        },
      );
    }
  }
  for (final invalid in [
    double.nan,
    double.infinity,
    double.negativeInfinity,
    1e30,
    '0x10',
  ]) {
    test(
      'both providers reject non-finite, overflowing, or non-decimal scores $invalid',
      () {
        expect(
          () => parseEspnTeamScoreboard(SportsLeague.nfl, {
            'events': [espnEvent('A', 'LIVE', 7, invalid)],
          }),
          throwsA(isA<SportsScoreValidationException>()),
        );
        expect(
          () => SportsDataIOGame.fromJson(
            SportsLeague.nfl,
            sdioGame(SportsLeague.nfl, 'A', 'LIVE', invalid, 7),
          ),
          throwsA(isA<SportsScoreValidationException>()),
        );
      },
    );
  }
  test('unknown status is not evidence that a missing score means zero', () {
    final espn = espnEvent('A', 'UPCOMING', null, null);
    (espn['competitions'] as List).first['status'] = <String, dynamic>{};
    expect(
      () => parseEspnTeamScoreboard(SportsLeague.nfl, {
        'events': [espn],
      }),
      throwsA(isA<SportsScoreValidationException>()),
    );
    final sdio = sdioGame(SportsLeague.nfl, 'A', 'UPCOMING', null, null)
      ..remove('Status');
    expect(
      () => SportsDataIOGame.fromJson(SportsLeague.nfl, sdio),
      throwsA(isA<SportsScoreValidationException>()),
    );
  });
  test(
    'suspended or delayed SportsDataIO games are not necessarily unstarted',
    () {
      for (final status in ['Suspended', 'Delayed']) {
        final game = sdioGame(SportsLeague.nfl, 'A', 'LIVE', null, null)
          ..['Status'] = status;
        expect(
          () => SportsDataIOGame.fromJson(SportsLeague.nfl, game),
          throwsA(isA<SportsScoreValidationException>()),
        );
      }
    },
  );
  test('absent score keys are allowed only for scheduled events', () {
    for (final status in ['UPCOMING', 'LIVE', 'FINAL']) {
      final espn = espnEvent('A', status, null, null);
      for (final team in (espn['competitions'] as List).first['competitors']) {
        team.remove('score');
      }
      final sdio = sdioGame(SportsLeague.nfl, 'A', status, null, null)
        ..remove('AwayScore')
        ..remove('HomeScore');
      if (status == 'UPCOMING') {
        expect(
          parseEspnTeamScoreboard(SportsLeague.nfl, {
            'events': [espn],
          }).single.awayScore,
          0,
        );
        expect(SportsDataIOGame.fromJson(SportsLeague.nfl, sdio).homeScore, 0);
      } else {
        expect(
          () => parseEspnTeamScoreboard(SportsLeague.nfl, {
            'events': [espn],
          }),
          throwsA(isA<SportsScoreValidationException>()),
        );
        expect(
          () => SportsDataIOGame.fromJson(SportsLeague.nfl, sdio),
          throwsA(isA<SportsScoreValidationException>()),
        );
      }
    }
  });
  test('integral numbers and trimmed decimal strings remain valid', () {
    final espn = parseEspnTeamScoreboard(SportsLeague.nfl, {
      'events': [espnEvent('A', 'LIVE', 7.0, ' 14 ')],
    }).single;
    final sdio = SportsDataIOGame.fromJson(
      SportsLeague.nfl,
      sdioGame(SportsLeague.nfl, 'A', 'FINAL', 7.0, ' 14 '),
    );
    expect((espn.awayScore, espn.homeScore), (7, 14));
    expect((sdio.awayScore, sdio.homeScore), (7, 14));
  });
}

Map<String, dynamic> espnEvent(
  String id,
  String status,
  Object? away,
  Object? home,
) => {
  'id': id,
  'competitions': [
    {
      'status': {
        'type': {
          'state': switch (status) {
            'LIVE' => 'in',
            'FINAL' => 'post',
            _ => 'pre',
          },
          'completed': status == 'FINAL',
        },
      },
      'competitors': [
        {
          'homeAway': 'away',
          'score': away,
          'team': {'abbreviation': 'BUF'},
        },
        {
          'homeAway': 'home',
          'score': home,
          'team': {'abbreviation': 'NE'},
        },
      ],
    },
  ],
};

Map<String, dynamic> sdioGame(
  SportsLeague league,
  String id,
  String status,
  Object? away,
  Object? home,
) {
  final fields = switch (league) {
    SportsLeague.nfl => ('AwayScore', 'HomeScore'),
    SportsLeague.nba ||
    SportsLeague.ncaaf => ('AwayTeamScore', 'HomeTeamScore'),
    SportsLeague.mlb => ('AwayTeamRuns', 'HomeTeamRuns'),
    _ => throw StateError('not a team sport'),
  };
  return {
    'GameID': id,
    'AwayTeam': 'BUF',
    'HomeTeam': 'NE',
    'Status': switch (status) {
      'LIVE' => 'InProgress',
      'FINAL' => 'Final',
      _ => 'Scheduled',
    },
    fields.$1: away,
    fields.$2: home,
  };
}

class Transport extends Fake implements DeviceTransport {
  final slates = <List<GameData>>[];
  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    slates.add(games);
  }
}
