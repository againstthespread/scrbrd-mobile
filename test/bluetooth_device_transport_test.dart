import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:sports_hub_mobile/ble_device_state.dart';
import 'package:sports_hub_mobile/bluetooth_device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/session_aware_device_sender.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_hub_ble_protocol.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  test('sending remains a physically connected BLE state', () {
    expect(BleConnectionState.connected.isPhysicallyConnected, isTrue);
    expect(BleConnectionState.sending.isPhysicallyConnected, isTrue);
    expect(BleConnectionState.disconnected.isPhysicallyConnected, isFalse);
  });

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
    expect(
      protocol.wakeCharacteristicUuid.toString(),
      'd8f6a9b2-7a5e-4e8c-9f2a-2b2f5b6c1001',
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

  test(
    'connected write transitions connected to sending to connected',
    () async {
      final harness = await _WriteHarness.create();
      final states = <BleConnectionState>[];
      final subscription = harness.transport.snapshots.listen(
        (snapshot) => states.add(snapshot.state),
      );

      final send = harness.transport.sendControlCommand('PING');
      await Future<void>.delayed(Duration.zero);
      expect(
        harness.transport.currentSnapshot.state,
        BleConnectionState.sending,
      );
      harness.completeWrite(0);
      await send;
      await Future<void>.delayed(Duration.zero);

      expect(states, [
        BleConnectionState.sending,
        BleConnectionState.connected,
      ]);
      await subscription.cancel();
      await harness.dispose();
    },
  );

  test(
    'physical disconnect wins over stale in-flight write completion',
    () async {
      final harness = await _WriteHarness.create();
      final states = <BleConnectionState>[];
      final subscription = harness.transport.snapshots.listen(
        (snapshot) => states.add(snapshot.state),
      );

      final send = harness.transport.sendControlCommand('PING');
      await Future<void>.delayed(Duration.zero);
      harness.physicalDisconnect();
      await Future<void>.delayed(Duration.zero);
      harness.completeWrite(0);
      await send;

      expect(
        harness.transport.currentSnapshot.state,
        BleConnectionState.disconnected,
      );
      expect(states, [
        BleConnectionState.sending,
        BleConnectionState.disconnected,
      ]);
      await expectLater(
        harness.transport.sendControlCommand('SECOND'),
        throwsA(isA<StateError>()),
      );
      await subscription.cancel();
      await harness.dispose();
    },
  );

  test(
    'explicit disconnect wins over stale in-flight write completion',
    () async {
      final harness = await _WriteHarness.create();
      final send = harness.transport.sendControlCommand('PING');
      await Future<void>.delayed(Duration.zero);

      await harness.transport.disconnect();
      harness.completeWrite(0);
      await send;

      expect(
        harness.transport.currentSnapshot.state,
        BleConnectionState.disconnected,
      );
      await expectLater(
        harness.transport.sendControlCommand('SECOND'),
        throwsA(isA<StateError>()),
      );
      await harness.dispose();
    },
  );

  test('later physical reconnect uses the new generation normally', () async {
    final harness = await _WriteHarness.create();
    final staleSend = harness.transport.sendControlCommand('OLD');
    await Future<void>.delayed(Duration.zero);
    harness.physicalDisconnect();
    await Future<void>.delayed(Duration.zero);
    harness.completeWrite(0);
    await staleSend;

    harness.physicalReconnect();
    await Future<void>.delayed(Duration.zero);
    expect(
      harness.transport.currentSnapshot.state,
      BleConnectionState.connected,
    );
    final freshSend = harness.transport.sendControlCommand('NEW');
    await Future<void>.delayed(Duration.zero);
    harness.completeWrite(1);
    await freshSend;

    expect(
      harness.transport.currentSnapshot.state,
      BleConnectionState.connected,
    );
    expect(harness.writeCount, 2);
    await harness.dispose();
  });

  test(
    'disconnect during slate transfer fails without advancing baseline',
    () async {
      final harness = await _WriteHarness.create();
      final session = TrackedDeviceSession()
        ..recordTeamSlate(
          league: SportsLeague.mlb,
          selectedDate: _date,
          games: [_game(score: 1)],
        );
      final sender = SessionAwareDeviceSender(
        transport: harness.transport,
        session: session,
      );

      final transfer = sender.sendTeamSlate([
        _game(score: 2),
      ], selectedDate: _date);
      await Future<void>.delayed(Duration.zero);
      harness.physicalDisconnect();
      await Future<void>.delayed(Duration.zero);
      harness.completeWrite(0);

      await expectLater(transfer, throwsA(isA<StateError>()));
      expect(harness.writeCount, 1);
      expect(
        (session[SportsLeague.mlb] as TrackedTeamSlate).games.single.awayScore,
        1,
      );
      session.dispose();
      await harness.dispose();
    },
  );

  test(
    'disconnect during PGA transfer fails without advancing baseline',
    () async {
      final harness = await _WriteHarness.create();
      final session = TrackedDeviceSession()..recordGolf(_golf('-1'));
      final sender = SessionAwareDeviceSender(
        transport: harness.transport,
        session: session,
      );

      final transfer = sender.sendGolf(_golf('-2'), selectedDate: _date);
      await Future<void>.delayed(Duration.zero);
      harness.physicalDisconnect();
      await Future<void>.delayed(Duration.zero);
      harness.completeWrite(0);

      await expectLater(transfer, throwsA(isA<StateError>()));
      expect(harness.writeCount, 1);
      expect(
        (session[SportsLeague.pga] as TrackedGolfLeaderboard)
            .leaderboard
            .golfers
            .single
            .score,
        '-1',
      );
      session.dispose();
      await harness.dispose();
    },
  );

  test('first scan waits for BLE readiness and finds candidate', () async {
    final status = StreamController<BleStatus>();
    final scan = StreamController<DiscoveredDevice>();
    var scanStarts = 0;
    final transport = BluetoothDeviceTransport(
      scanTimeout: const Duration(milliseconds: 40),
      bleStatusProvider: () => BleStatus.unknown,
      bleStatusStreamProvider: () => status.stream,
      scanStreamProvider: () {
        scanStarts++;
        return scan.stream;
      },
    );

    final attempt = transport.scanForDevice();
    await Future<void>.delayed(Duration.zero);
    expect(scanStarts, 0);
    status.add(BleStatus.ready);
    await Future<void>.delayed(Duration.zero);
    scan.add(_device('first'));
    await Future<void>.delayed(Duration.zero);

    expect(scanStarts, 1);
    expect(transport.currentSnapshot.candidates.single.id, 'first');
    await attempt;
    expect(transport.currentSnapshot.candidates.single.id, 'first');
    expect(transport.currentSnapshot.errorMessage, isNull);
    await status.close();
    await scan.close();
    await transport.dispose();
  });

  test('candidate survives scan timeout completion', () async {
    final harness = _ScanHarness();
    final attempt = harness.transport.scanForDevice();
    await Future<void>.delayed(Duration.zero);
    harness.scan.add(_device('candidate'));
    await attempt;

    expect(
      harness.transport.currentSnapshot.state,
      BleConnectionState.disconnected,
    );
    expect(harness.transport.currentSnapshot.candidates.single.id, 'candidate');
    expect(harness.transport.currentSnapshot.errorMessage, isNull);
    await harness.dispose();
  });

  test('candidate discovered near timeout boundary is retained', () async {
    final harness = _ScanHarness(timeout: const Duration(milliseconds: 50));
    final attempt = harness.transport.scanForDevice();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    harness.scan.add(_device('near-timeout'));
    await attempt;

    expect(
      harness.transport.currentSnapshot.candidates.single.id,
      'near-timeout',
    );
    expect(harness.transport.currentSnapshot.errorMessage, isNull);
    await harness.dispose();
  });

  test('truly empty first scan reports friendly no-device result', () async {
    final harness = _ScanHarness();
    await harness.transport.scanForDevice();

    expect(harness.transport.currentSnapshot.candidates, isEmpty);
    expect(harness.transport.currentSnapshot.errorMessage, 'No SCRBRD found.');
    await harness.dispose();
  });

  test('first discovered candidate is immediately actionable', () async {
    final harness = _ScanHarness(connect: true);
    final attempt = harness.transport.scanForDevice();
    await Future<void>.delayed(Duration.zero);
    harness.scan.add(_device('actionable'));
    await Future<void>.delayed(Duration.zero);
    final candidate = harness.transport.currentSnapshot.candidates.single;

    await harness.transport.connectToDevice(candidate);

    expect(harness.connectionAttempts, 1);
    expect(
      harness.transport.currentSnapshot.state,
      BleConnectionState.connected,
    );
    await attempt;
    await harness.dispose();
  });

  test('multiple candidates from the first scan remain selectable', () async {
    final harness = _ScanHarness();
    final attempt = harness.transport.scanForDevice();
    await Future<void>.delayed(Duration.zero);
    harness.scan.add(_device('one'));
    harness.scan.add(_device('two'));
    await Future<void>.delayed(Duration.zero);

    expect(
      harness.transport.currentSnapshot.candidates.map((value) => value.id),
      ['one', 'two'],
    );
    await attempt;
    await harness.dispose();
  });
}

class _ScanHarness {
  _ScanHarness({
    Duration timeout = const Duration(milliseconds: 30),
    bool connect = false,
  }) {
    transport = BluetoothDeviceTransport(
      scanTimeout: timeout,
      bleStatusProvider: () => BleStatus.ready,
      scanStreamProvider: () => scan.stream,
      connectionStreamProvider: connect
          ? ({
              required id,
              required servicesWithCharacteristicsToDiscover,
              required connectionTimeout,
            }) {
              connectionAttempts++;
              return Stream.value(
                ConnectionStateUpdate(
                  deviceId: id,
                  connectionState: DeviceConnectionState.connected,
                  failure: null,
                ),
              );
            }
          : null,
      wakeStreamProvider: (_) => const Stream.empty(),
    );
  }

  final scan = StreamController<DiscoveredDevice>.broadcast();
  late final BluetoothDeviceTransport transport;
  int connectionAttempts = 0;

  Future<void> dispose() async {
    await transport.dispose();
    await scan.close();
  }
}

class _WriteHarness {
  _WriteHarness._() {
    transport = BluetoothDeviceTransport(
      scanTimeout: const Duration(milliseconds: 10),
      bleStatusProvider: () => BleStatus.ready,
      scanStreamProvider: () => scan.stream,
      connectionStreamProvider:
          ({
            required id,
            required servicesWithCharacteristicsToDiscover,
            required connectionTimeout,
          }) => connection.stream,
      wakeStreamProvider: (_) => const Stream.empty(),
      writeWithResponse: (characteristic, {required value}) {
        final completion = Completer<void>();
        writes.add(completion);
        return completion.future;
      },
    );
  }

  static Future<_WriteHarness> create() async {
    final harness = _WriteHarness._();
    final scanAttempt = harness.transport.scanForDevice();
    await Future<void>.delayed(Duration.zero);
    harness.scan.add(_device('write-device'));
    await scanAttempt;
    final connectAttempt = harness.transport.connectToDevice(
      harness.transport.currentSnapshot.candidates.single,
    );
    await Future<void>.delayed(Duration.zero);
    harness.physicalReconnect();
    await connectAttempt;
    return harness;
  }

  final scan = StreamController<DiscoveredDevice>.broadcast();
  final connection = StreamController<ConnectionStateUpdate>.broadcast();
  final writes = <Completer<void>>[];
  late final BluetoothDeviceTransport transport;

  int get writeCount => writes.length;

  void completeWrite(int index) => writes[index].complete();

  void physicalDisconnect() {
    connection.add(
      const ConnectionStateUpdate(
        deviceId: 'write-device',
        connectionState: DeviceConnectionState.disconnected,
        failure: null,
      ),
    );
  }

  void physicalReconnect() {
    connection.add(
      const ConnectionStateUpdate(
        deviceId: 'write-device',
        connectionState: DeviceConnectionState.connected,
        failure: null,
      ),
    );
  }

  Future<void> dispose() async {
    await transport.dispose();
    await scan.close();
    await connection.close();
  }
}

final _date = DateTime(2026, 8, 22);

GameData _game({required int score}) => GameData(
  eventId: 'mlb-1',
  league: 'MLB',
  awayTeam: 'NYY',
  homeTeam: 'BOS',
  awayScore: score,
  homeScore: 0,
  status: 'LIVE',
  clock: 'Top 5th',
  scheduledStartTime: _date,
);

GolfLeaderboard _golf(String score) => GolfLeaderboard(
  tournamentId: 'pga-1',
  tournamentName: 'Test Open',
  golfers: [
    GolfLeaderboardRow(
      playerId: 'golfer-1',
      name: 'Golfer One',
      rank: '1',
      score: score,
      detail: 'THRU 5',
    ),
  ],
  isInProgress: true,
  isOver: false,
);

DiscoveredDevice _device(String id) => DiscoveredDevice(
  id: id,
  name: SportsHubBleProtocol.advertisingName,
  serviceData: const {},
  manufacturerData: Uint8List(0),
  rssi: -45,
  serviceUuids: const [],
);

class _TestBleProtocol extends SportsHubBleProtocol {
  const _TestBleProtocol();

  @override
  Uuid get serviceUuid => Uuid.parse('00000000-0000-1000-8000-00805f9b34fb');

  @override
  Uuid get writableCharacteristicUuid =>
      Uuid.parse('00000001-0000-1000-8000-00805f9b34fb');

  @override
  Uuid get wakeCharacteristicUuid =>
      Uuid.parse('00000002-0000-1000-8000-00805f9b34fb');
}
