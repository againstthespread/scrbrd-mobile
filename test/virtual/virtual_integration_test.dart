import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/ble_device_state.dart';
import 'package:sports_hub_mobile/bluetooth_device_transport.dart';
import 'package:sports_hub_mobile/fantasy_startup_outcome.dart';
import 'package:sports_hub_mobile/initial_device_sync_coordinator.dart';
import 'package:sports_hub_mobile/live_refresh_coordinator.dart';
import 'package:sports_hub_mobile/session_aware_device_sender.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

import 'support/fixture_source.dart';
import 'support/virtual_ble.dart';

void main() {
  group(
    'virtual mobile ↔ real native firmware',
    () {
      late Harness h;
      setUp(() async => h = Harness(VirtualBle(await NativeDevice.start())));
      tearDown(() async => h.close());

      test(
        'initial sync commits sports and fantasy, navigation survives refresh',
        () async {
          await h.start();
          expect(h.initial.snapshot.status, InitialSyncStatus.complete);
          expect(h.initial.snapshot.successfullySyncedLeagueCount, 3);
          expect((await h.state())['leagueCount'], 3);
          await h.select('NBA');
          await h.next();
          expect((await h.state())['eventId'], 'nba-2');
          expect((await h.state())['verified'], isTrue);
          h.source.score('nba-2', 31);
          final outcome = await h.live.refreshTrackedSessionOnce();
          expect(outcome.succeeded, isTrue);
          expect((await h.state())['eventId'], 'nba-2');
          expect((await h.state())['awayScore'], 31);
          await h.select('FANTASY');
          expect((await h.state())['identity'], 'fixture-espn');
          await h.next();
          expect((await h.state())['identity'], 'fixture-sleeper');
          expect((await h.state())['userScore'], closeTo(5.2, 0.001));
          await h.ble.transport.sendFantasySlate(h.source.fantasy);
          expect((await h.state())['identity'], 'fixture-sleeper');
        },
      );

      test(
        'WAKE drives production refresh; duplicate signals remain serialized',
        () async {
          await h.start();
          await h.select('NBA');
          h.source.score('nba-1', 44);
          h.ble.writeDelay = const Duration(milliseconds: 2);
          for (var i = 0; i < 4; i++) {
            h.ble.notifyWake();
          }
          await until(
            () =>
                h.wakeCount >= 4 &&
                h.refreshes >= 1 &&
                !h.initial.operationGate.isLiveRefreshActive,
          );
          expect((await h.state())['awayScore'], 44);
          expect(
            h.ble.transport.wakeSubscriptionHealth,
            WakeSubscriptionHealth.receiving,
          );
          await h.ble.transport.resumeWakeNotifications();
          h.ble.notifyWake();
          await until(
            () =>
                h.wakeCount == 5 &&
                !h.initial.operationGate.isLiveRefreshActive,
          );
          expect(h.errors, isEmpty);
        },
      );

      test(
        'dropped chunk retains firmware content despite successful native writes',
        () async {
          await h.start();
          await h.select('NBA');
          h.source.score('nba-1', 77);
          h.ble.faults[h.ble.packets.length + 2] = Fault.drop;
          final result = await h.live.refreshTrackedSessionOnce();
          // F34: ATT completion cannot establish ESP application-level acceptance.
          expect(
            result.leagues[SportsLeague.nba],
            SportsRefreshOutcome.written,
          );
          expect(
            (h.session[SportsLeague.nba] as TrackedTeamSlate)
                .games
                .first
                .awayScore,
            77,
          );
          expect((await h.state())['awayScore'], 10);
          h.source.score('nba-1', 78);
          await h.live.refreshTrackedSessionOnce();
          expect((await h.state())['awayScore'], 78);
        },
      );

      test(
        'disconnect mid-transaction cancels stale writes and reconnect sync recovers',
        () async {
          await h.start();
          await h.select('NBA');
          final before = h.session[SportsLeague.nba];
          h.source.score('nba-1', 65);
          final games = await h.repository.fetchGamesForDate(
            SportsLeague.nba,
            h.source.date,
          );
          h.ble.faults[h.ble.packets.length + 2] = Fault.hold;
          final failure = expectLater(
            h.sender.sendTeamSlate(games, selectedDate: h.source.date),
            throwsStateError,
          );
          await until(() => h.ble.held != null);
          expect((await h.state())['sportsStaging'], isTrue);
          await h.ble.disconnect();
          await failure;
          expect(h.session[SportsLeague.nba], same(before));
          expect((await h.state())['sportsStaging'], isFalse);
          expect((await h.state())['verified'], isFalse);
          expect((await h.state())['awayScore'], 10);
          await h
              .start(); // Scripted central reconnect; main does not yet contain F13.
          final writesAfterRecovery = h.ble.packets.length;
          h.ble
              .release(); // Obsolete plugin completion cannot restart old transfer.
          await Future<void>.delayed(const Duration(milliseconds: 5));
          expect(h.ble.packets.length, writesAfterRecovery);
          await h.select('NBA');
          expect((await h.state())['awayScore'], 65);
          h.source.score('nba-1', 66);
          h.ble.notifyWake();
          await until(
            () =>
                h.refreshes == 1 &&
                !h.initial.operationGate.isLiveRefreshActive,
          );
          expect((await h.state())['awayScore'], 66);
          expect(h.errors, isEmpty);
        },
      );

      test(
        'write failure does not advance delivered cache; next session recovers',
        () async {
          await h.start();
          final before = h.session[SportsLeague.nba];
          h.source.score('nba-1', 90);
          h.ble.faults[h.ble.packets.length + 1] = Fault.fail;
          final result = await h.live.refreshTrackedSessionOnce();
          expect(result.succeeded, isFalse);
          expect(h.session[SportsLeague.nba], same(before));
          await h.ble.disconnect();
          await h.start();
          await h.select('NBA');
          expect((await h.state())['awayScore'], 90);
        },
      );

      test(
        'delayed write timeout cannot deliver late data after disconnect',
        () async {
          await h.start();
          h.ble.faults[h.ble.packets.length + 1] = Fault.hold;
          final failed = expectLater(
            h.ble.transport.sendControlCommand('SYNC_START'),
            throwsStateError,
          );
          await failed;
          expect(
            h.ble.transport.currentSnapshot.errorMessage,
            contains('timed out'),
          );
          await h.ble.disconnect();
          h.ble.release();
          await h.start();
          expect(h.initial.snapshot.status, InitialSyncStatus.complete);
          expect(h.errors, isEmpty);
        },
      );

      test(
        'unavailable device and Bluetooth off fail without hidden reconnect loop',
        () async {
          h.ble.available = false;
          await expectLater(h.ble.connect(), throwsStateError);
          expect(h.ble.attempts, isEmpty);
          h.ble.available = true;
          await h.start();
          await h.ble.disconnect();
          final attempts = h.ble.attempts.length;
          h.ble.ready = false;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(h.ble.attempts, hasLength(attempts));
          expect(
            h.ble.transport.currentSnapshot.state,
            BleConnectionState.disconnected,
          );
          h.ble.ready = true;
          await h.start();
          expect(h.ble.attempts.last, VirtualBle.deviceId);
          expect(h.initial.snapshot.status, InitialSyncStatus.complete);
        },
      );

      test(
        'scripted disconnect fault aborts a multi-packet replacement',
        () async {
          await h.start();
          await h.select('NBA');
          h.source.score('nba-1', 70);
          final games = await h.repository.fetchGamesForDate(
            SportsLeague.nba,
            h.source.date,
          );
          final first = h.ble.packets.length;
          h.ble.faults[first + 2] = Fault.disconnect;
          await expectLater(
            h.sender.sendTeamSlate(games, selectedDate: h.source.date),
            throwsStateError,
          );
          expect(h.ble.packets.length, first + 2);
          expect((await h.state())['sportsStaging'], isFalse);
          expect((await h.state())['awayScore'], 10);
          await h.start();
          await h.select('NBA');
          expect((await h.state())['awayScore'], 70);
        },
      );

      test(
        'device disappears after scan; failed connect can be retried',
        () async {
          await h.ble.transport.scanForDevice();
          final selected = h.ble.transport.currentSnapshot.candidates.single;
          h.ble.available = false;
          await h.ble.transport.connectToDevice(selected);
          expect(
            h.ble.transport.currentSnapshot.state,
            BleConnectionState.error,
          );
          expect(h.ble.attempts, [VirtualBle.deviceId]);
          expect((await h.state())['connected'], isFalse);
          h.ble.available = true;
          await h.start();
          expect(h.initial.snapshot.status, InitialSyncStatus.complete);
          expect(h.ble.attempts, [VirtualBle.deviceId, VirtualBle.deviceId]);
        },
      );

      test(
        'provider outage retains native cached catalog and later retries succeed',
        () async {
          await h.start();
          await h.ble.disconnect();
          h.source.failures.add(SportsLeague.nba);
          final count = h.ble.packets.length;
          await h.start();
          expect(h.initial.snapshot.status, InitialSyncStatus.partialFailure);
          expect(
            h.ble.packets.skip(count).map(utf8.decode),
            isNot(contains('SYNC_START')),
          );
          await h.select('NBA');
          expect((await h.state())['awayScore'], 10);
          h.source.failures.clear();
          await h.initial.retryPendingSync();
          expect(h.initial.snapshot.status, InitialSyncStatus.complete);
          expect((await h.state())['leagueCount'], 3);
        },
      );
    },
    skip: Platform.environment['SCRBRD_VIRTUAL_DEVICE'] == null
        ? 'Run python3 tools/run_virtual_tests.py --firmware <firmware checkout> (native bridge required)'
        : false,
  );
}

Future<void> until(bool Function() condition) async {
  final timeout = Stopwatch()..start();
  while (!condition()) {
    if (timeout.elapsed > const Duration(seconds: 5)) {
      throw StateError('Virtual scenario failed to settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

class Harness {
  Harness(this.ble) {
    repository = SportsRepository(source);
    sender = SessionAwareDeviceSender(
      transport: ble.transport,
      session: session,
    );
    initial = InitialDeviceSyncCoordinator(
      repository: repository,
      sender: sender,
      isBleConnected: () =>
          ble.transport.currentSnapshot.state.isPhysicallyConnected,
      clock: () => source.date,
      onAuthoritativeSyncStarted: session.clear,
      prepareFantasyCategory: () async => PreparedFantasyStartup(
        hasContent: true,
        commit: () async {
          await ble.transport.sendFantasySlate(source.fantasy);
          return const FantasyStartupOutcome(hasContent: true);
        },
      ),
    );
    live = LiveRefreshCoordinator(
      repository: repository,
      transport: sender,
      session: session,
      isBleConnected: () =>
          ble.transport.currentSnapshot.state.isPhysicallyConnected,
    );
    snapshots = ble.transport.snapshots.listen((s) {
      if (s.state == BleConnectionState.disconnected ||
          s.state == BleConnectionState.error) {
        initial.handleConnectionState(s.state);
        live.cancelCurrentRefresh('virtual session ended');
      }
    });
    wakes = ble.transport.wakeNotifications.listen((_) {
      wakeCount++;
      unawaited(
        initial.operationGate
            .requestLiveRefresh(() async {
              final result = await live.refreshTrackedSessionOnce();
              if (!result.succeeded) errors.add('WAKE refresh failed');
              refreshes++;
            })
            .catchError((Object e) {
              errors.add('$e');
            }),
      );
    });
  }
  final VirtualBle ble;
  final source = FixtureSource();
  final session = TrackedDeviceSession();
  late final SportsRepository repository;
  late final SessionAwareDeviceSender sender;
  late final InitialDeviceSyncCoordinator initial;
  late final LiveRefreshCoordinator live;
  late final StreamSubscription<BleDeviceSnapshot> snapshots;
  late final StreamSubscription<List<int>> wakes;
  final errors = <String>[];
  int wakeCount = 0, refreshes = 0;
  static int _id = 0;
  final id = ++_id;
  Future<void> start() async {
    await ble.connect();
    await initial.startForConnectionForTest();
  }

  Future<Map<String, dynamic>> state() => ble.device.state();
  Future<void> select(String league) async {
    await ble.device.request({'op': 'select', 'league': league});
  }

  Future<void> next() async {
    await ble.device.request({'op': 'next'});
  }

  Future<void> close() async {
    await wakes.cancel();
    await snapshots.cancel();
    initial.handleConnectionState(BleConnectionState.disconnected);
    live.cancelCurrentRefresh('virtual session ended');
    await ble.close('scenario-$id');
    repository.dispose();
    session.dispose();
  }
}
