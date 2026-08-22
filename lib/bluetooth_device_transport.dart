import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'ble_device_state.dart';
import 'device_transport.dart';
import 'game_data.dart';
import 'game_packet_serializer.dart';
import 'golf_leaderboard.dart';
import 'golf_packet_serializer.dart';
import 'sports_hub_ble_protocol.dart';

typedef BleScanStreamFactory = Stream<DiscoveredDevice> Function();
typedef BleConnectionStreamFactory =
    Stream<ConnectionStateUpdate> Function({
      required String id,
      required Map<Uuid, List<Uuid>> servicesWithCharacteristicsToDiscover,
      required Duration connectionTimeout,
    });
typedef BleWakeStreamFactory =
    Stream<List<int>> Function(QualifiedCharacteristic characteristic);

class BluetoothDeviceTransport implements DeviceTransport {
  BluetoothDeviceTransport({
    this.protocol = const SportsHubBleProtocol(),
    this.serializer = const GamePacketSerializer(),
    this.golfSerializer = const GolfPacketSerializer(),
    this.scanTimeout = const Duration(seconds: 8),
    this.bleReadyTimeout = const Duration(seconds: 4),
    this.bleStatusProvider,
    this.bleStatusStreamProvider,
    this.scanStreamProvider,
    this.connectionStreamProvider,
    this.wakeStreamProvider,
  });

  final SportsHubBleProtocol protocol;
  final GamePacketSerializer serializer;
  final GolfPacketSerializer golfSerializer;
  final Duration scanTimeout;
  final Duration bleReadyTimeout;
  final BleStatus Function()? bleStatusProvider;
  final Stream<BleStatus> Function()? bleStatusStreamProvider;
  final BleScanStreamFactory? scanStreamProvider;
  final BleConnectionStreamFactory? connectionStreamProvider;
  final BleWakeStreamFactory? wakeStreamProvider;
  FlutterReactiveBle? _ble;

  final _snapshotController = StreamController<BleDeviceSnapshot>.broadcast();
  // TEMPORARY BLE WAKE-NOTIFICATION EXPERIMENT: Remove after iOS testing.
  final _wakeNotificationController = StreamController<List<int>>.broadcast();
  final _devicesById = <String, DiscoveredDevice>{};

  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  StreamSubscription<List<int>>? _wakeNotificationSubscription;
  QualifiedCharacteristic? _writableCharacteristic;
  BleDeviceSnapshot _snapshot = const BleDeviceSnapshot(
    state: BleConnectionState.disconnected,
  );
  bool _isWriting = false;
  int _scanGeneration = 0;

  Stream<BleDeviceSnapshot> get snapshots => _snapshotController.stream;

  // TEMPORARY BLE WAKE-NOTIFICATION EXPERIMENT: Remove after iOS testing.
  Stream<List<int>> get wakeNotifications => _wakeNotificationController.stream;

  BleDeviceSnapshot get currentSnapshot => _snapshot;

  Future<void> scanForDevice() async {
    await disconnect();
    final generation = _scanGeneration;

    _emit(
      const BleDeviceSnapshot(
        state: BleConnectionState.scanning,
        candidates: [],
      ),
    );
    debugPrint('BLE scan started');

    if (!await _waitForBleReady() || generation != _scanGeneration) return;

    _scanSubscription = _scanForDevices().listen(
      (device) {
        if (generation == _scanGeneration) {
          _handleDiscoveredDevice(device);
        }
      },
      onError: (Object error) {
        if (generation == _scanGeneration) {
          _emitError('Bluetooth scan failed: $error');
        }
      },
    );

    await Future<void>.delayed(scanTimeout);

    if (generation == _scanGeneration &&
        _snapshot.state == BleConnectionState.scanning) {
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      final candidateCount = _devicesById.length;
      debugPrint('BLE scan completed; candidates=$candidateCount');
      _emit(
        _snapshot.copyWith(
          state: BleConnectionState.disconnected,
          errorMessage: candidateCount == 0 ? 'No SCRBRD found.' : null,
          clearError: candidateCount > 0,
        ),
      );
    }
  }

  Future<void> connectToDevice(BleDeviceCandidate candidate) async {
    final discoveredDevice = _devicesById[candidate.id];
    if (discoveredDevice == null) {
      _emitError('Selected Sports Hub device is no longer available.');
      return;
    }

    await _scanSubscription?.cancel();
    _scanSubscription = null;
    _emit(
      _snapshot.copyWith(
        state: BleConnectionState.connecting,
        deviceName: candidate.name,
        clearError: true,
      ),
    );

    final serviceUuid = _tryReadServiceUuid();
    final characteristicUuid = _tryReadWritableCharacteristicUuid();
    final wakeCharacteristicUuid = _tryReadWakeCharacteristicUuid();
    if (serviceUuid == null ||
        characteristicUuid == null ||
        wakeCharacteristicUuid == null) {
      return;
    }

    final completer = Completer<void>();
    _connectionSubscription =
        _connectToDevice(
          id: discoveredDevice.id,
          servicesWithCharacteristicsToDiscover: {
            serviceUuid: [characteristicUuid, wakeCharacteristicUuid],
          },
          connectionTimeout: const Duration(seconds: 12),
        ).listen(
          (update) {
            if (update.connectionState == DeviceConnectionState.connected) {
              _writableCharacteristic = QualifiedCharacteristic(
                serviceId: serviceUuid,
                characteristicId: characteristicUuid,
                deviceId: discoveredDevice.id,
              );
              _startWakeNotificationSubscription(
                QualifiedCharacteristic(
                  serviceId: serviceUuid,
                  characteristicId: wakeCharacteristicUuid,
                  deviceId: discoveredDevice.id,
                ),
              );
              _emit(
                _snapshot.copyWith(
                  state: BleConnectionState.connected,
                  deviceName: candidate.name,
                  clearError: true,
                ),
              );
              if (!completer.isCompleted) {
                completer.complete();
              }
            } else if (update.connectionState ==
                DeviceConnectionState.disconnected) {
              unawaited(_cancelWakeNotificationSubscription());
              _writableCharacteristic = null;
              _emit(
                _snapshot.copyWith(
                  state: BleConnectionState.disconnected,
                  deviceName: null,
                ),
              );
            }
          },
          onError: (Object error) {
            _emitError('Bluetooth connection failed: $error');
            if (!completer.isCompleted) {
              completer.complete();
            }
          },
        );

    await completer.future.timeout(
      const Duration(seconds: 14),
      onTimeout: () {
        _emitError('Bluetooth connection timed out.');
      },
    );
  }

  Future<void> disconnect() async {
    _scanGeneration++;
    await _scanSubscription?.cancel();
    await _connectionSubscription?.cancel();
    await _cancelWakeNotificationSubscription();
    _scanSubscription = null;
    _connectionSubscription = null;
    _writableCharacteristic = null;
    _isWriting = false;
    _devicesById.clear();
    _emit(const BleDeviceSnapshot(state: BleConnectionState.disconnected));
  }

  @override
  Future<void> sendControlCommand(String command) async {
    await _sendPacket(utf8.encode(command));
  }

  @override
  Future<void> sendGameData(GameData gameData) async {
    await _sendPacket(serializer.serialize(gameData));
  }

  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    final slateId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final transfer = serializer.buildChunkedSlateTransfer(
      games,
      slateId: slateId,
    );
    debugPrint(
      'Slate transfer start: id=${transfer.slateId}, '
      'games=${games.length}, chunks=${transfer.chunkPackets.length}',
    );
    try {
      await _sendPacket(transfer.startPacket);
      for (var index = 0; index < transfer.chunkPackets.length; index++) {
        final chunk = transfer.chunkPackets[index];
        debugPrint('Slate transfer chunk: index=$index, bytes=${chunk.length}');
        await _sendPacket(chunk);
      }
      await _sendPacket(transfer.endPacket);
      debugPrint('Slate transfer complete: id=${transfer.slateId}');
    } on Object catch (error) {
      debugPrint('Slate transfer failed: id=${transfer.slateId}, error=$error');
      throw StateError('Slate transfer failed: $error');
    }
  }

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {
    final transferId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final transfer = golfSerializer.buildTransfer(
      leaderboard,
      transferId: transferId,
    );
    debugPrint(
      'Golf transfer start: tournament=${leaderboard.tournamentId}, '
      'golfers=${leaderboard.golfers.length}, chunks=${transfer.chunkPackets.length}',
    );
    try {
      await _sendPacket(transfer.startPacket);
      for (var index = 0; index < transfer.chunkPackets.length; index++) {
        final packet = transfer.chunkPackets[index];
        debugPrint('Golf chunk: index=$index, bytes=${packet.length}');
        await _sendPacket(packet);
      }
      await _sendPacket(transfer.endPacket);
      debugPrint(
        'Golf transfer complete: tournament=${leaderboard.tournamentId}',
      );
    } on Object catch (error) {
      debugPrint(
        'Golf transfer failed: tournament=${leaderboard.tournamentId}; $error',
      );
      throw StateError('Golf transfer failed: $error');
    }
  }

  Future<void> _sendPacket(List<int> packet) async {
    final characteristic = _writableCharacteristic;
    if (characteristic == null ||
        _snapshot.state == BleConnectionState.disconnected ||
        _snapshot.state == BleConnectionState.error) {
      throw StateError('Sports Hub is not connected.');
    }

    if (_isWriting || _snapshot.state == BleConnectionState.sending) {
      throw StateError('A Sports Hub packet is already being sent.');
    }

    _isWriting = true;
    final previousSnapshot = _snapshot;
    _emit(_snapshot.copyWith(state: BleConnectionState.sending));

    try {
      await _bleClient.writeCharacteristicWithResponse(
        characteristic,
        value: packet,
      );
      _emit(previousSnapshot.copyWith(state: BleConnectionState.connected));
    } on Object catch (error) {
      _emitError('Bluetooth write failed: $error');
      rethrow;
    } finally {
      _isWriting = false;
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _wakeNotificationController.close();
    await _snapshotController.close();
  }

  FlutterReactiveBle get _bleClient {
    return _ble ??= FlutterReactiveBle();
  }

  Stream<DiscoveredDevice> _scanForDevices() =>
      scanStreamProvider?.call() ??
      _bleClient.scanForDevices(withServices: const []);

  Stream<ConnectionStateUpdate> _connectToDevice({
    required String id,
    required Map<Uuid, List<Uuid>> servicesWithCharacteristicsToDiscover,
    required Duration connectionTimeout,
  }) =>
      connectionStreamProvider?.call(
        id: id,
        servicesWithCharacteristicsToDiscover:
            servicesWithCharacteristicsToDiscover,
        connectionTimeout: connectionTimeout,
      ) ??
      _bleClient.connectToDevice(
        id: id,
        servicesWithCharacteristicsToDiscover:
            servicesWithCharacteristicsToDiscover,
        connectionTimeout: connectionTimeout,
      );

  Future<bool> _waitForBleReady() async {
    var status = bleStatusProvider?.call() ?? _bleClient.status;
    if (status == BleStatus.ready) return true;
    try {
      status =
          await (bleStatusStreamProvider?.call() ?? _bleClient.statusStream)
              .firstWhere((value) => value != BleStatus.unknown)
              .timeout(bleReadyTimeout);
    } on TimeoutException {
      _emitError('Bluetooth is not ready. Try again.');
      return false;
    }
    if (status == BleStatus.ready) return true;
    final message = switch (status) {
      BleStatus.poweredOff => 'Turn on Bluetooth to connect to SCRBRD.',
      BleStatus.unauthorized => 'Allow Bluetooth access to connect to SCRBRD.',
      BleStatus.unsupported => 'Bluetooth is not supported on this device.',
      BleStatus.locationServicesDisabled =>
        'Enable location services to search for SCRBRD.',
      BleStatus.unknown ||
      BleStatus.ready => 'Bluetooth is not ready. Try again.',
    };
    _emitError(message);
    return false;
  }

  void _handleDiscoveredDevice(DiscoveredDevice device) {
    final name = device.name.trim();
    final matchesName = name == SportsHubBleProtocol.advertisingName;
    final serviceUuid = _safeReadServiceUuid();
    final matchesService =
        serviceUuid != null && device.serviceUuids.contains(serviceUuid);

    if (!matchesName && !matchesService) {
      return;
    }

    _devicesById[device.id] = device;
    debugPrint('SCRBRD candidate discovered: ${device.id}');
    final candidates = _devicesById.values.map((device) {
      final displayName = device.name.trim().isEmpty
          ? SportsHubBleProtocol.advertisingName
          : device.name.trim();
      return BleDeviceCandidate(id: device.id, name: displayName);
    }).toList();

    _emit(_snapshot.copyWith(candidates: candidates, clearError: true));
  }

  Uuid? _tryReadServiceUuid() {
    try {
      return protocol.serviceUuid;
    } on StateError catch (error) {
      _emitError(error.message);
      return null;
    }
  }

  Uuid? _safeReadServiceUuid() {
    try {
      return protocol.serviceUuid;
    } on StateError {
      return null;
    }
  }

  Uuid? _tryReadWritableCharacteristicUuid() {
    try {
      return protocol.writableCharacteristicUuid;
    } on StateError catch (error) {
      _emitError(error.message);
      return null;
    }
  }

  // TEMPORARY BLE WAKE-NOTIFICATION EXPERIMENT: Remove after iOS testing.
  Uuid? _tryReadWakeCharacteristicUuid() {
    try {
      return protocol.wakeCharacteristicUuid;
    } on StateError catch (error) {
      _emitError(error.message);
      return null;
    }
  }

  // TEMPORARY BLE WAKE-NOTIFICATION EXPERIMENT: Remove after iOS testing.
  void _startWakeNotificationSubscription(
    QualifiedCharacteristic characteristic,
  ) {
    unawaited(_wakeNotificationSubscription?.cancel());
    _wakeNotificationSubscription =
        (wakeStreamProvider?.call(characteristic) ??
                _bleClient.subscribeToCharacteristic(characteristic))
            .listen(
              (value) {
                debugPrint(
                  'TEMP BLE WAKE EXPERIMENT: wake notification received; '
                  'bytes=$value',
                );
                if (!_wakeNotificationController.isClosed) {
                  _wakeNotificationController.add(value);
                }
              },
              onError: (Object error) {
                debugPrint(
                  'TEMP BLE WAKE EXPERIMENT: wake notification subscription '
                  'failed: $error',
                );
              },
              onDone: () {
                debugPrint(
                  'TEMP BLE WAKE EXPERIMENT: wake subscription cancelled',
                );
              },
            );
    debugPrint('TEMP BLE WAKE EXPERIMENT: wake subscription started');
  }

  // TEMPORARY BLE WAKE-NOTIFICATION EXPERIMENT: Remove after iOS testing.
  Future<void> _cancelWakeNotificationSubscription() async {
    final subscription = _wakeNotificationSubscription;
    _wakeNotificationSubscription = null;
    if (subscription == null) {
      return;
    }

    await subscription.cancel();
    debugPrint('TEMP BLE WAKE EXPERIMENT: wake subscription cancelled');
  }

  void _emitError(String message) {
    _emit(
      _snapshot.copyWith(
        state: BleConnectionState.error,
        errorMessage: message,
      ),
    );
  }

  void _emit(BleDeviceSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }
}
