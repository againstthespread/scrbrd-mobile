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

  test('maps live extra-innings MLB detail', () {
    final game = parseEspnTeamScoreboard(
      SportsLeague.mlb,
      _scoreboard(
        status: _status('STATUS_IN_PROGRESS', 'in', false, 'Top 10th'),
        period: 10,
      ),
    ).single;

    expect(game.status, 'LIVE');
    expect(game.clock, 'Top 10th');
  });

  test('maps MLB final game', () {
    final game = parseEspnTeamScoreboard(
      SportsLeague.mlb,
      _scoreboard(status: _status('STATUS_FINAL', 'post', true, 'Final')),
    ).single;

    expect(game.status, 'FINAL');
    expect(game.clock, 'Final');
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
}) => {
  'events': [
    {
      'id': id,
      'date': '2026-08-20T23:10:00Z',
      'status': {'type': status},
      'competitions': [
        {
          'date': '2026-08-20T23:10:00Z',
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
