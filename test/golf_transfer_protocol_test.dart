import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/golf_packet_serializer.dart';

void main() {
  test('incomplete golf transfer leaves existing PGA and MLB intact', () {
    final receiver = _GolfReceiverHarness()
      ..teamLeagues['MLB'] = ['game']
      ..activeGolfers = ['old'];
    final transfer = const GolfPacketSerializer().buildTransfer(
      _leaderboard(50),
      transferId: 'new',
    );
    receiver.receive(transfer.startPacket);
    receiver.receive(transfer.chunkPackets.first);
    expect(() => receiver.receive(transfer.endPacket), throwsStateError);
    expect(receiver.activeGolfers, ['old']);
    expect(receiver.teamLeagues['MLB'], ['game']);
  });

  test('complete transfer replaces only PGA and page navigation wraps', () {
    final receiver = _GolfReceiverHarness()
      ..teamLeagues['MLB'] = ['game']
      ..activeGolfers = ['old'];
    final transfer = const GolfPacketSerializer().buildTransfer(
      _leaderboard(47),
      transferId: 'complete',
    );
    receiver.receive(transfer.startPacket);
    for (final packet in transfer.chunkPackets) {
      receiver.receive(packet);
    }
    receiver.receive(transfer.endPacket);

    expect(receiver.activeGolfers, hasLength(47));
    expect(receiver.teamLeagues['MLB'], ['game']);
    expect(receiver.currentPageRows, hasLength(5));
    for (var index = 0; index < 9; index++) {
      receiver.nextPage();
    }
    expect(receiver.currentPageRows, hasLength(2));
    receiver.nextPage();
    expect(receiver.pageIndex, 0);
    for (var index = 0; index < 10; index++) {
      receiver.nextPage();
    }
    expect(receiver.pageIndex, 0);
  });
}

GolfLeaderboard _leaderboard(int count) => GolfLeaderboard(
  tournamentId: '77',
  tournamentName: 'The Championship',
  golfers: List.generate(
    count,
    (index) => GolfLeaderboardRow(
      playerId: '$index',
      name: 'Golfer $index',
      rank: '${index + 1}',
      score: '-$index',
    ),
  ),
  isInProgress: true,
  isOver: false,
);

class _GolfReceiverHarness {
  final teamLeagues = <String, List<String>>{};
  List<String> activeGolfers = [];
  List<String> _staged = [];
  String? _transferId;
  int _expectedGolfers = 0;
  int _expectedChunks = 0;
  int _nextChunk = 0;
  int pageIndex = 0;

  List<String> get currentPageRows =>
      activeGolfers.skip(pageIndex * 5).take(5).toList();

  void nextPage() {
    pageIndex = (pageIndex + 1) % ((activeGolfers.length + 4) ~/ 5);
  }

  void receive(List<int> bytes) {
    final packet = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    switch (packet['type']) {
      case 'golf_start':
        _transferId = packet['transferId'] as String;
        _expectedGolfers = packet['totalGolfers'] as int;
        _expectedChunks = packet['totalChunks'] as int;
        _nextChunk = 0;
        _staged = [];
        return;
      case 'golf_chunk':
        if (packet['transferId'] != _transferId ||
            packet['chunkIndex'] != _nextChunk) {
          throw StateError('invalid golf chunk');
        }
        _staged.addAll(
          (packet['golfers'] as List).map(
            (row) => (row as Map<String, dynamic>)['id'] as String,
          ),
        );
        _nextChunk++;
        return;
      case 'golf_end':
        if (packet['transferId'] != _transferId ||
            _nextChunk != _expectedChunks ||
            _staged.length != _expectedGolfers) {
          throw StateError('incomplete golf transfer');
        }
        activeGolfers = List.of(_staged);
        pageIndex = 0;
        return;
    }
  }
}
