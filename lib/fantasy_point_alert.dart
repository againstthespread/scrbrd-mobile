import 'fantasy_point_delta_tracker.dart';
import 'sleeper_models.dart';

class FantasyPointAlert {
  const FantasyPointAlert({
    required this.delta,
    required this.player,
    required this.userName,
    required this.userScore,
    required this.opponentName,
    required this.opponentScore,
    this.playerName,
    this.canonicalPlayerId,
    this.headline = '',
  });

  final FantasyPointDelta delta;
  final SleeperFantasyPlayer? player;
  final String userName;
  final double userScore;
  final String opponentName;
  final double opponentScore;
  final String? playerName;

  /// Stable real-world entity identity used only for delivery aggregation.
  final String? canonicalPlayerId;
  final String headline;
}
