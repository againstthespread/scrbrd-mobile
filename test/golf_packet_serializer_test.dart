import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/golf_packet_serializer.dart';

void main() {
  test('builds a 50-golfer atomic chunked transfer under 512 bytes', () {
    const serializer = GolfPacketSerializer();
    final leaderboard = _leaderboard(50);
    final transfer = serializer.buildTransfer(
      leaderboard,
      transferId: 'golf-transfer-1',
    );

    final start = jsonDecode(utf8.decode(transfer.startPacket)) as Map;
    expect(start['type'], 'golf_start');
    expect(start['league'], 'PGA');
    expect(start['tournamentId'], '9001');
    expect(start['totalGolfers'], 50);
    expect(
      [
        transfer.startPacket,
        ...transfer.chunkPackets,
        transfer.endPacket,
      ].every((packet) => packet.length <= 512),
      isTrue,
    );
    final rows = transfer.chunkPackets.expand((packet) {
      return (jsonDecode(utf8.decode(packet)) as Map)['golfers'] as List;
    });
    expect(rows, hasLength(50));
  });

  test('golf page count uses five golfers and handles a partial page', () {
    expect(_leaderboard(50).pageCount, 10);
    expect(_leaderboard(6).pageCount, 2);
    expect(_leaderboard(5).pageCount, 1);
  });
}

GolfLeaderboard _leaderboard(int count) => GolfLeaderboard(
  tournamentId: '9001',
  tournamentName: 'BMW Championship',
  golfers: List.generate(
    count,
    (index) => GolfLeaderboardRow(
      playerId: '${400 + index}',
      name: 'Golfer $index',
      rank: '${index + 1}',
      score: index == 0 ? 'E' : '-$index',
      detail: 'F',
    ),
  ),
  isInProgress: true,
  isOver: false,
);
