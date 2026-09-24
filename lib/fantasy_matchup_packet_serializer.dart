import 'dart:convert';

import 'fantasy_matchup_display_data.dart';
import 'utf8_display_text.dart';

class FantasyMatchupPacketSerializer {
  const FantasyMatchupPacketSerializer();

  static const maxPacketBytes = 512;
  static const maxLeagueNameLength = 48;
  static const maxTeamNameLength = 20;

  List<int> serialize(FantasyMatchupDisplayData data, {String? identity}) {
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
    for (final projection in [
      data.userProjectedScore,
      data.opponentProjectedScore,
    ]) {
      if (projection != null &&
          (!projection.isFinite || projection.abs() > 10000)) {
        throw const FormatException('Fantasy projection is invalid.');
      }
    }
    if (data.week < 1 || data.week > 30) {
      throw const FormatException('Fantasy week must be between 1 and 30.');
    }
    final packet = <String, Object?>{
      'version': 1,
      'type': 'fantasy_matchup',
      'leagueName': leagueName,
      'userName': userName,
      'userScore': data.userScore,
      'opponentName': opponentName,
      'opponentScore': data.opponentScore,
      if (data.userProjectedScore != null)
        'userProjectedScore': data.userProjectedScore,
      if (data.opponentProjectedScore != null)
        'opponentProjectedScore': data.opponentProjectedScore,
      'week': data.week,
      'status': data.status.wireValue,
    };
    if (identity != null) packet['identity'] = identity;
    final bytes = utf8.encode(jsonEncode(packet));
    if (bytes.length > maxPacketBytes) {
      throw const FormatException('Fantasy matchup packet exceeds 512 bytes.');
    }
    return bytes;
  }

  List<int> serializeClear() =>
      utf8.encode(jsonEncode({'version': 1, 'type': 'fantasy_clear'}));

  List<int> serializeSlateStart() =>
      utf8.encode(jsonEncode({'version': 1, 'type': 'fantasy_slate_start'}));

  List<int> serializeSlateEnd() =>
      utf8.encode(jsonEncode({'version': 1, 'type': 'fantasy_slate_end'}));

  void _validateText(String field, String value) {
    if (value.isEmpty) {
      throw FormatException('$field must not be empty.');
    }
  }
}
