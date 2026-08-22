import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/fantasy_nfl_play.dart';
import 'package:sports_hub_mobile/fantasy_point_delta_tracker.dart';
import 'package:sports_hub_mobile/fantasy_scoring_correlation.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';

void main() {
  const correlator = FantasyScoringCorrelator();
  const ppr = {
    'rec': 1.0,
    'rec_yd': 0.1,
    'rec_td': 6.0,
    'pass_yd': 0.04,
    'pass_td': 4.0,
    'pass_int': -2.0,
    'rush_yd': 0.1,
    'rush_td': 6.0,
  };

  FantasyScoringEvent correlate({
    SleeperFantasyPlayer? player,
    FantasyNflPlay? play,
    double delta = 12,
    Map<String, double> scoring = ppr,
  }) => correlator
      .correlate(
        deltas: [_delta(player?.sleeperPlayerId ?? 'missing', delta)],
        players: player == null ? {} : {player.sleeperPlayerId: player},
        plays: play == null ? [] : [play],
        scoringSettings: scoring,
      )
      .single;

  group('identity and conservative matching', () {
    test('exact ESPN athlete ID is strong evidence', () {
      final event = correlate(
        player: _player(espnId: '99'),
        play: _play(
          'Unrelated rendering of a scoring play.',
          participants: [_participant(id: '99')],
        ),
      );
      expect(event.matchedPlay, isNotNull);
      expect(event.confidence, FantasyCorrelationConfidence.high);
    });

    test('normalized full name matches punctuation and capitalization', () {
      final event = correlate(
        player: _player(),
        play: _play("JA MARR CHASE catches a pass for 50 yards, touchdown."),
      );
      expect(event.matchedPlay, isNotNull);
    });

    test('first initial and surname handles apostrophe', () {
      final event = correlate(
        player: _player(),
        play: _play('J. Chase 50-yard reception, touchdown.'),
      );
      expect(event.matchedPlay, isNotNull);
      expect(event.predictedPoints, 12);
    });

    test('hyphenated first and multipart surname match safely', () {
      final player = _player(
        id: '2',
        first: 'Amon-Ra',
        last: 'St. Brown',
        team: 'DET',
      );
      expect(
        correlate(
          player: player,
          play: _play('A. St. Brown reception for 10 yards.', team: 'DET'),
          delta: 2,
        ).matchedPlay,
        isNotNull,
      );
    });

    test('suffix is ignored after a first-initial surname match', () {
      final player = _player(
        id: '3',
        first: 'Brian',
        last: 'Robinson Jr.',
        team: 'WAS',
        position: 'RB',
      );
      expect(
        correlate(
          player: player,
          play: _play('B. Robinson Jr. rush for 10 yards.', team: 'WAS'),
          delta: 1,
        ).matchedPlay,
        isNotNull,
      );
    });

    test('wrong surname does not match', () {
      expect(
        correlate(
          player: _player(),
          play: _play('J. Jefferson touchdown.'),
        ).matchedPlay,
        isNull,
      );
    });

    test('equal plausible candidates are rejected as ambiguous', () {
      final events = correlator.correlate(
        deltas: [_delta('1', 1)],
        players: {'1': _player()},
        plays: [
          _play('J. Chase reception for 10 yards.', id: 'a'),
          _play('J. Chase reception for 10 yards.', id: 'b'),
        ],
        scoringSettings: ppr,
      );
      expect(events.single.matchedPlay, isNull);
      expect(events.single.diagnostic, contains('ambiguous'));
    });

    test('wrong possession team rejects a textual candidate', () {
      expect(
        correlate(
          player: _player(),
          play: _play('J. Chase touchdown.', team: 'BAL'),
        ).matchedPlay,
        isNull,
      );
    });

    test('structured ID overrides weak team context', () {
      expect(
        correlate(
          player: _player(espnId: '99'),
          play: _play(
            'Defensive change of possession.',
            team: 'BAL',
            participants: [_participant(id: '99', team: 'CIN')],
          ),
        ).matchedPlay,
        isNotNull,
      );
    });
  });

  group('limited scoring evidence', () {
    test('50-yard PPR receiving touchdown predicts 12', () {
      expect(
        correlate(
          player: _player(),
          play: _play('J. Chase pass reception for 50 yards, touchdown.'),
        ).predictedPoints,
        12,
      );
    });

    test('half-PPR receiving touchdown predicts 11.5', () {
      expect(
        correlate(
          player: _player(),
          play: _play('J. Chase pass reception for 50 yards, touchdown.'),
          delta: 11.5,
          scoring: {...ppr, 'rec': 0.5},
        ).predictedPoints,
        11.5,
      );
    });

    test('passing touchdown and yardage use QB settings', () {
      final qb = _player(
        id: 'qb',
        first: 'Joe',
        last: 'Burrow',
        position: 'QB',
      );
      expect(
        correlate(
          player: qb,
          play: _play('J. Burrow pass for 50 yards, touchdown.'),
          delta: 6,
        ).predictedPoints,
        6,
      );
    });

    test('rushing touchdown and yardage use rushing settings', () {
      final rb = _player(
        id: 'rb',
        first: 'Breece',
        last: 'Hall',
        position: 'RB',
        team: 'NYJ',
      );
      expect(
        correlate(
          player: rb,
          play: _play(
            'B. Hall rush for 20 yards, touchdown.',
            team: 'NYJ',
            type: FantasyNflPlayType.rush,
          ),
          delta: 8,
        ).predictedPoints,
        8,
      );
    });

    test('interception supports negative scoring', () {
      final qb = _player(
        id: 'qb',
        first: 'Joe',
        last: 'Burrow',
        position: 'QB',
      );
      expect(
        correlate(
          player: qb,
          play: _play(
            'J. Burrow pass intercepted.',
            type: FantasyNflPlayType.interception,
          ),
          delta: -2,
        ).predictedPoints,
        -2,
      );
    });

    test('predicted mismatch never changes Sleeper delta', () {
      final event = correlate(
        player: _player(),
        play: _play('J. Chase pass reception for 50 yards, touchdown.'),
        delta: 14,
      );
      expect(event.delta.delta, 14);
      expect(event.predictedPoints, 12);
      expect(event.matchedPlay, isNotNull);
    });

    test('unsupported bonus does not destroy strong identity', () {
      final event = correlate(
        player: _player(espnId: '99'),
        play: _play(
          'J. Chase pass reception for 50 yards, touchdown.',
          participants: [_participant(id: '99')],
        ),
        delta: 14,
      );
      expect(event.confidence, FantasyCorrelationConfidence.high);
    });
  });

  group('batch and safe fallback behavior', () {
    test('one TD play can explain passer and receiver deltas', () {
      final chase = _player();
      final burrow = _player(
        id: 'qb',
        first: 'Joe',
        last: 'Burrow',
        position: 'QB',
        espnId: '8',
      );
      final play = _play(
        'J. Burrow pass complete to J. Chase for 50 yards, touchdown.',
        participants: [_participant(id: '8', role: 'passer')],
      );
      final events = correlator.correlate(
        deltas: [_delta('1', 12), _delta('qb', 6)],
        players: {'1': chase, 'qb': burrow},
        plays: [play],
        scoringSettings: ppr,
      );
      expect(events.map((event) => event.matchedPlay?.playId), ['p1', 'p1']);
    });

    test('unrelated deltas select different plays', () {
      final chase = _player();
      final hall = _player(
        id: 'rb',
        first: 'Breece',
        last: 'Hall',
        position: 'RB',
        team: 'NYJ',
      );
      final events = correlator.correlate(
        deltas: [_delta('1', 2), _delta('rb', 1)],
        players: {'1': chase, 'rb': hall},
        plays: [
          _play('J. Chase reception for 10 yards.', id: 'a'),
          _play('B. Hall rush for 10 yards.', id: 'b', team: 'NYJ'),
        ],
        scoringSettings: ppr,
      );
      expect(events.map((event) => event.matchedPlay?.playId), ['a', 'b']);
    });

    test('negative correction with no play is safe and authoritative', () {
      final event = correlate(player: _player(), delta: -1);
      expect(event.matchedPlay, isNull);
      expect(event.delta.delta, -1);
    });

    test('delta with no plays and missing metadata safely falls back', () {
      final event = correlate(delta: 1.7);
      expect(event.matchedPlay, isNull);
      expect(event.player, isNull);
      expect(event.confidence, FantasyCorrelationConfidence.none);
    });

    test('plays without deltas create no fantasy events', () {
      expect(
        correlator.correlate(
          deltas: const [],
          players: {'1': _player()},
          plays: [_play('J. Chase touchdown.')],
          scoringSettings: ppr,
        ),
        isEmpty,
      );
    });

    test('null ESPN ID and missing participant still allow text match', () {
      expect(
        correlate(
          player: _player(),
          play: _play('J. Chase reception for 10 yards.'),
          delta: 2,
        ).matchedPlay,
        isNotNull,
      );
    });

    test('malformed description does not fabricate a match', () {
      expect(
        correlate(player: _player(), play: _play('---')).matchedPlay,
        isNull,
      );
    });

    test('unsupported D/ST delta remains unmatched', () {
      final defense = _player(
        id: 'DEF',
        first: 'Cincinnati',
        last: 'Defense',
        position: 'DEF',
      );
      expect(correlate(player: defense, delta: 6).matchedPlay, isNull);
    });
  });

  test(
    'correlation layer contains no HTTP, BLE, or periodic timer coupling',
    () {
      final source = File(
        'lib/fantasy_scoring_correlation.dart',
      ).readAsStringSync();
      expect(source, isNot(contains('package:http')));
      expect(source, isNot(contains('Bluetooth')));
      expect(source, isNot(contains('Timer.periodic')));
    },
  );
}

FantasyPointDelta _delta(String id, double value) => FantasyPointDelta(
  playerId: id,
  side: FantasyMatchupSide.user,
  previousPoints: 0,
  currentPoints: value,
  delta: value,
);

SleeperFantasyPlayer _player({
  String id = '1',
  String first = "Ja'Marr",
  String last = 'Chase',
  String team = 'CIN',
  String position = 'WR',
  String? espnId,
}) => SleeperFantasyPlayer(
  sleeperPlayerId: id,
  fullName: '$first $last',
  firstName: first,
  lastName: last,
  position: position,
  nflTeam: team,
  espnPlayerId: espnId,
);

FantasyNflPlayParticipant _participant({
  required String id,
  String role = 'receiver',
  String team = 'CIN',
}) => FantasyNflPlayParticipant(
  espnAthleteId: id,
  displayName: null,
  role: role,
  team: team,
);

FantasyNflPlay _play(
  String description, {
  String id = 'p1',
  String team = 'CIN',
  FantasyNflPlayType type = FantasyNflPlayType.reception,
  List<FantasyNflPlayParticipant> participants = const [],
}) => FantasyNflPlay(
  playId: id,
  gameId: 'g1',
  description: description,
  possessionTeam: team,
  yards: _yards(description),
  type: type,
  wallClock: null,
  quarter: 1,
  gameClock: '10:00',
  isScoringPlay: description.toLowerCase().contains('touchdown'),
  participants: participants,
  usesFallbackIdentity: false,
);

int? _yards(String description) {
  final value = RegExp(r'(\d+)[ -]yard').firstMatch(description)?.group(1);
  return value == null ? null : int.parse(value);
}
