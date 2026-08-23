import 'dart:convert';

import 'fantasy_matchup_display_data.dart';
import 'utf8_display_text.dart';

class FantasyMatchupPacketSerializer {
  const FantasyMatchupPacketSerializer();

  static const maxPacketBytes = 512;
  static const maxLeagueNameLength = 48;
  static const maxTeamNameLength = 20;

  List<int> serialize(FantasyMatchupDisplayData data) {
    final leagueName = truncateUtf8DisplayText(
      data.leagueName,
      maxLeagueNameLength,
    );
    final userName = truncateUtf8DisplayText(data.userName, maxTeamNameLength);
    final opponentName = truncateUtf8DisplayText(
      data.opponentName,
      maxTeamNameLength,
    );
    _validateText('leagueName', leagueName);
    _validateText('userName', userName);
    _validateText('opponentName', opponentName);
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
        'leagueName': leagueName,
        'userName': userName,
        'userScore': data.userScore,
        'opponentName': opponentName,
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

  void _validateText(String field, String value) {
    if (value.isEmpty) {
      throw FormatException('$field must not be empty.');
    }
  }
}
