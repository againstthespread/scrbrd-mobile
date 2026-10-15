import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/live_refresh_coordinator.dart';
import 'package:sports_hub_mobile/refresh_diagnostic_history.dart';
import 'package:sports_hub_mobile/session_aware_device_sender.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  late DateTime now;
  late RefreshDiagnosticHistory history;
  late _Source source;
  late _Transport transport;
  late TrackedDeviceSession session;
  late SportsRepository repository;
  late LiveRefreshCoordinator live;
  setUp(() {
    now = DateTime.utc(2026, 10, 15, 12);
    history = RefreshDiagnosticHistory(clock: () => now);
    source = _Source();
    transport = _Transport();
    session = TrackedDeviceSession()
      ..recordTeamSlate(
        league: SportsLeague.mlb,
        selectedDate: now,
        games: [_game(1)],
      );
    repository = SportsRepository(source, diagnosticHistory: history);
    live = LiveRefreshCoordinator(
      repository: repository,
      transport: SessionAwareDeviceSender(
        transport: transport,
        session: session,
        diagnosticHistory: history,
      ),
      session: session,
      isBleConnected: () => true,
    );
  });
  tearDown(() {
    session.dispose();
    history.dispose();
  });

  test(
    'F20 unchanged scores refresh provider time without new BLE write',
    () async {
      await live.refreshTrackedSessionOnce();
      final first = history.freshness['sports:mlb']!;
      expect(first.providerState, 'fetched');
      expect(first.deliveryState, 'unchanged');
      expect(first.lastProviderSuccess, now);
      expect(first.lastBleWrite, isNull);
      now = now.add(const Duration(minutes: 2));
      final result = await live.refreshTrackedSessionOnce();
      expect(result.leagues[SportsLeague.mlb], SportsRefreshOutcome.unchanged);
      expect(result.succeeded, isTrue);
      expect(history.freshness['sports:mlb']!.lastProviderSuccess, now);
      expect(history.freshness['sports:mlb']!.lastBleWrite, isNull);
      expect(transport.writes, 0);
    },
  );

  test(
    'F20 failed provider retains cache and last successful timestamps',
    () async {
      source.score = 2;
      await live.refreshTrackedSessionOnce();
      final verified = history.freshness['sports:mlb']!;
      source.fail = true;
      now = now.add(const Duration(minutes: 3));
      final result = await live.refreshTrackedSessionOnce();
      final failed = history.freshness['sports:mlb']!;
      expect(result.succeeded, isFalse);
      expect(failed.providerState, 'failed');
      expect(failed.lastProviderSuccess, verified.lastProviderSuccess);
      expect(failed.lastBleWrite, verified.lastBleWrite);
      expect(
        (session[SportsLeague.mlb] as TrackedTeamSlate).games.single.awayScore,
        2,
      );
      expect(transport.writes, 1);
    },
  );

  test(
    'F20 failed BLE write keeps baseline retryable and provider success separate',
    () async {
      source.score = 2;
      transport.fail = true;
      final failed = await live.refreshTrackedSessionOnce();
      expect(failed.succeeded, isFalse);
      expect(history.freshness['sports:mlb']!.providerState, 'fetched');
      expect(history.freshness['sports:mlb']!.lastProviderSuccess, now);
      expect(history.freshness['sports:mlb']!.lastBleWrite, isNull);
      expect(history.freshness['sports:mlb']!.deliveryState, 'failed');
      expect(
        (session[SportsLeague.mlb] as TrackedTeamSlate).games.single.awayScore,
        1,
      );
      transport.fail = false;
      now = now.add(const Duration(seconds: 20));
      final retry = await live.refreshTrackedSessionOnce();
      expect(retry.succeeded, isTrue);
      expect(history.freshness['sports:mlb']!.lastBleWrite, now);
      expect(
        (session[SportsLeague.mlb] as TrackedTeamSlate).games.single.awayScore,
        2,
      );
    },
  );

  test(
    'F20 cancelled provider response does not mark cached data freshly verified',
    () async {
      source.pending = Completer<void>();
      final work = live.refreshTrackedSessionOnce();
      await Future<void>.delayed(Duration.zero);
      live.cancelCurrentRefresh('test generation invalidated');
      source.pending!.complete();
      final result = await work;
      expect(result.cancelled, isTrue);
      expect(result.succeeded, isFalse);
      expect(history.freshness['sports:mlb']!.providerState, 'cancelled');
      expect(history.freshness['sports:mlb']!.lastProviderSuccess, isNull);
      expect(transport.writes, 0);
    },
  );

  test(
    'F20 cancelled logical write neither timestamps nor advances baseline',
    () async {
      source.score = 2;
      transport.pending = Completer<void>();
      final work = live.refreshTrackedSessionOnce();
      await transport.started.future;
      live.cancelCurrentRefresh('test cancelled in flight');
      transport.pending!.complete();
      final result = await work;
      expect(result.cancelled, isTrue);
      expect(history.freshness['sports:mlb']!.deliveryState, 'cancelled');
      expect(history.freshness['sports:mlb']!.lastBleWrite, isNull);
      expect(
        (session[SportsLeague.mlb] as TrackedTeamSlate).games.single.awayScore,
        1,
      );
    },
  );

  test(
    'F20 empty valid fetch does not verify or erase retained cached slate',
    () async {
      source.empty = true;
      final result = await live.refreshTrackedSessionOnce();
      expect(history.freshness['sports:mlb']!.providerState, 'empty');
      expect(history.freshness['sports:mlb']!.deliveryState, 'retained');
      expect(history.freshness['sports:mlb']!.lastBleWrite, isNull);
      expect(result.succeeded, isFalse);
      expect(session[SportsLeague.mlb], isNotNull);
      expect(
        history.freshnessText,
        contains('empty fetches do not verify cached content'),
      );
    },
  );

  test('F20 cached write cannot manufacture provider verification', () async {
    final sender = SessionAwareDeviceSender(
      transport: transport,
      session: session,
      diagnosticHistory: history,
    );
    await sender.sendTeamSlate([_game(2)], selectedDate: now);
    expect(history.freshness['sports:mlb']!.lastProviderSuccess, isNull);
    expect(history.freshness['sports:mlb']!.lastBleWrite, now);
    expect(history.exportText(), contains('ESP=unconfirmed'));
  });

  test(
    'F20 later rejected write does not hide an in-flight completed write',
    () async {
      final pending = Completer<void>();
      final older = history.trackDelivery(
        'sports:mlb',
        () => pending.future,
        scope: 'old write',
      );
      await expectLater(
        history.trackDelivery(
          'sports:mlb',
          () async => throw StateError('busy'),
          scope: 'new write',
        ),
        throwsStateError,
      );
      now = now.add(const Duration(seconds: 1));
      pending.complete();
      await older;
      final result = history.freshness['sports:mlb']!;
      expect(result.deliveryState, 'failed');
      expect(result.deliveryScope, 'new write');
      expect(result.lastBleWrite, now);
      expect(result.lastBleWriteScope, 'old write');
    },
  );

  test('F20 late old fetch cannot overwrite a newer attempt', () async {
    final old = Completer<int>();
    final first = history.trackProvider(
      'sports:mlb',
      () => old.future,
      scope: 'old',
    );
    now = now.add(const Duration(seconds: 10));
    await history.trackProvider('sports:mlb', () async => 2, scope: 'new');
    final latest = history.freshness['sports:mlb']!;
    old.complete(1);
    await first;
    expect(history.freshness['sports:mlb'], same(latest));
    expect(latest.lastProviderSuccessScope, 'new');
  });

  test(
    'F20 failed newer scope keeps original successful-fetch scope',
    () async {
      await history.trackProvider(
        'sports:mlb',
        () async => 1,
        scope: 'yesterday',
      );
      now = now.add(const Duration(days: 1));
      await expectLater(
        history.trackProvider<int>(
          'sports:mlb',
          () async => throw StateError('private error'),
          scope: 'today',
        ),
        throwsStateError,
      );
      final value = history.freshness['sports:mlb']!;
      expect(value.providerScope, 'today');
      expect(value.lastProviderSuccessScope, 'yesterday');
      expect(history.exportText(), isNot(contains('private error')));
    },
  );

  test(
    'F20 freshness is bounded and survives timeline eviction and CLEAR',
    () async {
      await repository.fetchGamesForDate(SportsLeague.mlb, now);
      for (var i = 0; i < 600; i++) {
        history.add('event $i');
      }
      expect(history.freshness['sports:mlb']!.lastProviderSuccess, now);
      history.clear();
      expect(history.freshness['sports:mlb']!.lastProviderSuccess, now);
      for (var i = 0; i < 80; i++) {
        await history.trackProvider('fantasy:league:$i', () async => i);
      }
      expect(history.freshness.length, 64);
      expect(history.entries.length, lessThanOrEqualTo(512));
    },
  );
}

GameData _game(int score) => GameData(
  league: 'MLB',
  eventId: 'g',
  awayTeam: 'A',
  homeTeam: 'H',
  awayScore: score,
  homeScore: 0,
  status: 'LIVE',
  clock: 'Top 5th',
  scheduledStartTime: DateTime(2026, 10, 15),
);

class _Source implements SportsDataSource {
  int score = 1;
  bool fail = false;
  bool empty = false;
  Completer<void>? pending;
  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime date,
  ) async {
    if (pending != null) await pending!.future;
    if (fail) throw StateError('provider failed');
    return empty
        ? []
        : [
            SportsGame(
              league: 'MLB',
              eventId: 'g',
              awayTeam: 'A',
              homeTeam: 'H',
              awayScore: score,
              homeScore: 0,
              status: 'LIVE',
              clock: 'Top 5th',
              scheduledStartTime: date,
            ),
          ];
  }
}

class _Transport extends DeviceTransport {
  bool fail = false;
  int writes = 0;
  Completer<void>? pending;
  final started = Completer<void>();
  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    if (!started.isCompleted) started.complete();
    if (pending != null) await pending!.future;
    if (fail) throw StateError('write failed');
    writes++;
  }

  @override
  Future<void> sendGameData(GameData game) async {}
}
