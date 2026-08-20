import 'game_data.dart';
import 'golf_leaderboard.dart';

abstract class DeviceTransport {
  Future<void> sendGameData(GameData gameData);

  Future<void> sendGameSlate(List<GameData> games);

  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) {
    throw UnsupportedError('Golf leaderboard transport is unavailable.');
  }
}
