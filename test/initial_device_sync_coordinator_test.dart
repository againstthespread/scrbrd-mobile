import 'dart:async';
import 'package:sports_hub_mobile/fantasy_startup_outcome.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/ble_device_state.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_data_source.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/initial_device_sync_coordinator.dart';
import 'package:sports_hub_mobile/session_aware_device_sender.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';
import 'package:sports_hub_mobile/device_content_preferences.dart';

void main() {
  group('F07 cached reconnect', () {
    void cached(_Harness harness) {
      harness.session.recordTeamSlate(
        league: SportsLeague.nfl,
        selectedDate: DateTime(2026, 8, 21),
        games: [_game('NFL')],
      );
      harness.transport.received.addAll(['NFL', 'NBA']);
    }

    test(
      'pending provider fetch must not reset device or phone cache',
      () async {
        final pending = Completer<List<SportsGame>>();
        final harness = _Harness(pendingFirstFetch: pending);
        cached(harness);
        final sync = harness.coordinator.startForConnectionForTest();
        await harness.settle();
        try {
          expect(harness.transport.controls, isEmpty);
          expect(harness.transport.received, {'NFL', 'NBA'});
          expect(harness.session[SportsLeague.nfl], isNotNull);
        } finally {
          pending.complete([]);
          await sync;
        }
      },
    );

    test(
      'provider failure retains cached device and phone categories',
      () async {
        final harness = _Harness(fetchFailures: {SportsLeague.nfl});
        cached(harness);
        await harness.coordinator.startForConnectionForTest();
        expect(harness.transport.controls, isNot(contains('SYNC_START')));
        expect(harness.transport.received, {'NFL', 'NBA'});
        expect(harness.session[SportsLeague.nfl], isNotNull);
        expect(harness.coordinator.snapshot.status, InitialSyncStatus.failure);
      },
    );

    test(
      'partial provider success does not erase an unavailable category',
      () async {
        final harness = _Harness(
          fetchFailures: {SportsLeague.nfl},
          games: {
            SportsLeague.mlb: [_game('MLB')],
          },
        );
        cached(harness);
        await harness.coordinator.startForConnectionForTest();
        expect(harness.transport.controls, isNot(contains('SYNC_START')));
        expect(harness.transport.received, {'NFL', 'NBA', 'MLB'});
        expect(harness.session[SportsLeague.nfl], isNotNull);
        expect(harness.session[SportsLeague.mlb], isNotNull);
        expect(
          harness.coordinator.snapshot.status,
          InitialSyncStatus.partialFailure,
        );
      },
    );

    test(
      'invalid replacement data is rejected before destructive reset',
      () async {
        final harness = _Harness(
          games: {SportsLeague.nba: List.generate(73, (_) => _game('NBA'))},
        );
        cached(harness);
        await harness.coordinator.startForConnectionForTest();
        expect(harness.transport.controls, isNot(contains('SYNC_START')));
        expect(harness.transport.received, {'NFL', 'NBA'});
        expect(harness.coordinator.snapshot.status, InitialSyncStatus.failure);
      },
    );
    test(
      'recovery retries unavailable providers and removes known-empty cached categories safely',
      () async {
        final unavailable = <SportsLeague>{SportsLeague.nfl};
        final harness = _Harness(
          fetchFailures: unavailable,
          games: {
            SportsLeague.nfl: [_game('NFL')],
          },
        );
        cached(harness);
        await harness.coordinator.startForConnectionForTest();
        expect(harness.coordinator.needsRetry, isTrue);
        expect(harness.coordinator.snapshot.cachedContentMayBeStale, isTrue);
        unavailable.clear();
        await harness.coordinator.retryPendingSync();
        expect(harness.transport.received, {'NFL'});
        expect(harness.transport.controls, ['SYNC_START', 'SYNC_COMPLETE']);
        expect(harness.coordinator.needsRetry, isFalse);
        expect(harness.coordinator.snapshot.cachedContentMayBeStale, isFalse);
        final count = harness.source.requested.length;
        await harness.coordinator.retryPendingSync();
        expect(harness.source.requested, hasLength(count));
      },
    );

    test('simultaneous retry triggers share one fetch and one reset', () async {
      final unavailable = <SportsLeague>{SportsLeague.nfl};
      final harness = _Harness(fetchFailures: unavailable);
      cached(harness);
      await harness.coordinator.startForConnectionForTest();
      unavailable.clear();
      final pending = Completer<List<SportsGame>>();
      harness.source.nextFetch = pending;
      final priorRequests = harness.source.requested.length;
      final attempts = [
        for (var i = 0; i < 10; i++) harness.coordinator.retryPendingSync(),
      ];
      await harness.settle();
      expect(harness.source.requested.length, priorRequests + 1);
      expect(harness.transport.controls, isEmpty);
      pending.complete([_sportsGame('NFL')]);
      await Future.wait(attempts);
      expect(harness.transport.controls, ['SYNC_START', 'SYNC_COMPLETE']);
      expect(harness.transport.received, {'NFL'});
    });

    test(
      'verified empty schedules intentionally remove old content on recovery',
      () async {
        final unavailable = <SportsLeague>{SportsLeague.nfl};
        final harness = _Harness(fetchFailures: unavailable);
        cached(harness);
        await harness.coordinator.startForConnectionForTest();
        expect(harness.transport.received, {'NFL', 'NBA'});
        unavailable.clear();
        await harness.coordinator.retryPendingSync();
        expect(harness.transport.received, isEmpty);
        expect(harness.session.snapshot(), isEmpty);
        expect(harness.transport.controls, ['SYNC_START', 'SYNC_EMPTY']);
        expect(harness.coordinator.snapshot.status, InitialSyncStatus.empty);
      },
    );

    test(
      'disabled sports are retained during uncertainty then intentionally removed',
      () async {
        final unavailable = <SportsLeague>{SportsLeague.nfl};
        final harness = _Harness(
          fetchFailures: unavailable,
          games: {
            SportsLeague.nfl: [_game('NFL')],
          },
          preferences: DeviceContentPreferences.defaults().withEnabled(
            DeviceContentCategory.nba,
            false,
          ),
        );
        cached(harness);
        await harness.coordinator.startForConnectionForTest();
        expect(harness.source.requested, isNot(contains(SportsLeague.nba)));
        expect(harness.transport.received, {'NFL', 'NBA'});
        unavailable.clear();
        await harness.coordinator.retryPendingSync();
        expect(harness.transport.received, {'NFL'});
        expect(harness.coordinator.snapshot.status, InitialSyncStatus.complete);
      },
    );

    test(
      'write failure remains retryable without discarding successful categories',
      () async {
        final rejected = <String>{'NFL'};
        final harness = _Harness(
          sendFailures: rejected,
          games: {
            SportsLeague.nfl: [_game('NFL')],
            SportsLeague.mlb: [_game('MLB')],
          },
        );
        await harness.coordinator.startForConnectionForTest();
        expect(harness.transport.received, {'MLB'});
        expect(harness.coordinator.needsRetry, isTrue);
        rejected.clear();
        await harness.coordinator.retryPendingSync();
        expect(harness.transport.received, {'NFL', 'MLB'});
        expect(harness.coordinator.snapshot.status, InitialSyncStatus.complete);
      },
    );
  });

  test(
    'first connected transition syncs once and duplicates are suppressed',
    () async {
      final harness = _Harness();
      harness.coordinator.handleConnectionState(BleConnectionState.scanning);
      harness.coordinator.handleConnectionState(BleConnectionState.connecting);
      harness.coordinator.handleConnectionState(BleConnectionState.connected);
      harness.coordinator.handleConnectionState(BleConnectionState.connected);
      await harness.settle();
      expect(
        harness.transport.controls.where((c) => c == 'SYNC_START'),
        hasLength(1),
      );
    },
  );

  test('disconnect then reconnect starts a second sync', () async {
    final harness = _Harness();
    harness.coordinator.handleConnectionState(BleConnectionState.connected);
    await harness.settle();
    harness.connected = false;
    harness.coordinator.handleConnectionState(BleConnectionState.disconnected);
    harness.connected = true;
    harness.coordinator.handleConnectionState(BleConnectionState.connected);
    await harness.settle();
    expect(
      harness.transport.controls.where((c) => c == 'SYNC_START'),
      hasLength(2),
    );
  });

  test('connected sending connected remains one connection session', () async {
    final harness = _Harness();
    harness.coordinator.handleConnectionState(BleConnectionState.connected);
    harness.coordinator.handleConnectionState(BleConnectionState.sending);
    harness.coordinator.handleConnectionState(BleConnectionState.connected);
    await harness.settle();

    expect(
      harness.transport.controls.where((value) => value == 'SYNC_START'),
      hasLength(1),
    );
  });

  test(
    'F34 reconnect while previous provider fetch is pending starts current sync',
    () async {
      final pending = Completer<List<SportsGame>>();
      final harness = _Harness(
        pendingFirstFetch: pending,
        games: {
          SportsLeague.nba: [_game('NBA')],
        },
      );
      harness.coordinator.handleConnectionState(BleConnectionState.connected);
      await harness.settle();
      for (var reconnect = 0; reconnect < 2; reconnect++) {
        harness.connected = false;
        harness.coordinator.handleConnectionState(
          BleConnectionState.disconnected,
        );
        harness.connected = true;
        harness.coordinator.handleConnectionState(BleConnectionState.connected);
      }
      pending.complete([]);
      await harness.settle();
      expect(
        harness.transport.controls.where((c) => c == 'SYNC_START'),
        hasLength(1),
      );
      expect(harness.transport.sent, ['NBA']);
      expect(harness.coordinator.snapshot.status, InitialSyncStatus.complete);
    },
  );

  test(
    'fetch precedes SYNC_START and genuine all-empty sends SYNC_EMPTY',
    () async {
      final events = <String>[];
      final harness = _Harness(events: events);
      await harness.coordinator.startForConnectionForTest();
      expect(events.first, 'fetch:NFL');
      expect(
        events.indexOf('control:SYNC_START'),
        greaterThan(events.indexOf('fetch:PGA')),
      );
      expect(harness.transport.controls, ['SYNC_START', 'SYNC_EMPTY']);
      expect(harness.coordinator.snapshot.status, InitialSyncStatus.empty);
    },
  );

  test(
    'all four supported content types send in stable order and complete',
    () async {
      final harness = _Harness(
        games: {
          SportsLeague.nfl: [_game('NFL')],
          SportsLeague.ncaaf: [_game('NCAAF')],
          SportsLeague.nba: [_game('NBA')],
          SportsLeague.mlb: [_game('MLB')],
        },
        golf: _golf,
      );
      await harness.coordinator.startForConnectionForTest();
      expect(harness.source.requested, [
        SportsLeague.nfl,
        SportsLeague.ncaaf,
        SportsLeague.nba,
        SportsLeague.mlb,
      ]);
      expect(harness.transport.sent, ['NFL', 'NCAAF', 'NBA', 'MLB', 'PGA']);
      expect(harness.transport.controls, ['SYNC_START', 'SYNC_COMPLETE']);
      expect(harness.session.snapshot().keys, SportsLeague.values);
      for (final league in SportsLeague.values) {
        final entry = harness.session[league];
        final date = entry is TrackedTeamSlate
            ? entry.selectedDate
            : (entry as TrackedGolfLeaderboard).selectedDate;
        expect(date, DateTime(2026, 8, 21));
      }
    },
  );

  test(
    'failed fetch with no loaded content isolates leagues and never sends SYNC_EMPTY',
    () async {
      final harness = _Harness(fetchFailures: {SportsLeague.nfl});
      await harness.coordinator.startForConnectionForTest();
      expect(harness.source.requested, [
        SportsLeague.nfl,
        SportsLeague.ncaaf,
        SportsLeague.nba,
        SportsLeague.mlb,
      ]);
      expect(harness.transport.controls, isEmpty);
      expect(harness.coordinator.snapshot.status, InitialSyncStatus.failure);
    },
  );

  test('failed MLB send preserves baseline and still allows PGA', () async {
    final harness = _Harness(
      games: {
        SportsLeague.mlb: [_game('MLB')],
      },
      golf: _golf,
      sendFailures: {'MLB'},
    );
    await harness.coordinator.startForConnectionForTest();
    expect(harness.transport.sent, ['MLB', 'PGA']);
    expect(harness.session[SportsLeague.mlb], isNull);
    expect(harness.session[SportsLeague.pga], isA<TrackedGolfLeaderboard>());
    expect(harness.transport.controls.last, 'SYNC_COMPLETE');
  });

  test(
    'disconnect during fetch prevents later sends and final command',
    () async {
      final pending = Completer<List<SportsGame>>();
      final harness = _Harness(pendingFirstFetch: pending);
      harness.coordinator.handleConnectionState(BleConnectionState.connected);
      await Future<void>.delayed(Duration.zero);
      harness.connected = false;
      harness.coordinator.handleConnectionState(
        BleConnectionState.disconnected,
      );
      pending.complete([_sportsGame('NFL')]);
      await harness.settle();
      expect(harness.transport.controls, isEmpty);
      expect(harness.transport.sent, isEmpty);
    },
  );

  test('injected local date is used for every provider request', () async {
    final harness = _Harness();
    await harness.coordinator.startForConnectionForTest();
    expect(harness.source.dates, everyElement(DateTime(2026, 8, 21)));
    expect(harness.golfSource.requestedDate, DateTime(2026, 8, 21));
  });

  test(
    'explicit category order controls sends and disabled leagues are not fetched',
    () async {
      final preferences = DeviceContentPreferences([
        const DeviceContentPreference(
          category: DeviceContentCategory.mlb,
          enabled: true,
        ),
        const DeviceContentPreference(
          category: DeviceContentCategory.nfl,
          enabled: true,
        ),
        const DeviceContentPreference(
          category: DeviceContentCategory.ncaaf,
          enabled: false,
        ),
        const DeviceContentPreference(
          category: DeviceContentCategory.pga,
          enabled: true,
        ),
        const DeviceContentPreference(
          category: DeviceContentCategory.fantasy,
          enabled: true,
        ),
        const DeviceContentPreference(
          category: DeviceContentCategory.nba,
          enabled: false,
        ),
      ]);
      final harness = _Harness(
        preferences: preferences,
        games: {
          SportsLeague.nfl: [_game('NFL')],
          SportsLeague.nba: [_game('NBA')],
          SportsLeague.mlb: [_game('MLB')],
        },
        golf: _golf,
        fantasyAvailable: true,
      );
      await harness.coordinator.startForConnectionForTest();
      expect(harness.transport.sent, ['MLB', 'NFL', 'PGA', 'FANTASY']);
      expect(harness.source.requested, [SportsLeague.mlb, SportsLeague.nfl]);
      expect(harness.session[SportsLeague.nba], isNull);
    },
  );

  test(
    'all disabled clears tracked baseline and sends clean empty startup',
    () async {
      var preferences = DeviceContentPreferences.defaults();
      for (final category in DeviceContentCategory.values) {
        preferences = preferences.withEnabled(category, false);
      }
      final harness = _Harness(preferences: preferences);
      harness.session.recordTeamSlate(
        league: SportsLeague.nfl,
        selectedDate: DateTime(2026, 8, 21),
        games: [_game('NFL')],
      );
      await harness.coordinator.startForConnectionForTest();
      expect(harness.source.requested, isEmpty);
      expect(harness.transport.controls, ['SYNC_START', 'SYNC_EMPTY']);
      expect(harness.session.snapshot(), isEmpty);
    },
  );
}

class _Harness {
  _Harness({
    Map<SportsLeague, List<GameData>> games = const {},
    GolfLeaderboard? golf,
    Set<SportsLeague> fetchFailures = const {},
    Set<String> sendFailures = const {},
    Completer<List<SportsGame>>? pendingFirstFetch,
    List<String>? events,
    DeviceContentPreferences? preferences,
    bool fantasyAvailable = false,
  }) : source = _Source(games, fetchFailures, pendingFirstFetch, events),
       golfSource = _GolfSource(golf, events),
       transport = _Transport(sendFailures, events) {
    sender = SessionAwareDeviceSender(transport: transport, session: session);
    coordinator = InitialDeviceSyncCoordinator(
      repository: SportsRepository(source, golfDataSource: golfSource),
      sender: sender,
      isBleConnected: () => connected,
      clock: () => DateTime(2026, 8, 21, 16, 30),
      readContentPreferences: () =>
          preferences ?? DeviceContentPreferences.defaults(),
      prepareFantasyCategory: () async => PreparedFantasyStartup(
        hasContent: fantasyAvailable,
        commit: () async {
          if (fantasyAvailable) transport.sent.add('FANTASY');
          return FantasyStartupOutcome(hasContent: fantasyAvailable);
        },
      ),
      onAuthoritativeSyncStarted: session.clear,
    );
  }

  final TrackedDeviceSession session = TrackedDeviceSession();
  final _Source source;
  final _GolfSource golfSource;
  final _Transport transport;
  late final SessionAwareDeviceSender sender;
  late final InitialDeviceSyncCoordinator coordinator;
  bool connected = true;

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

class _Source implements SportsDataSource {
  _Source(this.games, this.failures, this.pending, this.events);
  final Map<SportsLeague, List<GameData>> games;
  final Set<SportsLeague> failures;
  final Completer<List<SportsGame>>? pending;
  final List<String>? events;
  Completer<List<SportsGame>>? nextFetch;
  final requested = <SportsLeague>[];
  final dates = <DateTime>[];

  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime date,
  ) async {
    requested.add(league);
    dates.add(date);
    events?.add('fetch:${league.label}');
    final next = nextFetch;
    nextFetch = null;
    if (next != null) return next.future;
    if (pending != null && requested.length == 1) return pending!.future;
    if (failures.contains(league)) throw StateError('fetch failed');
    return (games[league] ?? const [])
        .map((g) => _sportsGame(g.league))
        .toList();
  }
}

class _GolfSource implements GolfDataSource {
  _GolfSource(this.golf, this.events);
  final GolfLeaderboard? golf;
  final List<String>? events;
  DateTime? requestedDate;
  @override
  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(DateTime date) async {
    requestedDate = date;
    events?.add('fetch:PGA');
    return golf;
  }

  @override
  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(String id) async =>
      golf!;
}

class _Transport implements DeviceTransport {
  _Transport(this.failures, this.events);
  final Set<String> failures;
  final List<String>? events;
  final received = <String>{};
  final controls = <String>[];
  final sent = <String>[];
  @override
  Future<void> sendControlCommand(String command) async {
    controls.add(command);
    if (command == 'SYNC_START') received.clear();
    events?.add('control:$command');
  }

  @override
  Future<void> sendGameData(GameData gameData) async {}
  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    final league = games.first.league;
    sent.add(league);
    if (failures.contains(league)) throw StateError('send failed');
    received.add(league);
  }

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {
    sent.add('PGA');
    if (failures.contains('PGA')) throw StateError('send failed');
    received.add('PGA');
  }
}

GameData _game(String league) => GameData(
  eventId: '$league-1',
  league: league,
  awayTeam: 'A',
  homeTeam: 'H',
  awayScore: 0,
  homeScore: 0,
  status: 'UPCOMING',
  clock: '1:00 PM',
  scheduledStartTime: DateTime(2026, 8, 21),
);

SportsGame _sportsGame(String league) => SportsGame(
  eventId: '$league-1',
  league: league,
  awayTeam: 'A',
  homeTeam: 'H',
  awayTeamKey: league == 'NCAAF' ? 'SC' : null,
  awayScore: 0,
  homeScore: 0,
  status: 'UPCOMING',
  clock: '1:00 PM',
  scheduledStartTime: DateTime(2026, 8, 21),
);

const _golf = GolfLeaderboard(
  tournamentId: 'pga-1',
  tournamentName: 'Open',
  golfers: [
    GolfLeaderboardRow(playerId: '1', name: 'P', rank: '1', score: 'E'),
  ],
  isInProgress: true,
  isOver: false,
);
