import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/espn_team_sports.dart';
import 'package:sports_hub_mobile/sports_league.dart';

void main() {
  test('maps MLB upcoming game and stable ESPN event identity', () {
    final game = parseEspnTeamScoreboard(
      SportsLeague.mlb,
      _scoreboard(
        id: '401-upcoming',
        status: _status('STATUS_SCHEDULED', 'pre', false, '7:10 PM'),
      ),
    ).single;

    expect(game.eventId, '401-upcoming');
    expect(game.status, 'UPCOMING');
    expect(game.awayTeam, 'BOS');
    expect(game.homeTeam, 'NYY');
    expect(game.clock, '7:10 PM');
  });

  for (final testCase in [
    (inning: 1, detail: 'Delayed, Top 1st', expected: 'Top 1st'),
    (inning: 1, detail: 'Bottom 1st', expected: 'Bot 1st'),
    (inning: 5, detail: 'Top 5th', expected: 'Top 5th'),
    (inning: 9, detail: 'Bot 9th', expected: 'Bot 9th'),
    (inning: 10, detail: 'Top 10th', expected: 'Top 10th'),
    (inning: 11, detail: 'Bottom 11th', expected: 'Bot 11th'),
    (inning: 12, detail: 'Top 12th', expected: 'Top 12th'),
    (inning: 13, detail: 'Bot 13th', expected: 'Bot 13th'),
  ]) {
    test('maps live MLB ${testCase.expected}', () {
      final game = parseEspnTeamScoreboard(
        SportsLeague.mlb,
        _scoreboard(
          status: _status('STATUS_IN_PROGRESS', 'in', false, testCase.detail),
          period: testCase.inning,
        ),
      ).single;

      expect(game.status, 'LIVE');
      expect(game.clock, testCase.expected);
    });
  }

  test('falls back to ordinal inning when MLB half is unknown', () {
    final game = parseEspnTeamScoreboard(
      SportsLeague.mlb,
      _scoreboard(
        status: _status('STATUS_IN_PROGRESS', 'in', false, 'In Progress'),
        period: 5,
      ),
    ).single;

    expect(game.status, 'LIVE');
    expect(game.clock, '5th');
  });

  for (final testCase in [
    (first: false, second: false, third: false, outs: 0),
    (first: true, second: false, third: false, outs: 1),
    (first: false, second: true, third: false, outs: 2),
    (first: false, second: false, third: true, outs: 0),
    (first: true, second: true, third: false, outs: 1),
    (first: true, second: true, third: true, outs: 2),
  ]) {
    test('maps structured MLB situation $testCase', () {
      final game = parseEspnTeamScoreboard(
        SportsLeague.mlb,
        _scoreboard(
          status: _status('STATUS_IN_PROGRESS', 'in', false, 'Top 5th'),
          period: 5,
          situation: {
            'onFirst': testCase.first,
            'onSecond': testCase.second,
            'onThird': testCase.third,
            'outs': testCase.outs,
          },
        ),
      ).single;

      expect(game.baseballState?.runnerOnFirst, testCase.first);
      expect(game.baseballState?.runnerOnSecond, testCase.second);
      expect(game.baseballState?.runnerOnThird, testCase.third);
      expect(game.baseballState?.outs, testCase.outs);
    });
  }

  test('upcoming and final MLB games omit baseball situation', () {
    final situation = {
      'onFirst': true,
      'onSecond': true,
      'onThird': true,
      'outs': 2,
    };
    final upcoming = parseEspnTeamScoreboard(
      SportsLeague.mlb,
      _scoreboard(
        status: _status('STATUS_SCHEDULED', 'pre', false, '7:10 PM'),
        situation: situation,
      ),
    ).single;
    final finalGame = parseEspnTeamScoreboard(
      SportsLeague.mlb,
      _scoreboard(
        status: _status('STATUS_FINAL', 'post', true, 'Final'),
        situation: situation,
      ),
    ).single;

    expect(upcoming.baseballState, isNull);
    expect(finalGame.baseballState, isNull);
  });

  test('non-MLB game ignores baseball situation', () {
    final game = parseEspnTeamScoreboard(
      SportsLeague.nfl,
      _scoreboard(
        status: _status('STATUS_IN_PROGRESS', 'in', false, null),
        situation: {
          'onFirst': true,
          'onSecond': true,
          'onThird': true,
          'outs': 2,
        },
      ),
    ).single;
    expect(game.baseballState, isNull);
  });

  test('maps MLB final game', () {
    final game = parseEspnTeamScoreboard(
      SportsLeague.mlb,
      _scoreboard(status: _status('STATUS_FINAL', 'post', true, 'Final')),
    ).single;

    expect(game.status, 'FINAL');
    expect(game.clock, 'Final');
    expect(game.eventId, '401-event');
    expect(game.awayScore, 3);
    expect(game.homeScore, 2);
  });

  test('accepts NFL preseason event metadata', () {
    final fixture = _scoreboard(
      id: 'preseason-event',
      status: _status('STATUS_FINAL', 'post', true, 'Final'),
    );
    (fixture['events'] as List).first['season'] = {
      'year': 2026,
      'type': 1,
      'slug': 'preseason',
    };
    (fixture['events'] as List).first['week'] = {'number': 2};

    final game = parseEspnTeamScoreboard(SportsLeague.nfl, fixture).single;
    expect(game.eventId, 'preseason-event');
    expect(game.status, 'FINAL');
  });

  test('maps live NFL quarter and clock', () {
    final game = parseEspnTeamScoreboard(
      SportsLeague.nfl,
      _scoreboard(
        status: _status('STATUS_IN_PROGRESS', 'in', false, null),
        period: 3,
        displayClock: '08:42',
      ),
    ).single;
    expect(game.status, 'LIVE');
    expect(game.clock, 'Q3 08:42');
  });

  test('maps live NBA period and clock', () {
    final game = parseEspnTeamScoreboard(
      SportsLeague.nba,
      _scoreboard(
        status: _status('STATUS_IN_PROGRESS', 'in', false, null),
        period: 4,
        displayClock: '01:05',
      ),
    ).single;
    expect(game.status, 'LIVE');
    expect(game.clock, 'Q4 01:05');
  });
}

Map<String, dynamic> _scoreboard({
  String id = '401-event',
  required Map<String, dynamic> status,
  int period = 1,
  String displayClock = '0:00',
  Map<String, dynamic>? situation,
}) => {
  'events': [
    {
      'id': id,
      'date': '2026-08-20T23:10:00Z',
      'status': {'type': status},
      'competitions': [
        {
          'date': '2026-08-20T23:10:00Z',
          'situation': ?situation,
          'status': {
            'period': period,
            'displayClock': displayClock,
            'type': status,
          },
          'competitors': [
            {
              'homeAway': 'home',
              'score': '2',
              'team': {'abbreviation': 'NYY'},
            },
            {
              'homeAway': 'away',
              'score': '3',
              'team': {'abbreviation': 'BOS'},
            },
          ],
        },
      ],
    },
  ],
};

Map<String, dynamic> _status(
  String name,
  String state,
  bool completed,
  String? detail,
) => {
  'name': name,
  'state': state,
  'completed': completed,
  'shortDetail': ?detail,
};
