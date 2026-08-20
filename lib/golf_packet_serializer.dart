import 'dart:convert';

import 'game_packet_serializer.dart';
import 'golf_leaderboard.dart';

class GolfTransfer {
  const GolfTransfer({
    required this.transferId,
    required this.startPacket,
    required this.chunkPackets,
    required this.endPacket,
  });

  final String transferId;
  final List<int> startPacket;
  final List<List<int>> chunkPackets;
  final List<int> endPacket;
}

class GolfPacketSerializer {
  const GolfPacketSerializer();

  static const maxGolfers = 50;
  static const maxPacketBytes = 512;
  static const maxTournamentNameBytes = 48;
  static const maxIdentifierBytes = 48;
  static const maxGolferNameBytes = 32;

  GolfTransfer buildTransfer(
    GolfLeaderboard leaderboard, {
    required String transferId,
  }) {
    _required('transferId', transferId, maxIdentifierBytes);
    _required('tournamentId', leaderboard.tournamentId, maxIdentifierBytes);
    _required(
      'tournamentName',
      leaderboard.tournamentName,
      maxTournamentNameBytes,
    );
    if (leaderboard.golfers.isEmpty ||
        leaderboard.golfers.length > maxGolfers) {
      throw const GamePacketValidationException(
        'A golf leaderboard must contain 1 through 50 golfers.',
      );
    }
    for (final golfer in leaderboard.golfers) {
      _required('playerId', golfer.playerId, maxIdentifierBytes);
      _required('name', golfer.name, maxGolferNameBytes);
      _required('rank', golfer.rank, 8);
      _required('score', golfer.score, 8);
      if (golfer.detail != null && golfer.detail!.trim().isNotEmpty) {
        _required('detail', golfer.detail!, 16);
      }
    }

    final chunks = <List<GolfLeaderboardRow>>[];
    var current = <GolfLeaderboardRow>[];
    for (final golfer in leaderboard.golfers) {
      final candidate = [...current, golfer];
      if (_chunkBytes(transferId, maxGolfers - 1, candidate).length <=
          maxPacketBytes) {
        current = candidate;
      } else {
        if (current.isEmpty) {
          throw const GamePacketValidationException(
            'A golfer row is too large for one golf chunk.',
          );
        }
        chunks.add(current);
        current = [golfer];
      }
    }
    chunks.add(current);

    final start = utf8.encode(
      jsonEncode({
        'version': 1,
        'type': 'golf_start',
        'league': 'PGA',
        'transferId': transferId.trim(),
        'tournamentId': leaderboard.tournamentId.trim(),
        'tournamentName': leaderboard.tournamentName.trim(),
        'totalGolfers': leaderboard.golfers.length,
        'totalChunks': chunks.length,
      }),
    );
    final chunkPackets = [
      for (var index = 0; index < chunks.length; index++)
        _chunkBytes(transferId.trim(), index, chunks[index]),
    ];
    final end = utf8.encode(
      jsonEncode({
        'version': 1,
        'type': 'golf_end',
        'transferId': transferId.trim(),
      }),
    );
    for (final packet in [start, ...chunkPackets, end]) {
      if (packet.length > maxPacketBytes) {
        throw const GamePacketValidationException(
          'Golf transfer packet exceeds 512 bytes.',
        );
      }
    }
    return GolfTransfer(
      transferId: transferId.trim(),
      startPacket: start,
      chunkPackets: chunkPackets,
      endPacket: end,
    );
  }

  List<int> canonicalContent(GolfLeaderboard leaderboard) => utf8.encode(
    jsonEncode({
      'tournamentId': leaderboard.tournamentId,
      'tournamentName': leaderboard.tournamentName,
      'golfers': leaderboard.golfers.map(_rowJson).toList(),
    }),
  );

  List<int> _chunkBytes(
    String transferId,
    int index,
    List<GolfLeaderboardRow> golfers,
  ) => utf8.encode(
    jsonEncode({
      'version': 1,
      'type': 'golf_chunk',
      'transferId': transferId,
      'chunkIndex': index,
      'golfers': golfers.map(_rowJson).toList(),
    }),
  );

  Map<String, Object> _rowJson(GolfLeaderboardRow row) => {
    'id': row.playerId.trim(),
    'name': row.name.trim(),
    'rank': row.rank.trim(),
    'score': row.score.trim(),
    if (row.detail?.trim().isNotEmpty ?? false) 'detail': row.detail!.trim(),
  };

  void _required(String field, String value, int maxBytes) {
    final normalized = value.trim();
    if (normalized.isEmpty || utf8.encode(normalized).length > maxBytes) {
      throw GamePacketValidationException(
        '$field is required and must be $maxBytes UTF-8 bytes or fewer.',
      );
    }
  }
}
