import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports_hub_mobile/bluetooth_device_transport.dart';
import 'package:sports_hub_mobile/connection_screen.dart';
import 'package:sports_hub_mobile/device_content_preferences.dart';
import 'package:sports_hub_mobile/device_content_preferences_store.dart';
import 'package:sports_hub_mobile/push_notification_service.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';

void main() {
  testWidgets(
    'F18 foreground renews WAKE and coalesces with startup/active refresh',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final scan = StreamController<DiscoveredDevice>.broadcast();
      final connection = StreamController<ConnectionStateUpdate>.broadcast();
      final wakes = <StreamController<List<int>>>[];
      final source = _Source();
      final packets = <String>[];
      final initial = Completer<void>();
      source.block = initial;
      final transport = BluetoothDeviceTransport(
        scanTimeout: const Duration(milliseconds: 10),
        bleStatusProvider: () => BleStatus.ready,
        scanStreamProvider: () => scan.stream,
        connectionStreamProvider:
            ({
              required id,
              required servicesWithCharacteristicsToDiscover,
              required connectionTimeout,
            }) => connection.stream,
        wakeStreamProvider: (_) {
          final stream = StreamController<List<int>>.broadcast();
          wakes.add(stream);
          return stream.stream;
        },
        writeWithResponse: (_, {required value}) async {
          packets.add(utf8.decode(value));
        },
      );
      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          // Stream cancellation can complete in the real zone; timers and UI
          // callbacks still need Flutter's fake clock advanced explicitly.
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 10));
        }
      }

      void resume() {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }

      var cleaned = false;
      addTearDown(() {
        if (!initial.isCompleted) initial.complete();
        if (source.block != null && !source.block!.isCompleted) {
          source.block!.complete();
        }
        if (!cleaned) {
          unawaited(transport.dispose());
          unawaited(scan.close());
          unawaited(connection.close());
          for (final stream in wakes) {
            unawaited(stream.close());
          }
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionScreen(
            repository: SportsRepository(source),
            transport: transport,
            pushNotificationService: const _NoPush(),
            contentPreferencesStore: MemoryDeviceContentPreferencesStore(
              DeviceContentPreferences([
                for (final category in DeviceContentCategory.values)
                  DeviceContentPreference(
                    category: category,
                    enabled: category == DeviceContentCategory.nfl,
                  ),
              ]),
            ),
          ),
        ),
      );
      var scanned = false;
      unawaited(transport.scanForDevice().then((_) => scanned = true));
      await tester.pump();
      scan.add(
        DiscoveredDevice(
          id: 'esp2',
          name: 'Peter Sports Hub',
          serviceData: const {},
          manufacturerData: Uint8List(0),
          serviceUuids: const [],
          rssi: -40,
        ),
      );
      await settle();
      expect(scanned, isTrue);
      var connected = false;
      unawaited(
        transport
            .connectToDevice(transport.currentSnapshot.candidates.single)
            .then((_) => connected = true),
      );
      await settle();
      connection.add(
        const ConnectionStateUpdate(
          deviceId: 'esp2',
          connectionState: DeviceConnectionState.connected,
          failure: null,
        ),
      );
      await settle();
      expect(connected, isTrue);
      expect(source.calls, 1);
      expect(wakes, hasLength(1));
      resume();
      await settle();
      expect(wakes, hasLength(2));
      for (var i = 0; i < 10; i++) {
        wakes.last.add(utf8.encode('WAKE'));
      }
      await settle();
      expect(source.calls, 1); // Still owned by initial sync.
      expect(packets, isNot(contains('SYNC_START')));
      initial.complete();
      await settle();
      expect(source.calls, 2); // Exactly one coalesced follow-up.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle();
      expect(source.calls, 2);
      expect(wakes, hasLength(2));

      final active = Completer<void>();
      source.block = active;
      wakes.last.add(utf8.encode('WAKE'));
      await settle();
      expect(source.calls, 3);
      resume();
      await settle();
      expect(wakes, hasLength(3));
      for (var i = 0; i < 10; i++) {
        wakes.last.add(utf8.encode('WAKE'));
      }
      await settle();
      expect(source.calls, 3);
      active.complete();
      await settle();
      expect(source.calls, 4);
      expect(source.maxActive, 1);
      expect(wakes.where((s) => s.hasListener), hasLength(1));
      connection.add(
        const ConnectionStateUpdate(
          deviceId: 'esp2',
          connectionState: DeviceConnectionState.disconnected,
          failure: null,
        ),
      );
      await settle();
      resume();
      await settle();
      expect(source.calls, 4);
      expect(wakes, hasLength(3));
      // F07: the retained phone/device catalog must survive an offline
      // reconnect, then recover from one coalesced burst when the provider returns.
      source.fail = true;
      final resets = packets.where((p) => p == 'SYNC_START').length;
      connection.add(
        const ConnectionStateUpdate(
          deviceId: 'esp2',
          connectionState: DeviceConnectionState.connected,
          failure: null,
        ),
      );
      await settle();
      expect(source.calls, 5);
      expect(packets.where((p) => p == 'SYNC_START'), hasLength(resets));
      expect(
        find.text('Updates incomplete; cached data unverified'),
        findsOneWidget,
      );
      final recovery = Completer<void>();
      source.block = recovery;
      for (var i = 0; i < 10; i++) {
        wakes.last.add(utf8.encode('WAKE'));
      }
      await settle();
      expect(source.calls, 6);
      expect(packets.where((p) => p == 'SYNC_START'), hasLength(resets));
      source.fail = false;
      recovery.complete();
      await settle();
      expect(source.calls, 6);
      expect(packets.where((p) => p == 'SYNC_START'), hasLength(resets + 1));
      expect(packets.last, 'SYNC_COMPLETE');
      expect(
        find.text('Updates incomplete; cached data unverified'),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await settle();
      unawaited(
        Future.wait<void>([
          transport.dispose(),
          scan.close(),
          connection.close(),
          for (final stream in wakes) stream.close(),
        ]).then((_) => cleaned = true),
      );
      await settle();
      expect(cleaned, isTrue);
    },
  );
}

class _Source implements SportsDataSource {
  int calls = 0, active = 0, maxActive = 0;
  Completer<void>? block;
  bool fail = false;
  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime date,
  ) async {
    calls++;
    active++;
    if (active > maxActive) maxActive = active;
    final pending = block;
    block = null;
    try {
      if (pending != null) await pending.future;
      if (fail) throw StateError('Provider unavailable');
      return [
        const SportsGame(
          league: 'NFL',
          eventId: 'nfl',
          awayTeam: 'Away',
          homeTeam: 'Home',
          awayScore: 1,
          homeScore: 0,
          status: 'LIVE',
          clock: 'Q1',
        ),
      ];
    } finally {
      active--;
    }
  }
}

class _NoPush extends PushNotificationService {
  const _NoPush();
  @override
  Future<PushNotificationDiagnostics> readDiagnostics() async =>
      const PushNotificationDiagnostics(
        permissionStatus: 'unknown',
        apnsToken: null,
        isApplePlatform: false,
        token: null,
      );
}
