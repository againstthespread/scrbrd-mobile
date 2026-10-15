import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:sports_hub_mobile/ble_device_state.dart';
import 'package:sports_hub_mobile/refresh_diagnostic_history.dart';
import 'package:sports_hub_mobile/bluetooth_device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/fantasy_matchup_display_data.dart';
import 'package:sports_hub_mobile/fantasy_matchup_transport.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/session_aware_device_sender.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_hub_ble_protocol.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  for (final terminal in ['error', 'done']) {
    test('F18 WAKE $terminal recovers without a physical reconnect', () async {
      final streams = <StreamController<List<int>>>[];
      final harness = await _WriteHarness.create(
        wakeStreamProvider: (_) {
          final stream = StreamController<List<int>>.broadcast();
          streams.add(stream);
          return stream.stream;
        },
      );
      final received = <List<int>>[];
      final subscription = harness.transport.wakeNotifications.listen(
        received.add,
      );
      addTearDown(() async {
        await subscription.cancel();
        await harness.dispose();
        for (final stream in streams) {
          await stream.close();
        }
      });
      if (terminal == 'error') {
        streams.single.addError(StateError('CCCD subscription failed'));
      } else {
        await streams.single.close();
      }
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(streams, hasLength(2));
      streams.last.add(utf8.encode('WAKE'));
      await Future<void>.delayed(Duration.zero);
      expect(received, [utf8.encode('WAKE')]);
      expect(
        harness.transport.currentSnapshot.state,
        BleConnectionState.connected,
      );
    });
  }

  test(
    'H01 records WAKE, subscription and write boundaries without payloads',
    () async {
      final history = RefreshDiagnosticHistory();
      final harness = await _WriteHarness.create(
        diagnosticHistory: history,
        wakeRetryDelays: [Duration.zero],
      );
      try {
        harness.wake.add(utf8.encode('PRIVATE_WAKE_PAYLOAD'));
        await Future<void>.delayed(Duration.zero);
        expect(
          history.entries.any(
            (e) =>
                e.message.startsWith('wake.raw') &&
                e.message.contains('accepted=true'),
          ),
          isTrue,
        );
        expect(
          history.entries.any(
            (e) => e.message.contains('subscribing->listening'),
          ),
          isTrue,
        );
        final write = harness.transport.sendControlCommand(
          'PRIVATE_WRITE_PAYLOAD',
        );
        expect(
          history.entries.any((e) => e.message.startsWith('write.start')),
          isTrue,
        );
        expect(
          history.entries.any((e) => e.message.startsWith('write.completed')),
          isFalse,
        );
        harness.completeWrite(0);
        await write;
        expect(
          history.entries.any((e) => e.message.startsWith('write.completed')),
          isTrue,
        );
        final failed = harness.transport.sendControlCommand(
          'PRIVATE_WRITE_PAYLOAD',
        );
        final rejected = expectLater(failed, throwsA(isA<StateError>()));
        harness.writes[1].completeError(
          StateError('api_key=PRIVATE_ERROR_SECRET'),
        );
        await rejected;
        expect(
          history.entries.any((e) => e.message.startsWith('write.failed')),
          isTrue,
        );
        final text = history.exportText();
        expect(text, isNot(contains('PRIVATE_')));
        expect(
          history.entries.every(
            (e) =>
                e.generation != null &&
                e.transportId == harness.transport.diagnosticId,
          ),
          isTrue,
        );
      } finally {
        await harness.dispose();
        history.dispose();
      }
    },
  );

  test(
    'H01 observes reconnect generations and bounded subscription recovery',
    () async {
      final history = RefreshDiagnosticHistory();
      final harness = await _WriteHarness.create(
        diagnosticHistory: history,
        wakeRetryDelays: [Duration.zero],
      );
      try {
        final oldGeneration = harness.transport.connectionGeneration;
        harness.wake.addError(StateError('token=PRIVATE_SUBSCRIPTION_SECRET'));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(
          history.entries.any(
            (e) => e.message.startsWith('subscription.error'),
          ),
          isTrue,
        );
        expect(
          history.entries.any(
            (e) => e.message.startsWith('subscription.retry'),
          ),
          isTrue,
        );
        expect(
          harness.transport.wakeSubscriptionHealth,
          WakeSubscriptionHealth.listening,
        );
        harness.physicalDisconnect();
        await Future<void>.delayed(Duration.zero);
        harness.physicalReconnect();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        harness.wake.add(utf8.encode('WAKE'));
        await Future<void>.delayed(Duration.zero);
        expect(
          harness.transport.connectionGeneration,
          greaterThan(oldGeneration),
        );
        expect(
          history.entries.any(
            (e) => e.message.startsWith('connection.generation'),
          ),
          isTrue,
        );
        expect(
          history.entries
              .firstWhere((e) => e.message.startsWith('wake.raw'))
              .generation,
          harness.transport.connectionGeneration,
        );
        expect(history.exportText(), isNot(contains('PRIVATE_')));
      } finally {
        await harness.dispose();
        history.dispose();
      }
    },
  );

  Future<void> waitForWake(bool Function() ready) async {
    for (var tick = 0; tick < 100 && !ready(); tick++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(ready(), isTrue);
  }

  test(
    'F18 retry budget is bounded and explicit resume owns one fresh listener',
    () async {
      var attempts = 0;
      var fail = true;
      final stream = StreamController<List<int>>.broadcast();
      final harness = await _WriteHarness.create(
        wakeRetryDelays: List.filled(3, const Duration(milliseconds: 1)),
        wakeStreamProvider: (_) {
          attempts++;
          if (fail) throw StateError('subscribe failed synchronously');
          return stream.stream;
        },
      );
      addTearDown(() async {
        await harness.dispose();
        await stream.close();
      });
      await waitForWake(
        () =>
            harness.transport.wakeSubscriptionHealth ==
            WakeSubscriptionHealth.failed,
      );
      expect(attempts, 4);
      expect(
        harness.transport.currentSnapshot.errorMessage,
        contains('Automatic refresh paused'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(attempts, 4);
      harness.physicalReconnect();
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 4);
      expect(
        harness.transport.currentSnapshot.errorMessage,
        contains('Automatic refresh paused'),
      );
      fail = false;
      final first = harness.transport.resumeWakeNotifications();
      final second = harness.transport.resumeWakeNotifications();
      expect(identical(first, second), isTrue);
      await first;
      expect(attempts, 5);
      expect(
        harness.transport.wakeSubscriptionHealth,
        WakeSubscriptionHealth.listening,
      );
      stream.add(utf8.encode('WAKE'));
      await Future<void>.delayed(Duration.zero);
      expect(harness.transport.currentSnapshot.errorMessage, isNull);
    },
  );

  test(
    'F18 notifications and duplicate connected events do not reset retry budget',
    () async {
      final streams = <StreamController<List<int>>>[];
      final harness = await _WriteHarness.create(
        wakeRetryDelays: List.filled(3, const Duration(milliseconds: 1)),
        wakeStreamProvider: (_) {
          final stream = StreamController<List<int>>.broadcast();
          streams.add(stream);
          return stream.stream;
        },
      );
      addTearDown(() async {
        await harness.dispose();
        for (final s in streams) {
          await s.close();
        }
      });
      harness.physicalReconnect();
      await Future<void>.delayed(Duration.zero);
      expect(streams, hasLength(1));
      for (var attempt = 0; attempt < 4; attempt++) {
        streams.last.add(utf8.encode('WAKE'));
        streams.last.addError(StateError('interrupted'));
        await waitForWake(
          () => attempt == 3
              ? harness.transport.wakeSubscriptionHealth ==
                    WakeSubscriptionHealth.failed
              : streams.length == attempt + 2,
        );
      }
      expect(streams, hasLength(4));
      expect(
        harness.transport.wakeSubscriptionHealth,
        WakeSubscriptionHealth.failed,
      );
    },
  );

  test(
    'F18 disconnect cancels queued recovery and reconnect uses only new stream',
    () async {
      final streams = <StreamController<List<int>>>[];
      final harness = await _WriteHarness.create(
        wakeRetryDelays: [const Duration(milliseconds: 30)],
        wakeStreamProvider: (_) {
          final s = StreamController<List<int>>.broadcast();
          streams.add(s);
          return s.stream;
        },
      );
      final received = <List<int>>[];
      final listener = harness.transport.wakeNotifications.listen(received.add);
      addTearDown(() async {
        await listener.cancel();
        await harness.dispose();
        for (final s in streams) {
          await s.close();
        }
      });
      streams.single.addError(StateError('broken'));
      await Future<void>.delayed(Duration.zero);
      harness.physicalDisconnect();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(streams, hasLength(1));
      expect(
        harness.transport.wakeSubscriptionHealth,
        WakeSubscriptionHealth.inactive,
      );
      harness.physicalReconnect();
      await waitForWake(() => streams.length == 2);
      streams.first.add(utf8.encode('obsolete'));
      streams.last.add(utf8.encode('WAKE'));
      await Future<void>.delayed(Duration.zero);
      expect(received, [utf8.encode('WAKE')]);
    },
  );

  test(
    'F18 disconnect during cancellation cannot install a stale recovery listener',
    () async {
      final cancel = Completer<void>();
      final streams = <StreamController<List<int>>>[];
      final harness = await _WriteHarness.create(
        wakeRetryDelays: [const Duration(milliseconds: 1)],
        wakeStreamProvider: (_) {
          final s = StreamController<List<int>>(
            onCancel: streams.isEmpty ? () => cancel.future : null,
          );
          streams.add(s);
          return s.stream;
        },
      );
      addTearDown(() async {
        if (!cancel.isCompleted) cancel.complete();
        await harness.dispose();
        for (final s in streams) {
          await s.close();
        }
      });
      streams.single.addError(StateError('broken'));
      await waitForWake(() => !streams.first.hasListener);
      harness.physicalDisconnect();
      harness.physicalReconnect();
      await Future<void>.delayed(Duration.zero);
      cancel.complete();
      await waitForWake(() => streams.length == 2);
      expect(streams.where((s) => s.hasListener), hasLength(1));
      expect(
        harness.transport.wakeSubscriptionHealth,
        WakeSubscriptionHealth.listening,
      );
    },
  );

  test('F18 disposal cancels pending recovery timers', () async {
    var attempts = 0;
    final harness = await _WriteHarness.create(
      wakeRetryDelays: [const Duration(milliseconds: 20)],
      wakeStreamProvider: (_) {
        attempts++;
        return Stream.error(StateError('broken'));
      },
    );
    await Future<void>.delayed(Duration.zero);
    await harness.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(attempts, 1);
    expect(
      harness.transport.wakeSubscriptionHealth,
      WakeSubscriptionHealth.inactive,
    );
  });

  Future<void> drainWrites(_WriteHarness harness, Future<void> send) async {
    var done = false;
    send.then((_) => done = true, onError: (Object _) => done = true);
    for (var tick = 0; tick < 30 && !done; tick++) {
      await Future<void>.delayed(Duration.zero);
      for (final write in harness.writes) {
        if (!write.isCompleted) write.complete();
      }
    }
  }

  test('fantasy slate prevalidates every entry before any write', () async {
    final harness = await _WriteHarness.create();
    final send = harness.transport.sendFantasySlate([
      _fantasyEntry('A'),
      _fantasyEntry('B', week: 0),
    ]);
    final failure = expectLater(send, throwsFormatException);
    await drainWrites(harness, send);
    await failure;
    expect(harness.writeCount, 0);
    await harness.dispose();
  });

  for (final identity in ['', 'x' * 49, 'é' * 25, 'bad\u0000id']) {
    test(
      'fantasy invalid identity is rejected before opening staging: $identity',
      () async {
        final harness = await _WriteHarness.create();
        await expectLater(
          harness.transport.sendFantasySlate([_fantasyEntry(identity)]),
          throwsFormatException,
        );
        expect(harness.writeCount, 0);
        await harness.dispose();
      },
    );
  }

  test(
    'fantasy capacity and packet shapes retain version 1 contract',
    () async {
      final harness = await _WriteHarness.create();
      await expectLater(
        harness.transport.sendFantasySlate([
          for (var i = 0; i < 9; i++) _fantasyEntry('$i'),
        ]),
        throwsFormatException,
      );
      expect(harness.writeCount, 0);
      final entries = [_fantasyEntry('A'), _fantasyEntry('B')];
      final send = harness.transport.sendFantasySlate(entries);
      entries.clear(); // Prevalidation must snapshot caller-owned input.
      await drainWrites(harness, send);
      await send;
      final packets = harness.packets
          .map((packet) => jsonDecode(utf8.decode(packet)))
          .toList();
      expect(packets.map((packet) => packet['type']), [
        'fantasy_slate_start',
        'fantasy_matchup',
        'fantasy_matchup',
        'fantasy_slate_end',
      ]);
      expect(packets.every((packet) => packet['version'] == 1), isTrue);
      expect(packets[1]['identity'], 'A');
      expect(packets[2]['identity'], 'B');
      expect(harness.packets.every((packet) => packet.length <= 512), isTrue);
      await harness.dispose();
    },
  );

  test(
    'duplicate identities retain in-place replacement compatibility',
    () async {
      final harness = await _WriteHarness.create();
      final send = harness.transport.sendFantasySlate([
        for (var i = 0; i < 9; i++) _fantasyEntry('A'),
      ]);
      await drainWrites(harness, send);
      await send;
      expect(harness.writeCount, 11);
      expect(
        jsonDecode(utf8.decode(harness.packets.last))['type'],
        'fantasy_slate_end',
      );
      await harness.dispose();
    },
  );

  test(
    'fantasy failed write sends no end and retry starts a fresh transaction',
    () async {
      final harness = await _WriteHarness.create();
      final send = harness.transport.sendFantasySlate([_fantasyEntry('A')]);
      final failure = expectLater(send, throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      harness.completeWrite(0);
      await Future<void>.delayed(Duration.zero);
      harness.writes[1].completeError(StateError('injected write failure'));
      await failure;
      expect(harness.writeCount, 2);
      harness.physicalDisconnect();
      await Future<void>.delayed(Duration.zero);
      harness.physicalReconnect();
      await Future<void>.delayed(Duration.zero);
      final retry = harness.transport.sendFantasySlate([_fantasyEntry('A')]);
      final competing = harness.transport.sendFantasySlate([
        _fantasyEntry('B'),
      ]);
      await expectLater(competing, throwsA(isA<StateError>()));
      await drainWrites(harness, retry);
      await retry;
      expect(
        jsonDecode(utf8.decode(harness.packets[2]))['type'],
        'fantasy_slate_start',
      );
      expect(
        jsonDecode(utf8.decode(harness.packets.last))['type'],
        'fantasy_slate_end',
      );
      await harness.dispose();
    },
  );

  for (var boundary = 0; boundary < 4; boundary++) {
    test(
      'fantasy interruption at packet $boundary cannot cross sessions',
      () async {
        final harness = await _WriteHarness.create();
        final send = harness.transport.sendFantasySlate([
          _fantasyEntry('A'),
          _fantasyEntry('B'),
        ]);
        final failure = expectLater(send, throwsA(isA<StateError>()));
        for (var index = 0; index < boundary; index++) {
          await Future<void>.delayed(Duration.zero);
          harness.completeWrite(index);
        }
        await Future<void>.delayed(Duration.zero);
        harness.physicalDisconnect();
        await Future<void>.delayed(Duration.zero);
        harness.physicalReconnect();
        await Future<void>.delayed(Duration.zero);
        harness.completeWrite(boundary);
        await drainWrites(harness, send);
        await failure;
        expect(harness.writeCount, boundary + 1);
        await harness.dispose();
      },
    );
  }

  for (final golf in [false, true]) {
    for (var boundary = 0; boundary < 3; boundary++) {
      test(
        'F34 ${golf ? "golf" : "sports"} reconnect at packet $boundary retains baseline',
        () async {
          final harness = await _WriteHarness.create();
          final session = TrackedDeviceSession();
          if (golf) {
            session.recordGolf(_golf('-1'));
          } else {
            session.recordTeamSlate(
              league: SportsLeague.mlb,
              selectedDate: _date,
              games: [_game(score: 1)],
            );
          }
          final sender = SessionAwareDeviceSender(
            transport: harness.transport,
            session: session,
          );
          final send = golf
              ? sender.sendGolf(_golf('-2'), selectedDate: _date)
              : sender.sendTeamSlate([_game(score: 2)], selectedDate: _date);
          final failure = expectLater(send, throwsA(isA<StateError>()));
          for (var index = 0; index < boundary; index++) {
            await Future<void>.delayed(Duration.zero);
            harness.completeWrite(index);
          }
          await Future<void>.delayed(Duration.zero);
          harness.physicalDisconnect();
          await Future<void>.delayed(Duration.zero);
          harness.physicalReconnect();
          await Future<void>.delayed(Duration.zero);
          harness.completeWrite(boundary);
          await drainWrites(harness, send);
          await failure;
          expect(harness.writeCount, boundary + 1);
          if (golf) {
            expect(
              (session[SportsLeague.pga] as TrackedGolfLeaderboard)
                  .leaderboard
                  .golfers
                  .single
                  .score,
              '-1',
            );
          } else {
            expect(
              (session[SportsLeague.mlb] as TrackedTeamSlate)
                  .games
                  .single
                  .awayScore,
              1,
            );
          }
          final retry = golf
              ? sender.sendGolf(_golf('-2'), selectedDate: _date)
              : sender.sendTeamSlate([_game(score: 2)], selectedDate: _date);
          await drainWrites(harness, retry);
          await retry;
          expect(
            jsonDecode(utf8.decode(harness.packets[boundary + 1]))['type'],
            golf ? 'golf_start' : 'slate_start',
          );
          session.dispose();
          await harness.dispose();
        },
      );
    }
  }

  test(
    'F34 cancelled old write cannot release an active new transfer',
    () async {
      final harness = await _WriteHarness.create();
      final old = harness.transport.sendGameSlate([_game(score: 1)]);
      final cancelled = expectLater(old, throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      harness.physicalDisconnect();
      await Future<void>.delayed(Duration.zero);
      harness.physicalReconnect();
      await Future<void>.delayed(Duration.zero);
      final fresh = harness.transport.sendGameSlate([_game(score: 2)]);
      await Future<void>.delayed(Duration.zero);
      expect(harness.writeCount, 2);
      harness.completeWrite(0);
      await cancelled;
      expect(
        harness.transport.currentSnapshot.state,
        BleConnectionState.sending,
      );
      await expectLater(
        harness.transport.sendFantasySlate([_fantasyEntry('A')]),
        throwsA(isA<StateError>()),
      );
      await drainWrites(harness, fresh);
      await fresh;
      expect(harness.writeCount, 4);
      await harness.dispose();
    },
  );

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
      final failure = expectLater(send, throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      harness.physicalDisconnect();
      await Future<void>.delayed(Duration.zero);
      harness.completeWrite(0);
      await failure;

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
      final failure = expectLater(send, throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);

      await harness.transport.disconnect();
      harness.completeWrite(0);
      await failure;

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
    final failure = expectLater(staleSend, throwsA(isA<StateError>()));
    await Future<void>.delayed(Duration.zero);
    harness.physicalDisconnect();
    await Future<void>.delayed(Duration.zero);
    harness.completeWrite(0);
    await failure;

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
  _WriteHarness._({
    BleWakeStreamFactory? wakeStreamProvider,
    List<Duration>? wakeRetryDelays,
    RefreshDiagnosticHistory? diagnosticHistory,
  }) {
    transport = BluetoothDeviceTransport(
      diagnosticHistory: diagnosticHistory,
      scanTimeout: const Duration(milliseconds: 10),
      bleStatusProvider: () => BleStatus.ready,
      scanStreamProvider: () => scan.stream,
      connectionStreamProvider:
          ({
            required id,
            required servicesWithCharacteristicsToDiscover,
            required connectionTimeout,
          }) => connection.stream,
      wakeStreamProvider: wakeStreamProvider ?? (_) => wake.stream,
      wakeRetryDelays:
          wakeRetryDelays ??
          const [
            Duration(seconds: 1),
            Duration(seconds: 2),
            Duration(seconds: 4),
          ],
      writeWithResponse: (characteristic, {required value}) {
        final completion = Completer<void>();
        writes.add(completion);
        packets.add(List<int>.of(value));
        return completion.future;
      },
    );
  }

  static Future<_WriteHarness> create({
    BleWakeStreamFactory? wakeStreamProvider,
    List<Duration>? wakeRetryDelays,
    RefreshDiagnosticHistory? diagnosticHistory,
  }) async {
    final harness = _WriteHarness._(
      wakeStreamProvider: wakeStreamProvider,
      wakeRetryDelays: wakeRetryDelays,
      diagnosticHistory: diagnosticHistory,
    );
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

  final wake = StreamController<List<int>>.broadcast();
  final scan = StreamController<DiscoveredDevice>.broadcast();
  final connection = StreamController<ConnectionStateUpdate>.broadcast();
  final writes = <Completer<void>>[];
  final packets = <List<int>>[];
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
    await wake.close();
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

FantasyMatchupSlateEntry _fantasyEntry(String id, {int week = 1}) =>
    FantasyMatchupSlateEntry(
      identity: id,
      matchup: FantasyMatchupDisplayData(
        leagueName: 'League',
        userName: 'User',
        userScore: 10,
        opponentName: 'Opponent',
        opponentScore: 5,
        week: week,
        status: FantasyMatchupDisplayStatus.live,
      ),
    );
