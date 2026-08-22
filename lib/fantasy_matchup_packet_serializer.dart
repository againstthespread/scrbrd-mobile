import 'dart:convert';

import 'fantasy_matchup_display_data.dart';

class FantasyMatchupPacketSerializer {
  const FantasyMatchupPacketSerializer();

  static const maxPacketBytes = 512;
  static const maxLeagueNameLength = 48;
  static const maxTeamNameLength = 20;

  List<int> serialize(FantasyMatchupDisplayData data) {
    _validateText('leagueName', data.leagueName, maxLeagueNameLength);
    _validateText('userName', data.userName, maxTeamNameLength);
    _validateText('opponentName', data.opponentName, maxTeamNameLength);
    if (!data.userScore.isFinite ||
        !data.opponentScore.isFinite ||
        data.userScore.abs() > 10000 ||
        data.opponentScore.abs() > 10000) {
      throw const FormatException('Fantasy score is invalid.');
    }
    if (data.week < 1 || data.week > 30) {
      throw const FormatException('Fantasy week must be between 1 and 30.');
    }
    final bytes = utf8.encode(
      jsonEncode({
        'version': 1,
        'type': 'fantasy_matchup',
        'leagueName': data.leagueName,
        'userName': data.userName,
        'userScore': data.userScore,
        'opponentName': data.opponentName,
        'opponentScore': data.opponentScore,
        'week': data.week,
        'status': data.status.wireValue,
      }),
    );
    if (bytes.length > maxPacketBytes) {
      throw const FormatException('Fantasy matchup packet exceeds 512 bytes.');
    }
    return bytes;
  }

  List<int> serializeClear() =>
      utf8.encode(jsonEncode({'version': 1, 'type': 'fantasy_clear'}));

  void _validateText(String field, String value, int limit) {
    if (value.trim().isEmpty || value.length > limit) {
      throw FormatException('$field must contain 1-$limit characters.');
    }
  }
}
