import 'dart:async';
import 'package:sports_hub_mobile/logical_device_transaction.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sports_hub_mobile/fantasy_alert_packet_serializer.dart';
import 'package:sports_hub_mobile/fantasy_alert_transport.dart';
import 'package:sports_hub_mobile/fantasy_live_observation_coordinator.dart';
import 'package:sports_hub_mobile/fantasy_matchup_display_data.dart';
import 'package:sports_hub_mobile/fantasy_matchup_transport.dart';
import 'package:sports_hub_mobile/fantasy_point_alert.dart';
import 'package:sports_hub_mobile/fantasy_point_delta_tracker.dart';
import 'package:sports_hub_mobile/pending_fantasy_alert_store.dart';
import 'package:sports_hub_mobile/refresh_diagnostic_history.dart';
import 'package:sports_hub_mobile/sleeper_api_client.dart';
import 'package:sports_hub_mobile/sleeper_fantasy_config.dart';
import 'package:sports_hub_mobile/sleeper_fantasy_repository.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';
import 'package:sports_hub_mobile/sleeper_player_repository.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  group('Sleeper-only fantasy runtime', () {
    late _ConfigStore config;
    late _Transport transport;
    late List<SleeperLeagueSnapshot> snapshots;
    late int loads;
    late int metadataResolutions;
    late FantasyLiveObservationCoordinator coordinator;
    late RefreshDiagnosticHistory history;
    late DateTime now;
    var failLoad = false;

    setUp(() {
      now = DateTime.utc(2026, 10, 15, 12);
      history = RefreshDiagnosticHistory(clock: () => now);
      failLoad = false;
      addTearDown(history.dispose);
      config = _ConfigStore(
        const SleeperFantasyConfig(leagueId: 'league-1', rosterId: 1),
      );
      transport = _Transport();
      snapshots = [_snapshot()];
      loads = 0;
      metadataResolutions = 0;
      final api = SleeperApiClient(
        client: MockClient((_) async => throw 'unused'),
      );
      coordinator = FantasyLiveObservationCoordinator(
        configStore: config,
        repository: SleeperFantasyRepository(api),
        playerRepository: SleeperPlayerRepository(apiClient: api),
        transport: transport,
        diagnosticHistory: history,
        isBleConnected: () => transport.connected,
        matchupLoader: (_) async {
          if (failLoad) throw StateError('provider unavailable');
          final index = loads < snapshots.length ? loads : snapshots.length - 1;
          loads++;
          return snapshots[index];
        },
        metadataResolver: (ids) async {
          metadataResolutions++;
          return {
            for (final id in ids)
              if (id == 'user-player') id: _chase,
          };
        },
      );
    });

    test(
      'F20 failed matchup write cannot report observation success',
      () async {
        transport.failMatchup = true;
        final result = await coordinator.observe();
        expect(result.succeeded, isFalse);
        expect(result.deliveryError, isNotNull);
        expect(coordinator.status.lastResult, contains('BLE'));
        transport.failMatchup = false;
        final retry = await coordinator.observe();
        expect(retry.succeeded, isTrue);
        expect(transport.matchups, hasLength(1));
      },
    );

    test(
      'F20 failed alert reports failure and stays eligible for retry',
      () async {
        snapshots = [_snapshot(), _snapshot(userPoints: 10)];
        await coordinator.observe();
        transport.fail = true;
        final failed = await coordinator.observe();
        expect(failed.succeeded, isFalse);
        expect(failed.deliveryError, isNotNull);
        expect(failed.pendingAlerts, 1);
        transport.fail = false;
        final retry = await coordinator.observe();
        expect(retry.succeeded, isTrue);
        expect(retry.pendingAlerts, 0);
        expect(transport.alerts, hasLength(1));
      },
    );

    test(
      'F29 an alert queued behind manual ownership retries after write failure',
      () async {
        final queued = _QueuedTransport();
        final api = SleeperApiClient(
          client: MockClient((_) async => throw 'unused'),
        );
        var snapshot = _snapshot();
        final runtime = FantasyLiveObservationCoordinator(
          configStore: config,
          repository: SleeperFantasyRepository(api),
          playerRepository: SleeperPlayerRepository(apiClient: api),
          transport: queued,
          isBleConnected: () => true,
          matchupLoader: (_) async => snapshot,
          metadataResolver: (_) async => {'user-player': _chase},
        );
        await runtime.observe();
        final release = Completer<void>();
        final manual = queued.runTransaction(() => release.future);
        snapshot = _snapshot(userPoints: 10);
        final operation = runtime.observe();
        await Future<void>.delayed(Duration.zero);
        expect(queued.alerts, isEmpty);
        queued.fail = true;
        release.complete();
        await manual;
        final failed = await operation;
        expect(failed.succeeded, isFalse);
        expect(failed.pendingAlerts, 1);
        queued.fail = false;
        expect((await runtime.observe()).succeeded, isTrue);
        expect(queued.alerts, hasLength(1));
        expect(runtime.status.pendingAlerts, 0);
        runtime.dispose();
      },
    );

    test('F29 disposed observation cannot send or notify', () async {
      final api = SleeperApiClient(
        client: MockClient((_) async => throw 'unused'),
      );
      final loaded = Completer<SleeperLeagueSnapshot>();
      final runtime = FantasyLiveObservationCoordinator(
        configStore: config,
        repository: SleeperFantasyRepository(api),
        playerRepository: SleeperPlayerRepository(apiClient: api),
        transport: transport,
        isBleConnected: () => transport.connected,
        matchupLoader: (_) => loaded.future,
        metadataResolver: (_) async => {},
      );
      final operation = runtime.observe();
      await Future<void>.delayed(Duration.zero);
      runtime.dispose();
      loaded.complete(_snapshot());
      final result = await operation;
      expect(result.succeeded, isFalse);
      expect(transport.matchups, isEmpty);
    });

    test('F20 cancelled observation cannot report success', () async {
      final api = SleeperApiClient(
        client: MockClient((_) async => throw 'unused'),
      );
      final loaded = Completer<SleeperLeagueSnapshot>();
      coordinator = FantasyLiveObservationCoordinator(
        configStore: config,
        repository: SleeperFantasyRepository(api),
        playerRepository: SleeperPlayerRepository(apiClient: api),
        transport: transport,
        isBleConnected: () => transport.connected,
        matchupLoader: (_) => loaded.future,
        metadataResolver: (_) async => {},
      );
      final operation = coordinator.observe();
      await Future<void>.delayed(Duration.zero);
      coordinator.endConnectionSession();
      loaded.complete(_snapshot());
      final result = await operation;
      expect(result.succeeded, isFalse);
      expect(transport.matchups, isEmpty);
    });

    test('F20 fantasy unchanged refresh advances fetch time only', () async {
      final first = await coordinator.observe();
      expect(first.deliveryState, 'written');
      final writeAt = history.freshness['fantasy:matchup']!.lastBleWrite;
      now = now.add(const Duration(seconds: 20));
      final unchanged = await coordinator.observe();
      expect(unchanged.providerSucceeded, isTrue);
      expect(unchanged.deliveryState, 'unchanged');
      expect(
        history.freshness['fantasy:sleeper:league-1']!.lastProviderSuccess,
        now,
      );
      expect(history.freshness['fantasy:matchup']!.lastBleWrite, writeAt);
    });

    test(
      'F20 provider failure does not refresh retained fantasy cache',
      () async {
        final initial = await coordinator.observe();
        final fetched =
            history.freshness['fantasy:sleeper:league-1']!.lastProviderSuccess;
        final written = history.freshness['fantasy:matchup']!.lastBleWrite;
        now = now.add(const Duration(minutes: 5));
        failLoad = true;
        final failed = await coordinator.observe();
        expect(failed.providerSucceeded, isFalse);
        expect(failed.succeeded, isFalse);
        expect(failed.matchup, same(initial.matchup));
        expect(
          history.freshness['fantasy:sleeper:league-1']!.providerState,
          'failed',
        );
        expect(
          history.freshness['fantasy:sleeper:league-1']!.lastProviderSuccess,
          fetched,
        );
        expect(history.freshness['fantasy:matchup']!.lastBleWrite, written);
      },
    );

    test('F20 failed fantasy write preserves prior delivery time', () async {
      snapshots = [_snapshot(), _snapshot(userTotal: 100)];
      await coordinator.observe();
      final written = history.freshness['fantasy:matchup']!.lastBleWrite;
      now = now.add(const Duration(seconds: 20));
      transport.failMatchup = true;
      final failed = await coordinator.observe();
      expect(failed.providerSucceeded, isTrue);
      expect(failed.succeeded, isFalse);
      expect(failed.deliveryState, 'failed');
      expect(
        history.freshness['fantasy:sleeper:league-1']!.lastProviderSuccess,
        now,
      );
      expect(history.freshness['fantasy:matchup']!.lastBleWrite, written);
    });

    test(
      'F20 intentionally queued alerts are distinct from completed writes',
      () async {
        snapshots = [_snapshot(), _snapshot(userPoints: 10)];
        await coordinator.observe();
        final queued = await coordinator.observe(sendAlerts: false);
        expect(queued.providerSucceeded, isTrue);
        expect(queued.succeeded, isFalse);
        expect(queued.deliveryState, 'queued');
        expect(queued.leagues.values.single.succeeded, isFalse);
        expect(queued.pendingAlerts, 1);
        expect(history.freshness['fantasy:alerts']!.lastBleWrite, isNull);
        final retried = await coordinator.observe();
        expect(retried.succeeded, isTrue);
        expect(history.freshness['fantasy:alerts']!.lastBleWrite, now);
        expect(transport.alerts, hasLength(1));
      },
    );

    test(
      'F20 startup baseline reuse is not a new provider verification',
      () async {
        await coordinator.establishStartupBaseline();
        final fetched =
            history.freshness['fantasy:sleeper:league-1']!.lastProviderSuccess;
        now = now.add(const Duration(minutes: 10));
        await coordinator.establishStartupBaseline();
        expect(loads, 1);
        expect(
          history.freshness['fantasy:sleeper:league-1']!.lastProviderSuccess,
          fetched,
        );
      },
    );

    test(
      'F20 late alert completion cannot consume or timestamp a new session',
      () async {
        snapshots = [_snapshot(), _snapshot(userPoints: 10)];
        await coordinator.observe();
        final gate = Completer<void>();
        transport.gate = gate.future;
        final work = coordinator.observe();
        await transport.sendStarted.future;
        coordinator.endConnectionSession();
        coordinator.beginConnectionSession();
        gate.complete();
        final cancelled = await work;
        expect(cancelled.cancelled, isTrue);
        expect(cancelled.succeeded, isFalse);
        expect(history.freshness['fantasy:alerts']!.lastBleWrite, isNull);
        expect(history.freshness['fantasy:alerts']!.deliveryState, 'cancelled');
      },
    );

    test(
      'F20 cancelled persistent write stays eligible on next observation',
      () async {
        final gate = Completer<void>();
        transport.matchupGate = gate.future;
        final work = coordinator.observe();
        await transport.matchupStarted.future;
        coordinator.endConnectionSession();
        coordinator.beginConnectionSession();
        gate.complete();
        final cancelled = await work;
        expect(cancelled.succeeded, isFalse);
        expect(coordinator.deviceSession.baseline, isNull);
        expect(history.freshness['fantasy:matchup']!.lastBleWrite, isNull);
        transport.matchupGate = null;
        await coordinator.observe();
        expect(coordinator.deviceSession.baseline, isNotNull);
        expect(history.freshness['fantasy:matchup']!.lastBleWrite, now);
      },
    );

    test(
      'F20 failed fantasy clear is reported and remains retryable',
      () async {
        await coordinator.observe();
        await config.clear();
        transport.failClear = true;
        final failed = await coordinator.observe();
        expect(failed.succeeded, isFalse);
        expect(failed.deliveryError, isNotNull);
        expect(history.freshness['fantasy:clear']!.lastBleWrite, isNull);
        transport.failClear = false;
        final retry = await coordinator.observe();
        expect(retry.succeeded, isTrue);
        expect(history.freshness['fantasy:clear']!.lastBleWrite, now);
      },
    );

    test('first observation establishes baseline and emits no alert', () async {
      final result = await coordinator.observe();
      expect(result.baselineReset, isTrue);
      expect(result.alerts, isEmpty);
      expect(transport.alerts, isEmpty);
      expect(transport.matchups, hasLength(1));
    });

    test('0-0 resolved Week 1 matchup sends as upcoming', () async {
      snapshots = [
        _snapshot(
          week: 1,
          userPoints: 0,
          opponentPoints: 0,
          userTotal: 0,
          opponentTotal: 0,
        ),
      ];
      await coordinator.establishStartupBaseline();
      expect(transport.matchups.single.week, 1);
      expect(
        transport.matchups.single.status,
        FantasyMatchupDisplayStatus.upcoming,
      );
    });

    test(
      'unchanged matchup skips persistent send; score change sends',
      () async {
        snapshots = [_snapshot(), _snapshot(), _snapshot(userTotal: 105.7)];
        await coordinator.observe();
        await coordinator.observe();
        expect(transport.matchups, hasLength(1));
        await coordinator.observe();
        expect(transport.matchups, hasLength(2));
        expect(transport.matchups.last.userScore, 105.7);
      },
    );

    test('failed persistent send retains baseline for next wake', () async {
      snapshots = [_snapshot(), _snapshot(userTotal: 105.7)];
      await coordinator.observe();
      transport.failMatchup = true;
      await coordinator.observe();
      expect(transport.matchups, hasLength(1));
      transport.failMatchup = false;
      await coordinator.observe();
      expect(transport.matchups, hasLength(2));
    });

    test('long names send and advance the normalized device baseline', () async {
      snapshots = [
        _snapshot(
          leagueName:
              'A very long Sleeper league name that exceeds forty-eight characters',
          userName: 'The Extremely Long Home Team Name',
          opponentName: 'The Extremely Long Away Team Name',
        ),
      ];
      await coordinator.observe();
      await coordinator.observe();
      expect(transport.matchups, hasLength(1));
      expect(
        utf8.encode(transport.matchups.single.leagueName).length,
        lessThanOrEqualTo(48),
      );
      expect(
        utf8.encode(transport.matchups.single.userName).length,
        lessThanOrEqualTo(20),
      );
      expect(coordinator.deviceSession.baseline, transport.matchups.single);
    });

    test('user delta sends once, unchanged wake does not resend', () async {
      snapshots = [
        _snapshot(),
        _snapshot(userPoints: 23.4, userTotal: 104.7),
        _snapshot(userPoints: 23.4, userTotal: 104.7),
      ];
      await coordinator.observe();
      final changed = await coordinator.observe();
      await coordinator.observe();
      expect(changed.alerts.single.delta.delta, 15);
      expect(transport.alerts, hasLength(1));
      expect(transport.alerts.single.player?.fullName, "Ja'Marr Chase");
    });

    test(
      'opponent, fractional, and negative deltas are authoritative',
      () async {
        snapshots = [
          _snapshot(),
          _snapshot(opponentPoints: 6.25, opponentTotal: 89.45),
          _snapshot(opponentPoints: 5.75, opponentTotal: 88.95),
        ];
        await coordinator.observe();
        expect((await coordinator.observe()).alerts.single.delta.delta, 1.25);
        expect((await coordinator.observe()).alerts.single.delta.delta, -0.5);
      },
    );

    test('missing metadata falls back without blocking the alert', () async {
      snapshots = [_snapshot(), _snapshot(opponentPoints: 7)];
      await coordinator.observe();
      await coordinator.observe();
      expect(transport.alerts.single.player, isNull);
      final packet = const FantasyAlertPacketSerializer().serialize(
        transport.alerts.single,
      );
      expect(jsonDecode(utf8.decode(packet))['player'], 'opponent-player');
    });

    test(
      'mixed cached and missing players get independent names from one refresh',
      () async {
        var playerIndexRequests = 0;
        transport = _Transport();
        snapshots = [
          _snapshot(),
          _snapshot(userPoints: 10.4, secondUserPoints: 1, opponentPoints: 6),
        ];
        final api = SleeperApiClient(
          client: MockClient((request) async {
            playerIndexRequests++;
            expect(request.url.path, '/v1/players/nfl');
            return http.Response(
              jsonEncode({
                'second-user': _secondPlayer.toJson(),
                'opponent-player': _opponentPlayer.toJson(),
              }),
              200,
            );
          }),
        );
        coordinator = FantasyLiveObservationCoordinator(
          configStore: config,
          repository: SleeperFantasyRepository(api),
          playerRepository: SleeperPlayerRepository(
            apiClient: api,
            cache: _RuntimeMemoryPlayerCache(
              CachedSleeperPlayers(
                fetchedAt: DateTime.now(),
                players: {'user-player': _chase},
              ),
            ),
          ),
          transport: transport,
          isBleConnected: () => transport.connected,
          matchupLoader: (_) async => snapshots[loads++],
        );

        await coordinator.observe();
        final result = await coordinator.observe();

        expect(playerIndexRequests, 1);
        expect(result.alerts.map((alert) => alert.player?.fullName), [
          "Ja'Marr Chase",
          'Second Player',
          'Opponent Player',
        ]);
        expect(transport.alerts.map((alert) => alert.player?.fullName), [
          "Ja'Marr Chase",
          'Second Player',
          'Opponent Player',
        ]);
      },
    );

    test(
      'both simultaneous alerts drain in one observation with user priority',
      () async {
        snapshots = [
          _snapshot(),
          _snapshot(userPoints: 9.4, opponentPoints: 20),
          _snapshot(userPoints: 9.4, opponentPoints: 20),
        ];
        await coordinator.observe();
        await coordinator.observe();
        expect(transport.alerts, hasLength(2));
        expect(transport.alerts.first.delta.side, FantasyMatchupSide.user);
        expect(coordinator.pendingStore.length, 0);
        await coordinator.observe();
        expect(transport.alerts, hasLength(2));
        expect(transport.alerts.last.delta.side, FantasyMatchupSide.opponent);
      },
    );

    for (final interruption in ['none', 'failure', 'disconnect']) {
      test(
        'three simultaneous alerts: $interruption preserves order',
        () async {
          snapshots = [
            _snapshot(),
            _snapshot(
              userPoints: 10.4,
              secondUserPoints: 1,
              opponentPoints: 20,
            ),
          ];
          await coordinator.observe();
          if (interruption == 'failure') transport.failAt = 2;
          if (interruption == 'disconnect') transport.disconnectAfter = 1;
          final result = await coordinator.observe();
          expect(result.alerts, hasLength(3));
          if (interruption != 'none') {
            expect(transport.alerts.map((a) => a.delta.playerId), [
              'user-player',
            ]);
            expect(coordinator.pendingStore.length, 2);
            expect(
              coordinator.pendingStore.next!.alert.delta.playerId,
              'second-user',
            );
            expect(transport.attempts, interruption == 'failure' ? 2 : 1);
            transport.failAt = null;
            transport.disconnectAfter = null;
            transport.connected = true;
            await coordinator.observe();
          }
          expect(transport.alerts.map((a) => a.delta.playerId), [
            'user-player',
            'second-user',
            'opponent-player',
          ]);
          expect(coordinator.pendingStore.length, 0);
          await coordinator.observe();
          expect(transport.alerts, hasLength(3));
        },
      );
    }

    test(
      'drain awaits each send and excludes overlapping observations',
      () async {
        snapshots = [_snapshot(), _snapshot(userPoints: 10, opponentPoints: 6)];
        await coordinator.observe();
        final gate = Completer<void>();
        transport.gate = gate.future;
        final observation = coordinator.observe();
        await transport.sendStarted.future;
        expect(transport.attempts, 1);
        expect(coordinator.pendingStore.length, 2);
        await coordinator.observe();
        expect(transport.attempts, 1);
        gate.complete();
        await observation;
        expect(transport.alerts, hasLength(2));
        expect(coordinator.pendingStore.length, 0);
      },
    );

    test('BLE failure retains alert and later wake retries it', () async {
      snapshots = [
        _snapshot(),
        _snapshot(userPoints: 10),
        _snapshot(userPoints: 10),
      ];
      await coordinator.observe();
      transport.fail = true;
      await coordinator.observe();
      expect(coordinator.status.pendingAlerts, 1);
      transport.fail = false;
      await coordinator.observe();
      expect(transport.alerts, hasLength(1));
      expect(coordinator.status.pendingAlerts, 0);
    });

    test(
      'retry preserves both matchup totals captured for each event',
      () async {
        snapshots = [
          _snapshot(
            userPoints: 10,
            userTotal: 100,
            opponentPoints: 5,
            opponentTotal: 80,
          ),
          _snapshot(
            userPoints: 11,
            userTotal: 101,
            opponentPoints: 5,
            opponentTotal: 83,
          ),
          _snapshot(
            userPoints: 13,
            userTotal: 103,
            opponentPoints: 5,
            opponentTotal: 85,
          ),
        ];
        await coordinator.observe();
        transport.fail = true;
        await coordinator.observe();
        await coordinator.observe();
        transport.fail = false;
        await coordinator.observe();
        expect(transport.alerts.map((a) => a.delta.delta), [1, 2]);
        expect(transport.alerts.map((a) => a.userScore), [101, 103]);
        expect(transport.alerts.map((a) => a.opponentScore), [83, 85]);
        expect(coordinator.status.pendingAlerts, 0);
      },
    );

    test('startup baseline is owned once per connection session', () async {
      await coordinator.establishStartupBaseline();
      await coordinator.establishStartupBaseline();
      expect(loads, 1);
      expect(transport.alerts, isEmpty);
    });

    test('a new connection session resends persistent device state', () async {
      await coordinator.establishStartupBaseline();
      coordinator.endConnectionSession();
      coordinator.beginConnectionSession();
      await coordinator.establishStartupBaseline();
      expect(transport.matchups, hasLength(2));
    });

    test(
      'manual then automatic observation cannot duplicate transition',
      () async {
        snapshots = [
          _snapshot(),
          _snapshot(userPoints: 10),
          _snapshot(userPoints: 10),
        ];
        await coordinator.establishStartupBaseline();
        await coordinator.observe();
        await coordinator.observe();
        expect(transport.alerts, hasLength(1));
      },
    );

    test(
      'week or opponent change creates a clean zero-alert baseline',
      () async {
        snapshots = [
          _snapshot(),
          _snapshot(week: 9, opponentRosterId: 3, userPoints: 40),
        ];
        await coordinator.observe();
        final result = await coordinator.observe();
        expect(result.baselineReset, isTrue);
        expect(result.alerts, isEmpty);
      },
    );

    test(
      'ordinary observations resolve metadata without player download',
      () async {
        snapshots = [_snapshot(), _snapshot(userPoints: 10)];
        await coordinator.observe();
        await coordinator.observe();
        expect(metadataResolutions, 2);
        // The injected cached resolver is the only metadata path used.
        expect(loads, 2);
      },
    );

    test('alerts OFF persists and suppresses BLE delivery', () async {
      snapshots = [_snapshot(), _snapshot(userPoints: 20, userTotal: 105.7)];
      await coordinator.observe();
      await coordinator.setAlertsEnabled(false);
      await coordinator.observe();
      expect((await config.read())!.alertsEnabled, isFalse);
      expect(transport.alerts, isEmpty);
      expect(transport.matchups, hasLength(2));
    });

    test('removing configuration sends fantasy clear only', () async {
      await coordinator.observe();
      await coordinator.removeConfiguration();
      expect(transport.clears, 1);
      expect(await config.read(), isNull);
      expect(transport.matchups, hasLength(1));
    });

    test(
      're-enabling establishes a baseline without historical alerts',
      () async {
        snapshots = [
          _snapshot(),
          _snapshot(userPoints: 20),
          _snapshot(userPoints: 20),
          _snapshot(userPoints: 21),
        ];
        await coordinator.observe();
        await coordinator.setAlertsEnabled(false);
        await coordinator.observe();
        await coordinator.setAlertsEnabled(true);
        final baseline = await coordinator.observe();
        expect(baseline.baselineReset, isTrue);
        expect(transport.alerts, isEmpty);
        await coordinator.observe();
        expect(transport.alerts.single.delta.delta, 1);
      },
    );

    test(
      'test alert uses existing transport and handles disconnection',
      () async {
        transport.connected = false;
        expect(await coordinator.sendTestAlert(), isFalse);
        transport.connected = true;
        expect(await coordinator.sendTestAlert(), isTrue);
        expect(transport.alerts.single.delta.delta, 12);
      },
    );
  });

  test('changing league atomically clears an old roster selection', () async {
    final store = _ConfigStore(
      const SleeperFantasyConfig(leagueId: 'old', rosterId: 3),
    );
    final api = SleeperApiClient(
      client: MockClient((_) async => throw 'unused'),
    );
    final coordinator = FantasyLiveObservationCoordinator(
      configStore: store,
      repository: SleeperFantasyRepository(api),
      playerRepository: SleeperPlayerRepository(apiClient: api),
      transport: _Transport(),
      isBleConnected: () => true,
      setupLoader: (_) async => _snapshot(),
      matchupLoader: (_) async => _snapshot(),
      metadataResolver: (_) async => const {},
    );
    await coordinator.configureLeague('new');
    expect((await store.read())!.leagueId, 'new');
    expect((await store.read())!.rosterId, isNull);
  });

  test(
    'pending store retains bursts and deduplicates delivered transitions',
    () {
      final store = PendingFantasyAlertStore();
      for (var index = 0; index < 20; index++) {
        store.add(PendingFantasyAlert(id: '$index', alert: _alert('$index')));
      }
      expect(store.length, 20);
      store.markDelivered('0');
      expect(
        store.add(PendingFantasyAlert(id: '0', alert: _alert('0'))),
        isFalse,
      );
    },
  );

  test(
    'firmware-compatible packet uses empty fallback fields and <=512 bytes',
    () {
      final packet = const FantasyAlertPacketSerializer().serialize(
        _alert('user-player', player: _chase),
      );
      final json = jsonDecode(utf8.decode(packet)) as Map<String, dynamic>;
      expect(packet.length, lessThanOrEqualTo(512));
      expect(json['type'], 'fantasy_alert');
      expect(json['headline'], '');
      expect(json['confidence'], 'none');
      expect(json['points'], 1.0);
    },
  );

  test(
    'fantasy alert transport does not mutate tracked sports session',
    () async {
      final session = TrackedDeviceSession();
      final before = session.snapshot();
      await _Transport().sendFantasyAlert(_alert('1'));
      expect(session.snapshot(), before);
    },
  );

  test('fantasy failure does not prevent the sports WAKE domain', () async {
    var sportsRan = false;
    await runIsolatedWakeDomains(
      refreshSports: () async => sportsRan = true,
      observeFantasy: () async => throw StateError('Sleeper unavailable'),
    );
    expect(sportsRan, isTrue);
  });

  test('sports failure does not prevent the fantasy WAKE domain', () async {
    var fantasyRan = false;
    await runIsolatedWakeDomains(
      refreshSports: () async => throw StateError('sports unavailable'),
      observeFantasy: () async => fantasyRan = true,
    );
    expect(fantasyRan, isTrue);
  });
}

class _ConfigStore implements SleeperFantasyConfigStore {
  _ConfigStore(this.value);
  SleeperFantasyConfig? value;

  @override
  Future<SleeperFantasyConfig?> read() async => value;

  @override
  Future<void> save(SleeperFantasyConfig config) async => value = config;

  @override
  Future<void> clear() async => value = null;
}

class _Transport implements FantasyAlertTransport, FantasyMatchupTransport {
  final alerts = <FantasyPointAlert>[];
  final matchups = <FantasyMatchupDisplayData>[];
  bool connected = true;
  bool fail = false;
  bool failMatchup = false;
  bool failClear = false;
  int clears = 0;
  int attempts = 0;
  int? failAt;
  int? disconnectAfter;
  Future<void>? gate;
  Future<void>? matchupGate;
  final matchupStarted = Completer<void>();
  final sendStarted = Completer<void>();

  @override
  Future<void> sendFantasyAlert(FantasyPointAlert alert) async {
    attempts++;
    if (!sendStarted.isCompleted) sendStarted.complete();
    if (gate != null) await gate;
    if (fail || attempts == failAt) throw StateError('BLE failed');
    alerts.add(alert);
    if (alerts.length == disconnectAfter) connected = false;
  }

  @override
  Future<void> sendFantasyMatchup(FantasyMatchupDisplayData matchup) async {
    if (!matchupStarted.isCompleted) matchupStarted.complete();
    if (matchupGate != null) await matchupGate;
    if (failMatchup) throw StateError('matchup BLE failed');
    matchups.add(matchup);
  }

  @override
  Future<void> clearFantasyMatchup() async {
    if (failClear) throw StateError('clear write failed');
    clears++;
  }
}

SleeperLeagueSnapshot _snapshot({
  int week = 8,
  int opponentRosterId = 2,
  double userPoints = 8.4,
  double secondUserPoints = 0,
  double opponentPoints = 5,
  double userTotal = 89.7,
  double opponentTotal = 88.2,
  String leagueName = 'Friends',
  String userName = 'Peter',
  String opponentName = 'Mike',
}) => SleeperLeagueSnapshot(
  league: SleeperLeague(
    leagueId: 'league-1',
    name: leagueName,
    season: '2026',
    status: 'in_season',
    scoringSettings: {},
    rosterPositions: [],
  ),
  week: week,
  users: [
    SleeperUser(userId: 'u1', displayName: userName),
    SleeperUser(userId: 'u2', displayName: opponentName),
  ],
  rosters: [
    const SleeperRoster(
      rosterId: 1,
      ownerId: 'u1',
      players: ['user-player', 'second-user'],
      starters: ['user-player', 'second-user'],
    ),
    SleeperRoster(
      rosterId: opponentRosterId,
      ownerId: 'u2',
      players: const ['opponent-player'],
      starters: const ['opponent-player'],
    ),
  ],
  matchups: [
    SleeperMatchup(
      rosterId: 1,
      matchupId: 7,
      points: userTotal,
      starters: const ['user-player', 'second-user'],
      playerPoints: {
        'user-player': userPoints,
        'second-user': secondUserPoints,
      },
    ),
    SleeperMatchup(
      rosterId: opponentRosterId,
      matchupId: 7,
      points: opponentTotal,
      starters: const ['opponent-player'],
      playerPoints: {'opponent-player': opponentPoints},
    ),
  ],
);

FantasyPointAlert _alert(String playerId, {SleeperFantasyPlayer? player}) =>
    FantasyPointAlert(
      delta: FantasyPointDelta(
        playerId: playerId,
        side: FantasyMatchupSide.user,
        previousPoints: 0,
        currentPoints: 1,
        delta: 1,
      ),
      player: player,
      userName: 'PETER',
      userScore: 104.7,
      opponentName: 'MIKE',
      opponentScore: 97.2,
    );

const _chase = SleeperFantasyPlayer(
  sleeperPlayerId: 'user-player',
  fullName: "Ja'Marr Chase",
  firstName: "Ja'Marr",
  lastName: 'Chase',
  position: 'WR',
  nflTeam: 'CIN',
  espnPlayerId: '4362628',
);

const _secondPlayer = SleeperFantasyPlayer(
  sleeperPlayerId: 'second-user',
  fullName: 'Second Player',
  firstName: 'Second',
  lastName: 'Player',
  position: 'WR',
  nflTeam: 'BUF',
  espnPlayerId: null,
);

const _opponentPlayer = SleeperFantasyPlayer(
  sleeperPlayerId: 'opponent-player',
  fullName: 'Opponent Player',
  firstName: 'Opponent',
  lastName: 'Player',
  position: 'RB',
  nflTeam: 'MIA',
  espnPlayerId: null,
);

class _RuntimeMemoryPlayerCache implements SleeperPlayerCache {
  _RuntimeMemoryPlayerCache(this.value);

  CachedSleeperPlayers? value;

  @override
  Future<CachedSleeperPlayers?> read() async => value;

  @override
  Future<void> write(CachedSleeperPlayers cache) async => value = cache;
}

class _QueuedTransport extends _Transport implements LogicalDeviceTransport {
  final queue = LogicalDeviceTransactionQueue();
  @override
  Future<T> runTransaction<T>(
    Future<T> Function() operation, {
    bool Function()? isCurrent,
  }) => queue.run(operation, isCurrent: isCurrent);
  @override
  Future<void> sendFantasyAlert(FantasyPointAlert alert) =>
      queue.run(() => super.sendFantasyAlert(alert));
  @override
  Future<void> sendFantasyMatchup(FantasyMatchupDisplayData matchup) =>
      queue.run(() => super.sendFantasyMatchup(matchup));
}
