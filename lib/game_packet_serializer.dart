import 'dart:convert';

import 'game_data.dart';

class GamePacketValidationException implements Exception {
  const GamePacketValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ChunkedSlateTransfer {
  const ChunkedSlateTransfer({
    required this.slateId,
    required this.startPacket,
    required this.chunkPackets,
    required this.endPacket,
  });

  final String slateId;
  final List<int> startPacket;
  final List<List<int>> chunkPackets;
  final List<int> endPacket;

  List<List<int>> get packets => [startPacket, ...chunkPackets, endPacket];
}

class GamePacketSerializer {
  const GamePacketSerializer();

  static const protocolVersion = 1;
  static const packetType = 'game';
  static const slatePacketType = 'slate';
  static const slateStartPacketType = 'slate_start';
  static const slateChunkPacketType = 'slate_chunk';
  static const slateEndPacketType = 'slate_end';
  static const maxLegacySlateGames = 4;
  static const maxSlateGames = 20;
  static const maxSlatePacketBytes = 512;
  static const maxSlateIdBytes = 48;
  static const maxEventIdBytes = 48;
  static const maxLeagueBytes = 12;
  static const maxTeamBytes = 32;
  static const maxStatusBytes = 8;
  static const maxClockBytes = 24;
  static const maxScore = 255;
  static const _validStatuses = {'UPCOMING', 'LIVE', 'FINAL'};

  List<int> serialize(GameData gameData) {
    _validate(gameData);
    return utf8.encode(serializeToString(gameData));
  }

  String serializeToString(GameData gameData) {
    _validate(gameData);
    final packet = <String, Object>{
      'version': protocolVersion,
      'type': packetType,
      'league': gameData.league.trim(),
      'away': gameData.awayTeam.trim(),
      'home': gameData.homeTeam.trim(),
      'awayScore': gameData.awayScore,
      'homeScore': gameData.homeScore,
      'status': gameData.status.trim(),
      'clock': gameData.clock.trim(),
    };
    _addBaseballState(packet, gameData);
    return jsonEncode(packet);
  }

  List<int> canonicalSlateContent(List<GameData> games) {
    _validateSlateGames(games);
    return utf8.encode(
      jsonEncode({
        'league': games.first.league.trim(),
        'games': games.map(_gameToSlateJson).toList(),
      }),
    );
  }

  List<int> serializeSlate(List<GameData> games) {
    return utf8.encode(serializeSlateToString(games));
  }

  String serializeSlateToString(List<GameData> games) {
    if (games.isEmpty) {
      throw const GamePacketValidationException(
        'A slate must contain at least one game.',
      );
    }
    if (games.length > maxLegacySlateGames) {
      throw const GamePacketValidationException(
        'A one-packet slate may contain at most $maxLegacySlateGames games.',
      );
    }

    final league = games.first.league.trim();
    for (final game in games) {
      _validate(game);
      if (game.league.trim() != league) {
        throw const GamePacketValidationException(
          'All slate games must be from the same league.',
        );
      }
      final eventId = game.eventId?.trim();
      if (eventId != null && eventId.isNotEmpty) {
        _validateRequiredText('id', eventId, maxEventIdBytes);
      }
    }

    final packet = jsonEncode({
      'version': protocolVersion,
      'type': slatePacketType,
      'league': league,
      'games': games.map(_gameToSlateJson).toList(),
    });
    if (utf8.encode(packet).length > maxSlatePacketBytes) {
      throw const GamePacketValidationException(
        'Slate packet exceeds the $maxSlatePacketBytes-byte BLE limit.',
      );
    }
    return packet;
  }

  ChunkedSlateTransfer buildChunkedSlateTransfer(
    List<GameData> games, {
    required String slateId,
  }) {
    _validateSlateGames(games);
    _validateRequiredText('slateId', slateId, maxSlateIdBytes);
    final normalizedSlateId = slateId.trim();

    final chunks = <List<GameData>>[];
    var currentChunk = <GameData>[];
    for (final game in games) {
      final candidate = [...currentChunk, game];
      final candidatePacket = _serializeSlateChunk(
        normalizedSlateId,
        maxSlateGames - 1,
        candidate,
      );
      if (utf8.encode(candidatePacket).length <= maxSlatePacketBytes) {
        currentChunk = candidate;
        continue;
      }
      if (currentChunk.isEmpty) {
        throw const GamePacketValidationException(
          'A game is too large to fit in one slate chunk.',
        );
      }
      chunks.add(currentChunk);
      currentChunk = [game];
      if (utf8
              .encode(
                _serializeSlateChunk(
                  normalizedSlateId,
                  maxSlateGames - 1,
                  currentChunk,
                ),
              )
              .length >
          maxSlatePacketBytes) {
        throw const GamePacketValidationException(
          'A game is too large to fit in one slate chunk.',
        );
      }
    }
    chunks.add(currentChunk);

    final startPacket = utf8.encode(
      jsonEncode({
        'version': protocolVersion,
        'type': slateStartPacketType,
        'league': games.first.league.trim(),
        'slateId': normalizedSlateId,
        'totalGames': games.length,
        'totalChunks': chunks.length,
      }),
    );
    final chunkPackets = [
      for (var index = 0; index < chunks.length; index++)
        utf8.encode(
          _serializeSlateChunk(normalizedSlateId, index, chunks[index]),
        ),
    ];
    final endPacket = utf8.encode(
      jsonEncode({
        'version': protocolVersion,
        'type': slateEndPacketType,
        'slateId': normalizedSlateId,
      }),
    );

    for (final packet in [startPacket, ...chunkPackets, endPacket]) {
      if (packet.length > maxSlatePacketBytes) {
        throw const GamePacketValidationException(
          'Slate transfer packet exceeds the $maxSlatePacketBytes-byte BLE limit.',
        );
      }
    }
    return ChunkedSlateTransfer(
      slateId: normalizedSlateId,
      startPacket: startPacket,
      chunkPackets: chunkPackets,
      endPacket: endPacket,
    );
  }

  void _validateSlateGames(List<GameData> games) {
    if (games.isEmpty) {
      throw const GamePacketValidationException(
        'A slate must contain at least one game.',
      );
    }
    if (games.length > maxSlateGames) {
      throw const GamePacketValidationException(
        'A slate may contain at most $maxSlateGames games.',
      );
    }
    final league = games.first.league.trim();
    for (final game in games) {
      _validate(game);
      if (game.league.trim() != league) {
        throw const GamePacketValidationException(
          'All slate games must be from the same league.',
        );
      }
      final eventId = game.eventId?.trim();
      if (eventId != null && eventId.isNotEmpty) {
        _validateRequiredText('id', eventId, maxEventIdBytes);
      }
    }
  }

  String _serializeSlateChunk(
    String slateId,
    int chunkIndex,
    List<GameData> games,
  ) {
    return jsonEncode({
      'version': protocolVersion,
      'type': slateChunkPacketType,
      'slateId': slateId,
      'chunkIndex': chunkIndex,
      'games': games.map(_gameToSlateJson).toList(),
    });
  }

  Map<String, Object> _gameToSlateJson(GameData game) {
    final packetGame = <String, Object>{
      'away': game.awayTeam.trim(),
      'home': game.homeTeam.trim(),
      'awayScore': game.awayScore,
      'homeScore': game.homeScore,
      'status': game.status.trim(),
      'clock': game.clock.trim(),
    };
    final eventId = game.eventId?.trim();
    if (eventId != null && eventId.isNotEmpty) {
      packetGame['id'] = eventId;
    }
    _addBaseballState(packetGame, game);
    return packetGame;
  }

  void _addBaseballState(Map<String, Object> json, GameData game) {
    final state = game.baseballState;
    if (state == null) return;
    json.addAll({
      'onFirst': state.runnerOnFirst,
      'onSecond': state.runnerOnSecond,
      'onThird': state.runnerOnThird,
      'outs': state.outs,
    });
  }

  void _validate(GameData gameData) {
    _validateRequiredText('league', gameData.league, maxLeagueBytes);
    _validateRequiredText('away', gameData.awayTeam, maxTeamBytes);
    _validateRequiredText('home', gameData.homeTeam, maxTeamBytes);
    _validateRequiredText('clock', gameData.clock, maxClockBytes);
    _validateScore('awayScore', gameData.awayScore);
    _validateScore('homeScore', gameData.homeScore);

    final status = gameData.status.trim();
    _validateRequiredText('status', status, maxStatusBytes);
    if (!_validStatuses.contains(status)) {
      throw GamePacketValidationException(
        'status must be UPCOMING, LIVE, or FINAL.',
      );
    }
    final baseballState = gameData.baseballState;
    if (baseballState != null &&
        (baseballState.outs < 0 || baseballState.outs > 2)) {
      throw const GamePacketValidationException(
        'baseball outs must be between 0 and 2.',
      );
    }
  }

  void _validateRequiredText(String field, String value, int maxUtf8Bytes) {
    final trimmedValue = value.trim();
    if (trimmedValue.isEmpty) {
      throw GamePacketValidationException('$field is required.');
    }

    if (utf8.encode(trimmedValue).length > maxUtf8Bytes) {
      throw GamePacketValidationException(
        '$field must be $maxUtf8Bytes UTF-8 bytes or fewer.',
      );
    }
  }

  void _validateScore(String field, int value) {
    if (value < 0 || value > maxScore) {
      throw GamePacketValidationException(
        '$field must be between 0 and $maxScore.',
      );
    }
  }
}
