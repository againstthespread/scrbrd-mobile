import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sports_hub_mobile/espn_fantasy_play_parser.dart';
import 'package:sports_hub_mobile/espn_nfl_play_repository.dart';
import 'package:sports_hub_mobile/fantasy_nfl_play.dart';
import 'package:sports_hub_mobile/fantasy_nfl_play_tracker.dart';

void main() {
  group('ESPN NFL play parsing', () {
    test('parses stable play and game identity with core fields', () {
      final play = parseEspnFantasyNflPlays(
        'game-1',
        _summary([
          _play(
            id: 'play-1',
            type: 'Pass Reception',
            text: 'J. Burrow pass complete to J. Chase for 50 yards.',
            yards: 50,
            scoring: true,
          ),
        ]),
      ).single;

      expect(play.playId, 'play-1');
      expect(play.gameId, 'game-1');
      expect(play.description, contains('J. Chase'));
      expect(play.yards, 50);
      expect(play.isScoringPlay, isTrue);
      expect(play.quarter, 3);
      expect(play.gameClock, '08:14');
      expect(play.possessionTeam, 'CIN');
      expect(play.usesFallbackIdentity, isFalse);
    });

    test('parses structured athlete identity, role, and team', () {
      final raw = _play(id: 'p', type: 'Rush', text: 'J. Taylor rushes.');
      raw['participants'] = [
        {
          'type': 'rusher',
          'athlete': {
            'id': '4242335',
            'displayName': 'Jonathan Taylor',
            'team': {'abbreviation': 'IND'},
          },
        },
      ];
      final participant = parseEspnFantasyNflPlays(
        'game-1',
        _summary([raw]),
      ).single.participants.single;

      expect(participant.espnAthleteId, '4242335');
      expect(participant.displayName, 'Jonathan Taylor');
      expect(participant.role, 'rusher');
      expect(participant.team, 'IND');
    });

    test('missing athlete ID remains null', () {
      final raw = _play(id: 'p', type: 'Rush', text: 'Unknown rusher.');
      raw['participants'] = [
        {
          'type': 'rusher',
          'athlete': {'displayName': 'Unknown Player'},
        },
      ];
      final participant = parseEspnFantasyNflPlays(
        'game-1',
        _summary([raw]),
      ).single.participants.single;
      expect(participant.espnAthleteId, isNull);
    });

    test('sequence and deterministic hash provide defensive fallback IDs', () {
      final sequencePlay = _play(id: null, type: 'Rush', text: 'Rush.');
      sequencePlay['sequenceNumber'] = '12300';
      final hashPlay = _play(id: null, type: 'Timeout', text: 'Timeout.');
      final first = parseEspnFantasyNflPlays(
        'game-1',
        _summary([sequencePlay, hashPlay]),
      );
      final second = parseEspnFantasyNflPlays(
        'game-1',
        _summary([sequencePlay, hashPlay]),
      );
      expect(first.first.playId, 'sequence-12300');
      expect(first.last.playId, startsWith('fallback-'));
      expect(first.last.playId, second.last.playId);
    });

    test('malformed play does not crash the remaining ingestion', () {
      final plays = parseEspnFantasyNflPlays(
        'game-1',
        _summary([
          {'id': 'bad'},
          _play(id: 'good', type: 'Rush', text: 'Valid rush.'),
        ]),
      );
      expect(plays.map((play) => play.playId), ['good']);
    });
  });

  final classifications = <String, FantasyNflPlayType>{
    'Pass Incompletion': FantasyNflPlayType.pass,
    'Pass Reception': FantasyNflPlayType.reception,
    'Rush': FantasyNflPlayType.rush,
    'Passing Touchdown': FantasyNflPlayType.touchdown,
    'Pass Interception Return': FantasyNflPlayType.interception,
    'Fumble Recovery (Opponent)': FantasyNflPlayType.fumble,
    'Field Goal Good': FantasyNflPlayType.fieldGoal,
    'Extra Point Good': FantasyNflPlayType.extraPoint,
    'Two-Point Conversion': FantasyNflPlayType.twoPointConversion,
    'Sack': FantasyNflPlayType.sack,
    'Safety': FantasyNflPlayType.safety,
    'Punt': FantasyNflPlayType.punt,
    'Kickoff': FantasyNflPlayType.kickoff,
    'Penalty': FantasyNflPlayType.penalty,
    'End Period': FantasyNflPlayType.other,
  };
  for (final entry in classifications.entries) {
    test('classifies ${entry.key}', () {
      expect(classifyEspnFantasyNflPlay(entry.key), entry.value);
    });
  }

  group('new-play tracking', () {
    test('first observation establishes a zero-event baseline', () {
      final tracker = FantasyNflPlayTracker();
      expect(
        tracker.observe('g1', [_typedPlay('a'), _typedPlay('b')]),
        isEmpty,
      );
    });

    test('subsequent plays emit once in source order', () {
      final tracker = FantasyNflPlayTracker();
      tracker.observe('g1', [_typedPlay('a')]);
      final fresh = tracker.observe('g1', [
        _typedPlay('a'),
        _typedPlay('b'),
        _typedPlay('c'),
      ]);
      expect(fresh.map((play) => play.playId), ['b', 'c']);
      expect(
        tracker.observe('g1', [
          _typedPlay('a'),
          _typedPlay('b'),
          _typedPlay('c'),
        ]),
        isEmpty,
      );
    });

    test('revised text under the same play ID is not new', () {
      final tracker = FantasyNflPlayTracker();
      tracker.observe('g1', [_typedPlay('a', description: 'Original')]);
      expect(
        tracker.observe('g1', [_typedPlay('a', description: 'Revised')]),
        isEmpty,
      );
    });

    test('simultaneous games retain independent baselines', () {
      final tracker = FantasyNflPlayTracker();
      tracker.observe('g1', [_typedPlay('a', gameId: 'g1')]);
      tracker.observe('g2', [_typedPlay('a', gameId: 'g2')]);
      expect(
        tracker
            .observe('g1', [
              _typedPlay('a', gameId: 'g1'),
              _typedPlay('b', gameId: 'g1'),
            ])
            .single
            .gameId,
        'g1',
      );
      expect(tracker.observe('g2', [_typedPlay('a', gameId: 'g2')]), isEmpty);
    });

    test('newly discovered game baselines historical plays', () {
      final tracker = FantasyNflPlayTracker();
      tracker.observe('g1', [_typedPlay('a')]);
      expect(
        tracker.observe(
          'g2',
          List.generate(80, (index) => _typedPlay('$index')),
        ),
        isEmpty,
      );
    });
  });

  group('repository refresh', () {
    test('one summary failure does not block another game', () async {
      var refresh = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/scoreboard')) {
          refresh++;
          return _jsonResponse(_scoreboard(['g1', 'g2']));
        }
        final game = request.url.queryParameters['event'];
        if (refresh == 2 && game == 'g1') return http.Response('error', 500);
        final ids = refresh == 1 ? ['a'] : ['a', 'b'];
        return _jsonResponse(
          _summary(
            ids
                .map((id) => _play(id: id, type: 'Rush', text: '$game $id'))
                .toList(),
          ),
        );
      });
      final repository = EspnNflPlayRepository(client: client);

      expect(await repository.refresh(DateTime(2026, 8, 22)), isEmpty);
      final fresh = await repository.refresh(DateTime(2026, 8, 22));

      expect(fresh, hasLength(1));
      expect(fresh.single.gameId, 'g2');
      expect(fresh.single.playId, 'b');
    });

    test(
      'completed game gets one final observation then stops fetching',
      () async {
        var state = 'in';
        var summaryRequests = 0;
        var playCount = 1;
        final client = MockClient((request) async {
          if (request.url.path.endsWith('/scoreboard')) {
            return _jsonResponse(_scoreboard(['g1'], state: state));
          }
          summaryRequests++;
          return _jsonResponse(
            _summary(
              List.generate(
                playCount,
                (index) =>
                    _play(id: '$index', type: 'Rush', text: 'Play $index'),
              ),
            ),
          );
        });
        final repository = EspnNflPlayRepository(client: client);
        await repository.refresh(DateTime(2026, 8, 22));
        state = 'post';
        playCount = 2;
        expect(await repository.refresh(DateTime(2026, 8, 22)), hasLength(1));
        expect(await repository.refresh(DateTime(2026, 8, 22)), isEmpty);
        expect(summaryRequests, 2);
      },
    );

    test('already-completed newly discovered game is not fetched', () async {
      var summaryRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/scoreboard')) {
          return _jsonResponse(_scoreboard(['g1'], state: 'post'));
        }
        summaryRequests++;
        return _jsonResponse(_summary([]));
      });
      final repository = EspnNflPlayRepository(client: client);
      expect(await repository.refresh(DateTime(2026, 8, 22)), isEmpty);
      expect(summaryRequests, 0);
    });
  });

  test(
    'play ingestion has no fantasy scoring, Sleeper, BLE, or timer coupling',
    () {
      final sources = [
        'lib/fantasy_nfl_play.dart',
        'lib/fantasy_nfl_play_tracker.dart',
        'lib/espn_fantasy_play_parser.dart',
        'lib/espn_nfl_play_repository.dart',
      ].map((path) => File(path).readAsStringSync().toLowerCase()).join();
      expect(sources, isNot(contains('scoring_settings')));
      expect(sources, isNot(contains('fantasypointdelta')));
      expect(sources, isNot(contains('sleeper')));
      expect(sources, isNot(contains('bluetooth')));
      expect(sources, isNot(contains('device_transport')));
      expect(sources, isNot(contains('timer.periodic')));
    },
  );
}

Map<String, dynamic> _play({
  required String? id,
  required String type,
  required String text,
  int yards = 0,
  bool scoring = false,
}) {
  final play = <String, dynamic>{
    'type': {'text': type},
    'text': text,
    'statYardage': yards,
    'scoringPlay': scoring,
    'period': {'number': 3},
    'clock': {'displayValue': '08:14'},
    'wallclock': '2026-08-22T19:15:00Z',
    'start': {
      'team': {'id': '4'},
    },
  };
  if (id != null) play['id'] = id;
  return play;
}

Map<String, dynamic> _summary(List<Map<String, dynamic>> plays) => {
  'header': {
    'competitions': [
      {
        'competitors': [
          {
            'id': '4',
            'team': {'id': '4', 'abbreviation': 'CIN'},
          },
        ],
      },
    ],
  },
  'drives': {
    'previous': [
      {
        'team': {'abbreviation': 'CIN'},
        'plays': plays,
      },
    ],
  },
};

Map<String, dynamic> _scoreboard(List<String> ids, {String state = 'in'}) => {
  'events': [
    for (final id in ids)
      {
        'id': id,
        'competitions': [
          {
            'status': {
              'type': {'state': state},
            },
            'competitors': [
              {
                'homeAway': 'home',
                'team': {'abbreviation': 'CIN'},
              },
              {
                'homeAway': 'away',
                'team': {'abbreviation': 'BAL'},
              },
            ],
          },
        ],
      },
  ],
};

http.Response _jsonResponse(Object body) =>
    http.Response(jsonEncode(body), 200);

FantasyNflPlay _typedPlay(
  String id, {
  String gameId = 'g1',
  String description = 'Play',
}) => FantasyNflPlay(
  playId: id,
  gameId: gameId,
  description: description,
  possessionTeam: 'CIN',
  yards: 1,
  type: FantasyNflPlayType.rush,
  wallClock: null,
  quarter: 1,
  gameClock: '10:00',
  isScoringPlay: false,
  participants: const [],
  usesFallbackIdentity: false,
);
