import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:sports_hub_mobile/bluetooth_device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/sports_hub_ble_protocol.dart';

void main() {
  test('protocol UUIDs from SPORTS_HUB_PROTOCOL.md parse correctly', () {
    const protocol = SportsHubBleProtocol();

    expect(
      protocol.serviceUuid.toString(),
      'd8f6a9b0-7a5e-4e8c-9f2a-2b2f5b6c1001',
    );
    expect(
      protocol.writableCharacteristicUuid.toString(),
      'd8f6a9b1-7a5e-4e8c-9f2a-2b2f5b6c1001',
    );
  });

  test('valid protocol UUID strings parse without BLE hardware', () {
    const protocol = _TestBleProtocol();

    expect(protocol.serviceUuid, isA<Uuid>());
    expect(protocol.writableCharacteristicUuid, isA<Uuid>());
  });

  test('send rejects while disconnected without BLE hardware', () async {
    final transport = BluetoothDeviceTransport();

    await expectLater(
      transport.sendGameData(
        const GameData(
          league: 'NFL',
          awayTeam: 'BUF',
          homeTeam: 'NE',
          awayScore: 17,
          homeScore: 24,
          status: 'LIVE',
          clock: 'Q4 8:31',
        ),
      ),
      throwsA(isA<StateError>()),
    );

    await transport.dispose();
  });
}

class _TestBleProtocol extends SportsHubBleProtocol {
  const _TestBleProtocol();

  @override
  Uuid get serviceUuid => Uuid.parse('00000000-0000-1000-8000-00805f9b34fb');

  @override
  Uuid get writableCharacteristicUuid =>
      Uuid.parse('00000001-0000-1000-8000-00805f9b34fb');
}
