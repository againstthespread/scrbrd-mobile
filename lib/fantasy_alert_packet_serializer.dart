import 'dart:convert';

import 'fantasy_point_alert.dart';
import 'utf8_display_text.dart';

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
        'player': truncateUtf8DisplayText(
          alert.player?.fullName ?? alert.delta.playerId,
          maximumPlayerBytes,
        ),
        'headline': '',
        'points': alert.delta.delta,
        'userName': truncateUtf8DisplayText(
          alert.userName,
          maximumTeamNameBytes,
        ),
        'userScore': alert.userScore,
        'opponentName': truncateUtf8DisplayText(
          alert.opponentName,
          maximumTeamNameBytes,
        ),
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
