import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/game_packet_serializer.dart';

void main() {
  const serializer = GamePacketSerializer();

  for (final count in [20, 21, 40, 67, 72]) {
    test('$count NCAAF games serialize without truncation', () {
      final games = _games(count);
      final transfer = serializer.buildChunkedSlateTransfer(
        games,
        slateId: 'ncaaf-$count',
      );
      expect(transfer.packets.every((packet) => packet.length <= 512), isTrue);
      final reconstructedIds = <String>[];
      for (final bytes in transfer.chunkPackets) {
        final packet = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        for (final game in packet['games'] as List<dynamic>) {
          reconstructedIds.add((game as Map<String, dynamic>)['id'] as String);
        }
      }
      expect(reconstructedIds, games.map((game) => game.eventId));
      expect(reconstructedIds, hasLength(count));
    });
  }

  test('73 games are rejected explicitly', () {
    expect(
      () =>
          serializer.buildChunkedSlateTransfer(_games(73), slateId: 'too-many'),
      throwsA(isA<GamePacketValidationException>()),
    );
  });
}

List<GameData> _games(int count) => List.generate(
  count,
  (index) => GameData(
    eventId: 'cfb-$index',
    league: 'NCAAF',
    awayTeam: 'A$index',
    homeTeam: 'H$index',
    awayScore: index % 50,
    homeScore: 0,
    status: 'UPCOMING',
    clock: '1:00 PM',
  ),
);
