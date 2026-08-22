import 'dart:convert';

import 'fantasy_point_alert.dart';

class FantasyAlertPacketSerializer {
  const FantasyAlertPacketSerializer();

  static const maximumPacketBytes = 512;
  static const maximumPlayerBytes = 32;
  static const maximumHeadlineBytes = 32;
  static const maximumTeamNameBytes = 20;

  List<int> serialize(FantasyPointAlert alert) {
    final packet = utf8.encode(
      jsonEncode({
        'version': 1,
        'type': 'fantasy_alert',
        'player': _truncateUtf8(
          alert.player?.fullName ?? alert.delta.playerId,
          maximumPlayerBytes,
        ),
        'headline': '',
        'points': alert.delta.delta,
        'userName': _truncateUtf8(alert.userName, maximumTeamNameBytes),
        'userScore': alert.userScore,
        'opponentName': _truncateUtf8(alert.opponentName, maximumTeamNameBytes),
        'opponentScore': alert.opponentScore,
        'confidence': 'none',
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
  final digits = hundredths % 10 == 0 ? 1 : 2;
  return '${points >= 0 ? '+' : ''}${points.toStringAsFixed(digits)}';
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
