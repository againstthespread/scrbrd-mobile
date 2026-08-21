import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/game_packet_serializer.dart';
import 'package:sports_hub_mobile/sports_game.dart';

void main() {
  const serializer = GamePacketSerializer();

  test('serializes and decodes optional baseball state', () {
    final packet = serializer.serializeToString(
      _game(
        const BaseballGameState(
          runnerOnFirst: true,
          runnerOnSecond: false,
          runnerOnThird: true,
          outs: 2,
        ),
      ),
    );
    final decoded = jsonDecode(packet) as Map<String, dynamic>;

    expect(decoded['onFirst'], isTrue);
    expect(decoded['onSecond'], isFalse);
    expect(decoded['onThird'], isTrue);
    expect(decoded['outs'], 2);
  });

  test('legacy packet omits baseball fields', () {
    final decoded =
        jsonDecode(serializer.serializeToString(_game(null)))
            as Map<String, dynamic>;
    expect(decoded, isNot(contains('onFirst')));
    expect(decoded, isNot(contains('onSecond')));
    expect(decoded, isNot(contains('onThird')));
    expect(decoded, isNot(contains('outs')));
  });

  test('base occupancy change changes serialized game data', () {
    const empty = BaseballGameState(
      runnerOnFirst: false,
      runnerOnSecond: false,
      runnerOnThird: false,
      outs: 0,
    );
    const runnerOnFirst = BaseballGameState(
      runnerOnFirst: true,
      runnerOnSecond: false,
      runnerOnThird: false,
      outs: 0,
    );
    expect(
      serializer.serializeToString(_game(empty)),
      isNot(serializer.serializeToString(_game(runnerOnFirst))),
    );
  });

  test('outs change changes serialized game data', () {
    const zeroOuts = BaseballGameState(
      runnerOnFirst: false,
      runnerOnSecond: false,
      runnerOnThird: false,
      outs: 0,
    );
    const oneOut = BaseballGameState(
      runnerOnFirst: false,
      runnerOnSecond: false,
      runnerOnThird: false,
      outs: 1,
    );
    expect(
      serializer.serializeToString(_game(zeroOuts)),
      isNot(serializer.serializeToString(_game(oneOut))),
    );
  });

  test('rejects a third-out state', () {
    expect(
      () => serializer.serializeToString(
        _game(
          const BaseballGameState(
            runnerOnFirst: false,
            runnerOnSecond: false,
            runnerOnThird: false,
            outs: 3,
          ),
        ),
      ),
      throwsA(isA<GamePacketValidationException>()),
    );
  });
}

GameData _game(BaseballGameState? state) => GameData(
  league: 'MLB',
  awayTeam: 'NYY',
  homeTeam: 'BOS',
  awayScore: 2,
  homeScore: 1,
  status: 'LIVE',
  clock: 'Top 5th',
  eventId: '401-test',
  baseballState: state,
);
