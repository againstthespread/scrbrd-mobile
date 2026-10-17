import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:sports_hub_mobile/bluetooth_device_transport.dart';
import 'package:sports_hub_mobile/sports_hub_ble_protocol.dart';

/// Persistent real firmware parser/storage process; no firmware state model in Dart.
class NativeDevice {
  NativeDevice._(this.process) {
    lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    stderrDone = process.stderr.transform(utf8.decoder).forEach(stderr.write);
  }
  static Future<NativeDevice> start() async => NativeDevice._(
    await Process.start(
      Platform.environment['SCRBRD_VIRTUAL_DEVICE']!,
      const [],
    ),
  );
  final Process process;
  late final StreamIterator<String> lines;
  final stderr = StringBuffer();
  late final Future<void> stderrDone;
  Future<void> _tail = Future.value();
  final transcript = <Map<String, dynamic>>[];

  Future<Map<String, dynamic>> request(Map<String, dynamic> command) {
    final result = _tail.then((_) async {
      process.stdin.writeln(jsonEncode(command));
      await process.stdin.flush();
      if (!await lines.moveNext().timeout(const Duration(seconds: 5))) {
        throw StateError('Native device exited: $stderr');
      }
      final line = lines.current;
      if (!line.startsWith('VIRTUAL ')) {
        throw StateError('Unexpected native response: $line');
      }
      final response = jsonDecode(line.substring(8)) as Map<String, dynamic>;
      transcript.add({'request': command, 'response': response});
      if (response['ok'] != true) {
        throw StateError('Native device rejected command: $response');
      }
      return response;
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Map<String, dynamic>> state() => request({'op': 'state'});
  Future<void> close(String name) async {
    final output = Platform.environment['SCRBRD_VIRTUAL_REPORT_DIR'];
    if (output != null) {
      File('$output/$name-transcript.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(transcript),
      );
    }
    await process.stdin.close();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 3));
      if (code != 0) throw StateError('Native device exit $code: $stderr');
    } finally {
      process.kill();
      await lines.cancel();
      await stderrDone;
    }
  }
}

enum Fault { drop, fail, disconnect, hold }

/// Simulates ONLY the plugin/radio boundary. Production transport owns serialization,
/// logical transactions, generation cancellation, error state and WAKE subscriptions.
class VirtualBle {
  VirtualBle(this.device) {
    transport = BluetoothDeviceTransport(
      scanTimeout: const Duration(milliseconds: 5),
      writeTimeout: const Duration(milliseconds: 100),
      bleStatusProvider: () => ready ? BleStatus.ready : BleStatus.poweredOff,
      scanStreamProvider: () =>
          Stream.fromIterable(available ? [advertisement] : []),
      connectionStreamProvider:
          ({
            required id,
            required servicesWithCharacteristicsToDiscover,
            required connectionTimeout,
          }) {
            attempts.add(id);
            final controller = StreamController<ConnectionStateUpdate>();
            connections.add(controller);
            scheduleMicrotask(() async {
              if (!ready || !available || id != deviceId) {
                controller.addError(StateError('Scripted device unavailable'));
                return;
              }
              await device.request({'op': 'link', 'connected': true});
              linked = true;
              controller.add(
                ConnectionStateUpdate(
                  deviceId: id,
                  connectionState: DeviceConnectionState.connected,
                  failure: null,
                ),
              );
            });
            return controller.stream;
          },
      wakeStreamProvider: (_) => wake.stream,
      writeWithResponse: (_, {required value}) => write(value),
    );
  }
  static const deviceId = 'virtual-esp-2';
  final NativeDevice device;
  late final BluetoothDeviceTransport transport;
  final wake = StreamController<List<int>>.broadcast();
  final connections = <StreamController<ConnectionStateUpdate>>[];
  final attempts = <String>[];
  final faults = <int, Fault>{};
  final packets = <List<int>>[];
  bool available = true, ready = true, linked = false;
  int epoch = 0;
  Completer<void>? held;
  Duration writeDelay = Duration.zero;
  DiscoveredDevice get advertisement => DiscoveredDevice(
    id: deviceId,
    name: SportsHubBleProtocol.advertisingName,
    serviceData: const {},
    manufacturerData: Uint8List(0),
    serviceUuids: [Uuid.parse(SportsHubBleProtocol.serviceUuidText)],
    rssi: -45,
    connectable: Connectable.available,
  );

  Future<void> connect() async {
    await transport.scanForDevice();
    if (transport.currentSnapshot.candidates.isEmpty) {
      throw StateError('No available virtual device');
    }
    await transport.connectToDevice(
      transport.currentSnapshot.candidates.single,
    );
  }

  Future<void> disconnect() async {
    linked = false;
    epoch++;
    await device.request({'op': 'link', 'connected': false});
    connections.last.add(
      const ConnectionStateUpdate(
        deviceId: deviceId,
        connectionState: DeviceConnectionState.disconnected,
        failure: null,
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> write(List<int> value) async {
    final generation = epoch;
    packets.add(List.of(value));
    final fault = faults[packets.length];
    if (fault == Fault.disconnect) {
      await disconnect();
      throw StateError('Scripted link lost during write');
    }
    if (fault == Fault.fail) throw StateError('Scripted native write failure');
    if (fault == Fault.hold) {
      held = Completer<void>();
      await held!.future;
    }
    if (writeDelay > Duration.zero) await Future<void>.delayed(writeDelay);
    if (!linked || epoch != generation) {
      throw StateError('Obsolete virtual write');
    }
    // A successful native write does not guarantee ESP processing. Drop models RX
    // loss AFTER native completion, not BLE's reliable ATT retransmission mechanism.
    if (fault != Fault.drop) {
      await device.request({'op': 'packet', 'bytes': value});
    }
  }

  void release() {
    if (held?.isCompleted == false) held!.complete();
  }

  void notifyWake() => wake.add(utf8.encode('WAKE'));
  Future<void> close(String name) async {
    release();
    await transport.dispose();
    for (final connection in connections) {
      await connection.close();
    }
    await wake.close();
    await device.close(name);
  }
}
