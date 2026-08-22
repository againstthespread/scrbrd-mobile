import 'dart:async';

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

void main() {
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

  test('SYNC_START precedes fetch and all-empty sends SYNC_EMPTY', () async {
    final events = <String>[];
    final harness = _Harness(events: events);
    await harness.coordinator.startForConnectionForTest();
    expect(events.first, 'control:SYNC_START');
    expect(harness.transport.controls, ['SYNC_START', 'SYNC_EMPTY']);
    expect(harness.coordinator.snapshot.status, InitialSyncStatus.empty);
  });

  test(
    'all four supported content types send in stable order and complete',
    () async {
      final harness = _Harness(
        games: {
          SportsLeague.nfl: [_game('NFL')],
          SportsLeague.nba: [_game('NBA')],
          SportsLeague.mlb: [_game('MLB')],
        },
        golf: _golf,
      );
      await harness.coordinator.startForConnectionForTest();
      expect(harness.source.requested, [
        SportsLeague.nfl,
        SportsLeague.nba,
        SportsLeague.mlb,
      ]);
      expect(harness.transport.sent, ['NFL', 'NBA', 'MLB', 'PGA']);
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
    'partial fetch failure isolates leagues and never sends SYNC_EMPTY',
    () async {
      final harness = _Harness(fetchFailures: {SportsLeague.nfl});
      await harness.coordinator.startForConnectionForTest();
      expect(harness.source.requested, [
        SportsLeague.nfl,
        SportsLeague.nba,
        SportsLeague.mlb,
      ]);
      expect(harness.transport.controls, ['SYNC_START']);
      expect(
        harness.coordinator.snapshot.status,
        InitialSyncStatus.partialFailure,
      );
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
      expect(harness.transport.controls, ['SYNC_START']);
      expect(harness.transport.sent, isEmpty);
    },
  );

  test('injected local date is used for every provider request', () async {
    final harness = _Harness();
    await harness.coordinator.startForConnectionForTest();
    expect(harness.source.dates, everyElement(DateTime(2026, 8, 21)));
    expect(harness.golfSource.requestedDate, DateTime(2026, 8, 21));
  });
}

class _Harness {
  _Harness({
    Map<SportsLeague, List<GameData>> games = const {},
    GolfLeaderboard? golf,
    Set<SportsLeague> fetchFailures = const {},
    Set<String> sendFailures = const {},
    Completer<List<SportsGame>>? pendingFirstFetch,
    List<String>? events,
  }) : source = _Source(games, fetchFailures, pendingFirstFetch, events),
       golfSource = _GolfSource(golf, events),
       transport = _Transport(sendFailures, events) {
    sender = SessionAwareDeviceSender(transport: transport, session: session);
    coordinator = InitialDeviceSyncCoordinator(
      repository: SportsRepository(source, golfDataSource: golfSource),
      sender: sender,
      isBleConnected: () => connected,
      clock: () => DateTime(2026, 8, 21, 16, 30),
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
  final controls = <String>[];
  final sent = <String>[];
  @override
  Future<void> sendControlCommand(String command) async {
    controls.add(command);
    events?.add('control:$command');
  }

  @override
  Future<void> sendGameData(GameData gameData) async {}
  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    final league = games.first.league;
    sent.add(league);
    if (failures.contains(league)) throw StateError('send failed');
  }

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {
    sent.add('PGA');
    if (failures.contains('PGA')) throw StateError('send failed');
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
