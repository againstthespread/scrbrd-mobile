import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/game_packet_serializer.dart';

void main() {
  const serializer = GamePacketSerializer();

  test('incomplete transfer does not replace the active slate', () {
    final receiver = _SlateReceiverHarness(activeIds: const ['old']);
    final transfer = serializer.buildChunkedSlateTransfer(
      _games(15),
      slateId: 'new-slate',
    );

    receiver.receive(transfer.startPacket);
    receiver.receive(transfer.chunkPackets.first);
    expect(() => receiver.receive(transfer.endPacket), throwsStateError);
    expect(receiver.activeIds, const ['old']);
  });

  test('wrong slateId and duplicate chunks are rejected', () {
    final receiver = _SlateReceiverHarness(activeIds: const ['old']);
    final transfer = serializer.buildChunkedSlateTransfer(
      _games(15),
      slateId: 'expected',
    );
    receiver.receive(transfer.startPacket);

    final wrongId = _rewrite(transfer.chunkPackets.first, {'slateId': 'wrong'});
    expect(() => receiver.receive(wrongId), throwsStateError);
    receiver.receive(transfer.chunkPackets.first);
    expect(
      () => receiver.receive(transfer.chunkPackets.first),
      throwsStateError,
    );
    expect(receiver.activeIds, const ['old']);
  });

  test('malformed game is rejected without replacing active slate', () {
    final receiver = _SlateReceiverHarness(activeIds: const ['old']);
    final transfer = serializer.buildChunkedSlateTransfer(
      _games(4),
      slateId: 'malformed',
    );
    receiver.receive(transfer.startPacket);
    final chunk = jsonDecode(utf8.decode(transfer.chunkPackets.first)) as Map;
    (chunk['games'] as List).first['status'] = 'DELAYED';

    expect(
      () => receiver.receive(utf8.encode(jsonEncode(chunk))),
      throwsStateError,
    );
    expect(receiver.activeIds, const ['old']);
  });

  test('successful slate_end atomically activates the staged slate', () {
    final receiver = _SlateReceiverHarness(activeIds: const ['old']);
    final transfer = serializer.buildChunkedSlateTransfer(
      _games(20),
      slateId: 'complete',
    );

    receiver.receive(transfer.startPacket);
    for (final chunk in transfer.chunkPackets) {
      receiver.receive(chunk);
      expect(receiver.activeIds, const ['old']);
    }
    receiver.receive(transfer.endPacket);

    expect(receiver.activeIds, hasLength(20));
    expect(receiver.activeIds.first, 'event-0');
    expect(receiver.activeIds.last, 'event-19');
  });
}

List<GameData> _games(int count) {
  return List.generate(
    count,
    (index) => GameData(
      league: 'MLB',
      awayTeam: 'A$index',
      homeTeam: 'H$index',
      awayScore: index,
      homeScore: index + 1,
      status: index.isEven ? 'LIVE' : 'FINAL',
      clock: index.isEven ? 'BOT 7' : 'FINAL',
      eventId: 'event-$index',
    ),
  );
}

List<int> _rewrite(List<int> packet, Map<String, Object> changes) {
  final decoded = jsonDecode(utf8.decode(packet)) as Map<String, dynamic>;
  decoded.addAll(changes);
  return utf8.encode(jsonEncode(decoded));
}

// Mirrors the ESP32 staging contract so protocol regressions are testable
// without replacing the firmware compilation check.
class _SlateReceiverHarness {
  _SlateReceiverHarness({required this.activeIds});

  List<String> activeIds;
  String? _slateId;
  int _expectedGames = 0;
  int _expectedChunks = 0;
  int _nextChunk = 0;
  final _stagedIds = <String>[];

  void receive(List<int> bytes) {
    final packet = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    switch (packet['type']) {
      case 'slate_start':
        _slateId = packet['slateId'] as String;
        _expectedGames = packet['totalGames'] as int;
        _expectedChunks = packet['totalChunks'] as int;
        _nextChunk = 0;
        _stagedIds.clear();
        return;
      case 'slate_chunk':
        _requireMatchingId(packet);
        final index = packet['chunkIndex'] as int;
        if (index != _nextChunk) throw StateError('duplicate/out-of-order');
        final games = packet['games'] as List;
        for (final value in games) {
          final game = value as Map<String, dynamic>;
          if (!const {'UPCOMING', 'LIVE', 'FINAL'}.contains(game['status']) ||
              (game['away'] as String).isEmpty ||
              (game['home'] as String).isEmpty ||
              (game['clock'] as String).isEmpty) {
            throw StateError('malformed game');
          }
        }
        _stagedIds.addAll(
          games.map((game) => (game as Map<String, dynamic>)['id'] as String),
        );
        _nextChunk++;
        return;
      case 'slate_end':
        _requireMatchingId(packet);
        if (_nextChunk != _expectedChunks ||
            _stagedIds.length != _expectedGames) {
          throw StateError('incomplete transfer');
        }
        activeIds = List.of(_stagedIds);
        _slateId = null;
        return;
      default:
        throw StateError('unsupported packet');
    }
  }

  void _requireMatchingId(Map<String, dynamic> packet) {
    if (_slateId == null || packet['slateId'] != _slateId) {
      throw StateError('wrong slateId');
    }
  }
}
