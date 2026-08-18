import 'game_data.dart';

abstract class DeviceTransport {
  Future<void> sendGameData(GameData gameData);

  Future<void> sendGameSlate(List<GameData> games);
}
