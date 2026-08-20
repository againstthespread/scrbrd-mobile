import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/espn_golf.dart';

void main() {
  test('discovers PGA tournament containing selected date', () {
    final result = parseEspnGolfScoreboard(
      _fixture([_golfer('1', 'Player One', order: 1, score: '-2', holes: 18)]),
      selectedDate: DateTime(2026, 8, 21),
    );
    expect(result?.tournamentId, '401-tournament');
    expect(result?.tournamentName, 'Prototype Open');
  });

  test('maps pre-tee golfer to E and tee time', () {
    final row = _parse(
      _golfer(
        '1',
        'Pre Tee',
        order: 1,
        score: 'E',
        holes: 0,
        teeTime: 'Thu Aug 20 13:20:00 PDT 2026',
      ),
    );
    expect(row.score, 'E');
    expect(row.detail, '1:20 PM');
  });

  test('maps live golfer to score and THRU', () {
    final row = _parse(
      _golfer('2', 'Live Player', order: 2, score: '-3', holes: 11),
    );
    expect(row.score, '-3');
    expect(row.detail, 'THRU 11');
  });

  test('maps finished golfer to score and F', () {
    final row = _parse(
      _golfer('3', 'Finished Player', order: 3, score: '+1', holes: 18),
    );
    expect(row.score, '+1');
    expect(row.detail, 'F');
  });

  for (final status in ['CUT', 'WD', 'DQ']) {
    test('preserves explicit $status status', () {
      final row = _parse(
        _golfer(status, '$status Player', order: 20, score: status, holes: 0),
      );
      expect(row.score, status);
      expect(row.detail, isNull);
    });
  }

  test('preserves supplied tied ranks and response order', () {
    final leaderboard = parseEspnGolfScoreboard(
      _fixture([
        _golfer('1', 'First Tie', order: 1, rank: 'T1', score: '-5', holes: 9),
        _golfer('2', 'Second Tie', order: 2, rank: 'T1', score: '-5', holes: 8),
      ]),
      tournamentId: '401-tournament',
    )!;
    expect(leaderboard.golfers.map((row) => row.name), [
      'First Tie',
      'Second Tie',
    ]);
    expect(leaderboard.golfers.map((row) => row.rank), ['T1', 'T1']);
  });
}

dynamic _parse(Map<String, dynamic> golfer) => parseEspnGolfScoreboard(
  _fixture([golfer]),
  tournamentId: '401-tournament',
)!.golfers.single;

Map<String, dynamic> _fixture(List<Map<String, dynamic>> golfers) => {
  'events': [
    {
      'id': '401-tournament',
      'name': 'Prototype Open',
      'date': '2026-08-20T04:00:00Z',
      'endDate': '2026-08-23T04:00:00Z',
      'status': {
        'type': {
          'name': 'STATUS_IN_PROGRESS',
          'state': 'in',
          'completed': false,
        },
      },
      'competitions': [
        {
          'status': {'period': 1},
          'competitors': golfers,
        },
      ],
    },
  ],
};

Map<String, dynamic> _golfer(
  String id,
  String name, {
  required int order,
  String? rank,
  required String score,
  required int holes,
  String? teeTime,
}) => {
  'id': id,
  'order': order,
  'displayRank': ?rank,
  'score': score,
  'athlete': {'displayName': name},
  'linescores': [
    {
      'period': 1,
      'linescores': List.generate(holes, (index) => {'period': index + 1}),
      'statistics': {
        'categories': [
          {
            'stats': [
              {'displayValue': '0'},
              {'displayValue': teeTime ?? ''},
            ],
          },
        ],
      },
    },
  ],
};
