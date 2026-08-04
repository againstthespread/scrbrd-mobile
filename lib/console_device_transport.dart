import 'dart:convert';

import 'device_transport.dart';
import 'game_data.dart';
import 'game_packet_serializer.dart';

class ConsoleDeviceTransport implements DeviceTransport {
  const ConsoleDeviceTransport({
    this.serializer = const GamePacketSerializer(),
  });

  final GamePacketSerializer serializer;

  @override
  Future<void> sendGameData(GameData gameData) async {
    final packetBytes = serializer.serialize(gameData);
    // ignore: avoid_print
    print(utf8.decode(packetBytes));
  }
}
