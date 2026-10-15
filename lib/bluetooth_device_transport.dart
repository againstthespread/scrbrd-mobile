import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:reactive_ble_platform_interface/reactive_ble_platform_interface.dart'
    show CharacteristicInstance;

import 'acknowledged_wake_stream.dart';

import 'ble_device_state.dart';
import 'refresh_diagnostic_history.dart';
import 'device_transport.dart';
import 'game_data.dart';
import 'fantasy_alert_packet_serializer.dart';
import 'fantasy_alert_transport.dart';
import 'fantasy_point_alert.dart';
import 'fantasy_matchup_display_data.dart';
import 'fantasy_matchup_packet_serializer.dart';
import 'fantasy_matchup_transport.dart';
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
typedef BleWriteWithResponse =
    Future<void> Function(
      QualifiedCharacteristic characteristic, {
      required List<int> value,
    });

enum WakeSubscriptionHealth {
  inactive,
  subscribing,
  listening,
  receiving,
  retrying,
  failed,
}

class BluetoothDeviceTransport
    implements
        DeviceTransport,
        FantasyAlertTransport,
        FantasyMatchupTransport,
        FantasySlateTransport {
  BluetoothDeviceTransport({
    this.protocol = const SportsHubBleProtocol(),
    this.serializer = const GamePacketSerializer(),
    this.golfSerializer = const GolfPacketSerializer(),
    this.fantasyAlertSerializer = const FantasyAlertPacketSerializer(),
    this.fantasyMatchupSerializer = const FantasyMatchupPacketSerializer(),
    this.scanTimeout = const Duration(seconds: 8),
    this.bleReadyTimeout = const Duration(seconds: 4),
    this.bleStatusProvider,
    this.bleStatusStreamProvider,
    this.scanStreamProvider,
    this.connectionStreamProvider,
    this.wakeStreamProvider,
    this.writeWithResponse,
    this.wakeSilenceTimeout = const Duration(seconds: 75),
    this.wakeCancellationTimeout = const Duration(seconds: 3),
    RefreshDiagnosticHistory? diagnosticHistory,
    List<Duration> wakeRetryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
  }) : wakeRetryDelays = List.unmodifiable(wakeRetryDelays),
       diagnosticHistory =
           diagnosticHistory ?? RefreshDiagnosticHistory.session;

  static int _nextDiagnosticId = 0;
  final int diagnosticId = ++_nextDiagnosticId;
  final RefreshDiagnosticHistory diagnosticHistory;
  int get connectionGeneration => _connectionGeneration;
  int _diagnosticWriteId = 0;

  void _trace(String message) => diagnosticHistory.add(
    message,
    source: 'ble',
    transportId: diagnosticId,
    generation: _connectionGeneration,
  );

  void _setWakeHealth(WakeSubscriptionHealth health) {
    _trace(
      'subscription.health ${_wakeHealth.name}->${health.name}; epoch=$_wakeEpoch',
    );
    _wakeHealth = health;
  }

  final SportsHubBleProtocol protocol;
  final GamePacketSerializer serializer;
  final GolfPacketSerializer golfSerializer;
  final FantasyAlertPacketSerializer fantasyAlertSerializer;
  final FantasyMatchupPacketSerializer fantasyMatchupSerializer;
  final Duration scanTimeout;
  final Duration bleReadyTimeout;
  final BleStatus Function()? bleStatusProvider;
  final Stream<BleStatus> Function()? bleStatusStreamProvider;
  final BleScanStreamFactory? scanStreamProvider;
  final BleConnectionStreamFactory? connectionStreamProvider;
  final BleWakeStreamFactory? wakeStreamProvider;
  final BleWriteWithResponse? writeWithResponse;
  final List<Duration> wakeRetryDelays;
  final Duration wakeSilenceTimeout;
  final Duration wakeCancellationTimeout;
  FlutterReactiveBle? _ble;

  final _snapshotController = StreamController<BleDeviceSnapshot>.broadcast();
  // BLE WAKE notifications trigger the connected app's refresh path.
  final _wakeNotificationController = StreamController<List<int>>.broadcast();
  final _devicesById = <String, DiscoveredDevice>{};

  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  StreamSubscription<List<int>>? _wakeNotificationSubscription;
  QualifiedCharacteristic? _writableCharacteristic;
  QualifiedCharacteristic? _wakeCharacteristic;
  Timer? _wakeRetryTimer;
  Timer? _wakeSilenceTimer;
  bool _wakeForeground = true;
  int? _wakeSubscriptionGeneration;
  int? _wakeCleanupFailedGeneration;
  int _connectionAttemptEpoch = 0;
  int _wakeEpoch = 0;
  int _wakeRecoveryAttempts = 0;
  WakeSubscriptionHealth _wakeHealth = WakeSubscriptionHealth.inactive;
  Future<void> _wakeCancellation = Future<void>.value();
  Future<void>? _wakeResume;
  static const _wakeFailureMessage =
      'Automatic refresh paused. Return to the app or reconnect to retry.';
  BleDeviceSnapshot _snapshot = const BleDeviceSnapshot(
    state: BleConnectionState.disconnected,
  );
  bool _isWriting = false;
  int? _writingGeneration;
  int _connectionGeneration = 0;
  int? _transferSendingGeneration;
  int _scanGeneration = 0;

  WakeSubscriptionHealth get wakeSubscriptionHealth => _wakeHealth;

  Stream<BleDeviceSnapshot> get snapshots => _snapshotController.stream;

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
    final attempt = ++_connectionAttemptEpoch;
    _connectionSubscription =
        _connectToDevice(
          id: discoveredDevice.id,
          servicesWithCharacteristicsToDiscover: {
            serviceUuid: [characteristicUuid, wakeCharacteristicUuid],
          },
          connectionTimeout: const Duration(seconds: 12),
        ).listen(
          (update) {
            if (attempt != _connectionAttemptEpoch) {
              _trace('connection.event ignored stale attempt=$attempt');
              return;
            }
            _trace('connection.event ${update.connectionState.name}');
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
              _invalidatePhysicalConnection('physical disconnect');
              unawaited(_cancelWakeNotificationSubscription());
              _emit(
                _snapshot.copyWith(
                  state: BleConnectionState.disconnected,
                  deviceName: null,
                ),
              );
            }
          },
          onError: (Object error) {
            if (attempt != _connectionAttemptEpoch) return;
            _invalidatePhysicalConnection('connection failure');
            unawaited(_cancelWakeNotificationSubscription());
            _emitError('Bluetooth connection failed: $error');
            if (!completer.isCompleted) {
              completer.complete();
            }
          },
        );

    await completer.future.timeout(
      const Duration(seconds: 14),
      onTimeout: () {
        if (attempt != _connectionAttemptEpoch) return;
        _emitError('Bluetooth connection timed out.');
      },
    );
  }

  Future<void> disconnect() async {
    _connectionAttemptEpoch++;
    _scanGeneration++;
    _invalidatePhysicalConnection('explicit disconnect');
    await _scanSubscription?.cancel();
    await _connectionSubscription?.cancel();
    await _cancelWakeNotificationSubscription();
    _scanSubscription = null;
    _connectionSubscription = null;
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
      await _sendTransferPackets(transfer.packets);
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
      await _sendTransferPackets([
        transfer.startPacket,
        ...transfer.chunkPackets,
        transfer.endPacket,
      ]);
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

  @override
  Future<void> sendFantasyAlert(FantasyPointAlert alert) =>
      _sendPacket(fantasyAlertSerializer.serialize(alert));

  @override
  Future<void> sendFantasyMatchup(FantasyMatchupDisplayData matchup) =>
      _sendPacket(fantasyMatchupSerializer.serialize(matchup));

  @override
  Future<void> sendFantasySlate(List<FantasyMatchupSlateEntry> entries) async {
    if (entries.map((entry) => entry.identity).toSet().length >
        FantasyMatchupPacketSerializer.maxSlateMatchups) {
      throw const FormatException(
        'Fantasy slate exceeds eight distinct matchups.',
      );
    }
    // Prepare every packet before opening device staging. This also snapshots
    // caller-owned lists so edits during an awaited write cannot change a slate.
    final packets = [
      fantasyMatchupSerializer.serializeSlateStart(),
      for (final entry in entries)
        fantasyMatchupSerializer.serialize(
          entry.matchup,
          identity: entry.identity,
        ),
      fantasyMatchupSerializer.serializeSlateEnd(),
    ];
    await _sendTransferPackets(packets);
  }

  Future<void> _sendTransferPackets(List<List<int>> packets) async {
    final generation = _connectionGeneration;
    if (_transferSendingGeneration == generation) {
      throw StateError('A slate transfer is already being sent.');
    }
    _transferSendingGeneration = generation;
    try {
      for (final packet in packets) {
        if (generation != _connectionGeneration) {
          throw StateError('Slate transfer connection changed.');
        }
        await _sendPacket(packet, transferGeneration: generation);
        if (generation != _connectionGeneration) {
          throw StateError('Slate transfer connection changed.');
        }
      }
    } finally {
      if (_transferSendingGeneration == generation) {
        _transferSendingGeneration = null;
      }
    }
  }

  @override
  Future<void> clearFantasyMatchup() =>
      _sendPacket(fantasyMatchupSerializer.serializeClear());

  Future<void> _sendPacket(List<int> packet, {int? transferGeneration}) async {
    final writeId = ++_diagnosticWriteId;
    _trace('write.attempt id=$writeId bytes=${packet.length}');
    if (_transferSendingGeneration == _connectionGeneration &&
        transferGeneration != _connectionGeneration) {
      _trace('write.rejected id=$writeId reason=transfer-owned');
      throw StateError('A slate transfer owns the connection.');
    }
    final characteristic = _writableCharacteristic;
    if (characteristic == null ||
        _snapshot.state == BleConnectionState.disconnected ||
        _snapshot.state == BleConnectionState.error) {
      _trace('write.rejected id=$writeId reason=not-connected');
      throw StateError('Sports Hub is not connected.');
    }

    if (_isWriting || _snapshot.state == BleConnectionState.sending) {
      _trace('write.rejected id=$writeId reason=busy');
      throw StateError('A Sports Hub packet is already being sent.');
    }

    _isWriting = true;
    final generation = _connectionGeneration;
    _writingGeneration = generation;
    _emit(_snapshot.copyWith(state: BleConnectionState.sending));
    debugPrint('BLE write started; generation=$generation');
    final elapsed = Stopwatch()..start();
    _trace('write.start id=$writeId originG=$generation');

    try {
      await _writeCharacteristicWithResponse(characteristic, value: packet);
      _trace(
        'write.completed id=$writeId originG=$generation elapsedMs=${elapsed.elapsedMilliseconds}',
      );
      if (_writeCanRestoreConnected(generation, characteristic)) {
        _emit(_snapshot.copyWith(state: BleConnectionState.connected));
      } else {
        throw StateError('BLE write cancelled; connection changed.');
      }
    } on Object catch (error) {
      _trace(
        'write.failed id=$writeId originG=$generation type=${error.runtimeType}',
      );
      if (_writeCanRestoreConnected(generation, characteristic)) {
        _emitError('Bluetooth write failed: $error');
      } else {
        debugPrint(
          'BLE write failure ignored for transport state; '
          'stale generation=$generation; errorType=${error.runtimeType}',
        );
      }
      rethrow;
    } finally {
      if (_writingGeneration == generation) {
        _isWriting = false;
        _writingGeneration = null;
      }
      _trace(
        'write.release id=$writeId originG=$generation elapsedMs=${elapsed.elapsedMilliseconds}',
      );
    }
  }

  Future<void> dispose() async {
    _trace('transport.dispose');
    await disconnect();
    await _wakeNotificationController.close();
    await _snapshotController.close();
  }

  FlutterReactiveBle get _bleClient {
    return _ble ??= FlutterReactiveBle();
  }

  Future<void> _writeCharacteristicWithResponse(
    QualifiedCharacteristic characteristic, {
    required List<int> value,
  }) =>
      writeWithResponse?.call(characteristic, value: value) ??
      _bleClient.writeCharacteristicWithResponse(characteristic, value: value);

  bool _writeCanRestoreConnected(
    int generation,
    QualifiedCharacteristic characteristic,
  ) =>
      generation == _connectionGeneration &&
      identical(characteristic, _writableCharacteristic) &&
      _snapshot.state != BleConnectionState.disconnected &&
      _snapshot.state != BleConnectionState.error;

  void _invalidatePhysicalConnection(String reason) {
    final previousGeneration = _connectionGeneration;
    final wasActive =
        _writableCharacteristic != null ||
        _snapshot.state.isPhysicallyConnected;
    _connectionGeneration++;
    _trace(
      'connection.generation $previousGeneration->$_connectionGeneration reason=$reason',
    );
    unawaited(_cancelWakeNotificationSubscription());
    _writableCharacteristic = null;
    _isWriting = false;
    _writingGeneration = null;
    if (wasActive) {
      debugPrint(
        'Physical BLE connection ended ($reason); generation='
        '$previousGeneration->$_connectionGeneration',
      );
    }
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

  Uuid? _tryReadWakeCharacteristicUuid() {
    try {
      return protocol.wakeCharacteristicUuid;
    } on StateError catch (error) {
      _emitError(error.message);
      return null;
    }
  }

  void _startWakeNotificationSubscription(
    QualifiedCharacteristic characteristic,
  ) {
    // Duplicate connected events must not create duplicate listeners or replenish
    // the automatic recovery budget.
    if (_wakeCharacteristic?.deviceId == characteristic.deviceId) {
      _trace('subscription.duplicate-connected ignored');
      return;
    }
    _wakeCharacteristic = characteristic;
    _wakeRecoveryAttempts = 0;
    unawaited(_listenForWake(characteristic));
  }

  bool _isCurrentWake(
    int generation,
    int epoch,
    QualifiedCharacteristic characteristic,
  ) =>
      generation == _connectionGeneration &&
      epoch == _wakeEpoch &&
      identical(characteristic, _wakeCharacteristic) &&
      _writableCharacteristic != null &&
      (_snapshot.state.isPhysicallyConnected ||
          _snapshot.state == BleConnectionState.connecting);

  Future<void> _listenForWake(QualifiedCharacteristic characteristic) async {
    final generation = _connectionGeneration;
    final epoch = ++_wakeEpoch;
    _setWakeHealth(WakeSubscriptionHealth.subscribing);
    final cancellation = _queueWakeCancellation();
    _wakeCancellation = cancellation;
    _trace('subscription.cancel-wait originG=$generation epoch=$epoch');
    try {
      await cancellation.timeout(wakeCancellationTimeout);
      if (_wakeCleanupFailedGeneration == generation) {
        throw StateError('Native WAKE cleanup failed; reconnect required.');
      }
    } on Object catch (error) {
      _trace('subscription.barrier blocked originG=$generation epoch=$epoch');
      _wakeSubscriptionFailed(generation, epoch, characteristic, error);
      return;
    }
    _trace('subscription.cancel-ready originG=$generation epoch=$epoch');
    if (!_isCurrentWake(generation, epoch, characteristic)) {
      _trace(
        'subscription.subscribe-skipped stale originG=$generation epoch=$epoch',
      );
      return;
    }
    _trace('subscription.subscribe originG=$generation epoch=$epoch');
    try {
      final stream =
          wakeStreamProvider?.call(characteristic) ??
          acknowledgedWakeStream(
            resolve: () => _resolveWakeInstance(characteristic),
            values: _bleClient.characteristicValueStream,
            enable: (instance) => ReactiveBlePlatform.instance
                .subscribeToNotifications(instance)
                .first,
            disable: (instance) => ReactiveBlePlatform.instance
                .stopSubscribingToNotifications(instance),
            isCurrent: () => _isCurrentWake(generation, epoch, characteristic),
            trace: (message) =>
                _trace('$message originG=$generation epoch=$epoch'),
          );
      final subscription = stream.listen(
        (value) {
          final current = _isCurrentWake(generation, epoch, characteristic);
          _trace(
            'wake.raw originG=$generation epoch=$epoch bytes=${value.length} accepted=$current',
          );
          if (!current) return;
          if (_wakeHealth != WakeSubscriptionHealth.receiving) {
            _setWakeHealth(WakeSubscriptionHealth.receiving);
          }
          _trace(
            'subscription.receipt-confirmed originG=$generation epoch=$epoch',
          );
          _armWakeSilenceDeadline(generation, epoch, characteristic);
          if (_snapshot.errorMessage == _wakeFailureMessage) {
            _emit(_snapshot.copyWith(clearError: true));
          }
          if (!_wakeNotificationController.isClosed) {
            _wakeNotificationController.add(value);
          }
        },
        onError: (Object error) {
          _trace(
            'subscription.error originG=$generation epoch=$epoch type=${error.runtimeType}',
          );
          _wakeSubscriptionFailed(generation, epoch, characteristic, error);
        },
        onDone: () {
          _trace('subscription.done originG=$generation epoch=$epoch');
          _wakeSubscriptionFailed(
            generation,
            epoch,
            characteristic,
            'stream ended',
          );
        },
      );
      if (!_isCurrentWake(generation, epoch, characteristic)) {
        final cleanup = _wakeCancellation.then(
          (_) => _cancelWakeStream(subscription, generation),
        );
        _wakeCancellation = cleanup;
        // Cleanup remains serialized even if this stale attempt times out.
        try {
          await cleanup.timeout(wakeCancellationTimeout);
        } on TimeoutException {
          _trace(
            'subscription.stale-cleanup still-pending originG=$generation',
          );
        }
        return;
      }
      _wakeNotificationSubscription = subscription;
      _wakeSubscriptionGeneration = generation;
      _setWakeHealth(WakeSubscriptionHealth.listening);
      _trace('subscription.registered receipt=unconfirmed');
      _armWakeSilenceDeadline(generation, epoch, characteristic);
      debugPrint('BLE WAKE: subscription listening; generation=$generation');
    } on Object catch (error) {
      _wakeSubscriptionFailed(generation, epoch, characteristic, error);
    }
  }

  void _wakeSubscriptionFailed(
    int generation,
    int epoch,
    QualifiedCharacteristic characteristic,
    Object error,
  ) {
    if (!_isCurrentWake(generation, epoch, characteristic)) {
      _trace(
        'subscription.failure-ignored stale originG=$generation epoch=$epoch',
      );
      return;
    }
    _trace(
      'subscription.failure originG=$generation epoch=$epoch type=${error.runtimeType}',
    );
    _wakeSilenceTimer?.cancel();
    _wakeSilenceTimer = null;
    final retryEpoch =
        ++_wakeEpoch; // Ignore late values/error/done from this attempt.
    debugPrint('BLE WAKE: subscription interrupted type=${error.runtimeType}');
    if (_wakeRecoveryAttempts >= wakeRetryDelays.length) {
      _setWakeHealth(WakeSubscriptionHealth.failed);
      _queueWakeCancellation();
      _emit(_snapshot.copyWith(errorMessage: _wakeFailureMessage));
      return;
    }
    _setWakeHealth(WakeSubscriptionHealth.retrying);
    final delay = wakeRetryDelays[_wakeRecoveryAttempts++];
    _trace(
      'subscription.retry attempt=$_wakeRecoveryAttempts delayMs=${delay.inMilliseconds}',
    );
    _wakeRetryTimer = Timer(delay, () {
      _wakeRetryTimer = null;
      if (!_isCurrentWake(generation, retryEpoch, characteristic)) return;
      unawaited(_listenForWake(characteristic));
    });
  }

  /// Background time is not evidence of notification failure (iOS may suspend
  /// Dart). Foreground return grants one full deadline without replacing WAKE.
  void setWakeForeground(bool foreground) {
    if (_wakeForeground == foreground) return;
    _wakeForeground = foreground;
    _trace('subscription.foreground=$foreground');
    _wakeSilenceTimer?.cancel();
    _wakeSilenceTimer = null;
  }

  void _armWakeSilenceDeadline(
    int generation,
    int epoch,
    QualifiedCharacteristic characteristic,
  ) {
    _wakeSilenceTimer?.cancel();
    _wakeSilenceTimer = null;
    if (!_wakeForeground) return;
    _wakeSilenceTimer = Timer(wakeSilenceTimeout, () {
      _wakeSilenceTimer = null;
      if (!_wakeForeground ||
          !_isCurrentWake(generation, epoch, characteristic)) {
        return;
      }
      _trace(
        'subscription.silent originG=$generation epoch=$epoch deadlineMs=${wakeSilenceTimeout.inMilliseconds}',
      );
      _wakeSubscriptionFailed(
        generation,
        epoch,
        characteristic,
        TimeoutException('WAKE silent'),
      );
    });
  }

  /// Healthy/subscribing/retrying listeners keep their ownership and retry budget.
  /// Only an exhausted cycle can be explicitly restarted on foreground return.
  Future<void> resumeWakeNotifications() {
    _trace('subscription.resume requested');
    setWakeForeground(true);
    if (_wakeResume != null) {
      _trace('subscription.resume coalesced');
      return _wakeResume!;
    }
    final characteristic = _wakeCharacteristic;
    if (!_snapshot.state.isPhysicallyConnected || characteristic == null) {
      _trace('subscription.resume skipped disconnected-or-no-characteristic');
      return Future<void>.value();
    }
    if (_wakeHealth != WakeSubscriptionHealth.failed) {
      _trace('subscription.resume preserved health=${_wakeHealth.name}');
      if (_wakeSilenceTimer == null &&
          (_wakeHealth == WakeSubscriptionHealth.listening ||
              _wakeHealth == WakeSubscriptionHealth.receiving)) {
        _armWakeSilenceDeadline(
          _connectionGeneration,
          _wakeEpoch,
          characteristic,
        );
      }
      return Future<void>.value();
    }
    _wakeRecoveryAttempts = 0;
    late final Future<void> resume;
    resume = _listenForWake(characteristic).whenComplete(() {
      if (identical(_wakeResume, resume)) _wakeResume = null;
    });
    _wakeResume = resume;
    return resume;
  }

  Future<CharacteristicInstance> _resolveWakeInstance(
    QualifiedCharacteristic characteristic,
  ) async {
    await _bleClient.initialize();
    final services = await ReactiveBlePlatform.instance.getDiscoverServices(
      characteristic.deviceId,
    );
    final matches = [
      for (final service in services)
        if (service.serviceId == characteristic.serviceId)
          for (final value in service.characteristics)
            if (value.characteristicId == characteristic.characteristicId)
              CharacteristicInstance(
                characteristicId: value.characteristicId,
                characteristicInstanceId: value.characteristicInstanceId,
                serviceId: service.serviceId,
                serviceInstanceId: service.serviceInstanceId,
                deviceId: characteristic.deviceId,
              ),
    ];
    if (matches.length != 1) {
      throw StateError('WAKE characteristic not unique.');
    }
    return matches.single;
  }

  Future<void> _queueWakeCancellation() {
    final previous = _wakeNotificationSubscription;
    final generation = _wakeSubscriptionGeneration ?? _connectionGeneration;
    _wakeNotificationSubscription = null;
    _wakeSubscriptionGeneration = null;
    final cancellation = _wakeCancellation.then(
      (_) => _cancelWakeStream(previous, generation),
    );
    _wakeCancellation = cancellation;
    return cancellation;
  }

  Future<void> _cancelWakeStream(
    StreamSubscription<List<int>>? subscription,
    int generation,
  ) async {
    if (subscription == null) return;
    final id = identityHashCode(subscription);
    _trace('subscription.cancel start id=$id originG=$generation');
    try {
      // Do not timeout the actual barrier: a timeout cannot cancel native off.
      // Callers bound their wait while replacement stays behind this future.
      await subscription.cancel();
      _trace('subscription.cancel completed id=$id originG=$generation');
    } on Object catch (error) {
      _wakeCleanupFailedGeneration = generation;
      _trace(
        'subscription.cancel failed id=$id originG=$generation type=${error.runtimeType}',
      );
    }
  }

  Future<void> _cancelWakeNotificationSubscription() async {
    ++_wakeEpoch;
    _wakeRetryTimer?.cancel();
    _wakeRetryTimer = null;
    _wakeSilenceTimer?.cancel();
    _wakeSilenceTimer = null;
    _wakeCharacteristic = null;
    _wakeRecoveryAttempts = 0;
    _setWakeHealth(WakeSubscriptionHealth.inactive);
    _wakeResume = null;
    final cancellation = _queueWakeCancellation();
    try {
      await cancellation.timeout(wakeCancellationTimeout);
    } on TimeoutException {
      _trace('subscription.cancel still-pending; replacement barrier retained');
    }
  }

  void _emitError(String message) {
    _trace('connection.error');
    unawaited(_cancelWakeNotificationSubscription());
    _emit(
      _snapshot.copyWith(
        state: BleConnectionState.error,
        errorMessage: message,
      ),
    );
  }

  void _emit(BleDeviceSnapshot snapshot) {
    if (snapshot.state.isPhysicallyConnected &&
        _wakeHealth == WakeSubscriptionHealth.failed) {
      snapshot = snapshot.copyWith(errorMessage: _wakeFailureMessage);
    }
    if (_snapshot.state != snapshot.state) {
      _trace(
        'connection.state ${_snapshot.state.name}->${snapshot.state.name}; hasError=${snapshot.errorMessage != null}',
      );
    }
    _snapshot = snapshot;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }
}
