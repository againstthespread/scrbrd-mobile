import 'game_data.dart';
import 'golf_leaderboard.dart';
import 'fantasy_scoring_correlation.dart';

abstract class DeviceTransport {
  Future<void> sendControlCommand(String command) {
    throw UnsupportedError('Control-command transport is unavailable.');
  }

  Future<void> sendGameData(GameData gameData);

  Future<void> sendGameSlate(List<GameData> games);

  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) {
    throw UnsupportedError('Golf leaderboard transport is unavailable.');
  }

  Future<void> sendFantasyAlert(
    FantasyScoringEvent event, {
    required String userName,
    required double userScore,
    required String opponentName,
    required double opponentScore,
  }) {
    throw UnsupportedError('Fantasy-alert transport is unavailable.');
  }
}
