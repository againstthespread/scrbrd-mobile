import 'dart:convert';

import 'device_transport.dart';
import 'game_data.dart';
import 'game_packet_serializer.dart';
import 'golf_leaderboard.dart';
import 'golf_packet_serializer.dart';

class ConsoleDeviceTransport implements DeviceTransport {
  const ConsoleDeviceTransport({
    this.serializer = const GamePacketSerializer(),
  });

  final GamePacketSerializer serializer;

  @override
  Future<void> sendControlCommand(String command) async {
    // ignore: avoid_print
    print(command);
  }

  @override
  Future<void> sendGameData(GameData gameData) async {
    final packetBytes = serializer.serialize(gameData);
    // ignore: avoid_print
    print(utf8.decode(packetBytes));
  }

  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    final transfer = serializer.buildChunkedSlateTransfer(
      games,
      slateId: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
    );
    for (final packetBytes in transfer.packets) {
      // ignore: avoid_print
      print(utf8.decode(packetBytes));
    }
  }

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {
    final transfer = const GolfPacketSerializer().buildTransfer(
      leaderboard,
      transferId: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
    );
    for (final packet in [
      transfer.startPacket,
      ...transfer.chunkPackets,
      transfer.endPacket,
    ]) {
      // ignore: avoid_print
      print(utf8.decode(packet));
    }
  }
}
