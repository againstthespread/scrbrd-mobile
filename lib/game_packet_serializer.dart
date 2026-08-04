import 'dart:convert';

import 'game_data.dart';

class GamePacketValidationException implements Exception {
  const GamePacketValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GamePacketSerializer {
  const GamePacketSerializer();

  static const protocolVersion = 1;
  static const packetType = 'game';
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
    return jsonEncode({
      'version': protocolVersion,
      'type': packetType,
      'league': gameData.league.trim(),
      'away': gameData.awayTeam.trim(),
      'home': gameData.homeTeam.trim(),
      'awayScore': gameData.awayScore,
      'homeScore': gameData.homeScore,
      'status': gameData.status.trim(),
      'clock': gameData.clock.trim(),
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
