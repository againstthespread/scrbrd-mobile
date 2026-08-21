import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/game_packet_serializer.dart';
import 'package:sports_hub_mobile/sports_game.dart';

void main() {
  const serializer = GamePacketSerializer();

  test('identical slates compare equal independent of transfer IDs', () {
    final slate = [_game('1'), _game('2')];
    expect(
      serializer.canonicalSlateContent(slate),
      serializer.canonicalSlateContent(List.of(slate)),
    );
    final a = serializer.buildChunkedSlateTransfer(slate, slateId: 'a');
    final b = serializer.buildChunkedSlateTransfer(slate, slateId: 'b');
    expect(a.startPacket, isNot(b.startPacket));
    expect(
      serializer.canonicalSlateContent(slate),
      serializer.canonicalSlateContent(slate),
    );
  });

  test('score clock status bases outs membership and order are relevant', () {
    final base = [_game('1'), _game('2')];
    final canonical = serializer.canonicalSlateContent(base);
    expect(
      serializer.canonicalSlateContent([_game('1', score: 2), base[1]]),
      isNot(canonical),
    );
    expect(
      serializer.canonicalSlateContent([_game('1', clock: 'Bot 5th'), base[1]]),
      isNot(canonical),
    );
    expect(
      serializer.canonicalSlateContent([_game('1', status: 'FINAL'), base[1]]),
      isNot(canonical),
    );
    expect(
      serializer.canonicalSlateContent([_game('1', outs: 2), base[1]]),
      isNot(canonical),
    );
    expect(
      serializer.canonicalSlateContent(base.reversed.toList()),
      isNot(canonical),
    );
    expect(serializer.canonicalSlateContent([base.first]), isNot(canonical));
  });
}

GameData _game(
  String id, {
  int score = 1,
  String clock = 'Top 5th',
  String status = 'LIVE',
  int outs = 1,
}) => GameData(
  eventId: id,
  league: 'MLB',
  awayTeam: 'A$id',
  homeTeam: 'H$id',
  awayScore: score,
  homeScore: 0,
  status: status,
  clock: clock,
  baseballState: BaseballGameState(
    runnerOnFirst: true,
    runnerOnSecond: false,
    runnerOnThird: false,
    outs: outs,
  ),
);
