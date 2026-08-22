import 'dart:convert';

import 'fantasy_scoring_correlation.dart';

class FantasyAlertPacketSerializer {
  const FantasyAlertPacketSerializer();

  static const version = 1;
  static const packetType = 'fantasy_alert';
  static const maximumPacketBytes = 512;
  static const maximumPlayerBytes = 32;
  static const maximumHeadlineBytes = 32;
  static const maximumTeamNameBytes = 20;

  List<int> serialize(
    FantasyScoringEvent event, {
    required String userName,
    required double userScore,
    required String opponentName,
    required double opponentScore,
  }) {
    final packet = utf8.encode(
      jsonEncode({
        'version': version,
        'type': packetType,
        'player': _truncateUtf8(
          event.player?.fullName ?? event.delta.playerId,
          maximumPlayerBytes,
        ),
        'headline': _truncateUtf8(
          event.explanation ?? '',
          maximumHeadlineBytes,
        ),
        // Sleeper's FantasyPointDelta is the authoritative points source.
        'points': event.delta.delta,
        'userName': _truncateUtf8(userName, maximumTeamNameBytes),
        'userScore': userScore,
        'opponentName': _truncateUtf8(opponentName, maximumTeamNameBytes),
        'opponentScore': opponentScore,
        'confidence': event.confidence.name,
      }),
    );
    if (packet.length > maximumPacketBytes) {
      throw StateError(
        'Fantasy alert is ${packet.length} bytes; maximum is '
        '$maximumPacketBytes.',
      );
    }
    return packet;
  }
}

String formatFantasyAlertPoints(double points) {
  final hundredths = (points * 100).round();
  final hasMeaningfulHundredths = hundredths % 10 != 0;
  final value = points.toStringAsFixed(hasMeaningfulHundredths ? 2 : 1);
  return '${points >= 0 ? '+' : ''}$value';
}

String _truncateUtf8(String value, int maximumBytes) {
  final bytes = utf8.encode(value.trim());
  if (bytes.length <= maximumBytes) return value.trim();
  var end = maximumBytes;
  while (end > 0) {
    try {
      return utf8.decode(bytes.sublist(0, end));
    } on FormatException {
      end--;
    }
  }
  return '';
}
