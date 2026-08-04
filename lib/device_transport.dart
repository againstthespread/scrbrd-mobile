import 'game_data.dart';

abstract class DeviceTransport {
  Future<void> sendGameData(GameData gameData);
}
