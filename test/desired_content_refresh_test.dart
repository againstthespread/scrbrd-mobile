import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/device_content_preferences.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/favorite_team.dart';
import 'package:sports_hub_mobile/college_football.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_data_source.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/initial_device_sync_coordinator.dart';
import 'package:sports_hub_mobile/live_refresh_coordinator.dart';
import 'package:sports_hub_mobile/session_aware_device_sender.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_operation_gate.dart';
import 'package:sports_hub_mobile/sports_repository.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  test('F08 midnight advances consumer games without reconnecting', () async {
    final h = _Harness([DeviceContentCategory.nfl]);
    h.sports.games = (league, date) => [_game(league, date)];
    await h.start();
    h.now = DateTime(2026, 10, 15);
    await h.wake();
    expect(
      (h.session[SportsLeague.nfl] as TrackedTeamSlate).selectedDate,
      DateTime(2026, 10, 15),
    );
    expect(h.device.teams['NFL']!.single.eventId, 'NFL-2026-10-15');
  });

  test(
    'F08 enabled initially empty categories are periodically rediscovered',
    () async {
      final h = _Harness([DeviceContentCategory.nba]);
      await h.start();
      expect(h.session.snapshot(), isEmpty);
      h.sports.games = (league, date) => [_game(league, date)];
      h.now = h.now.add(const Duration(minutes: 5));
      await h.wake();
      expect(h.device.teams['NBA'], hasLength(1));
    },
  );

  test('F08 PGA discovers a new tournament on the same date', () async {
    final h = _Harness([DeviceContentCategory.pga]);
    h.now = DateTime(2026, 10, 14, 12);
    h.golf.current = _golf('old');
    await h.start();
    h.golf.current = _golf('new');
    h.now = h.now.add(const Duration(minutes: 5));
    await h.wake();
    expect(h.device.golf!.tournamentId, 'new');
  });

  test('F08 today is the local calendar date even with a UTC clock', () async {
    final h = _Harness([DeviceContentCategory.nfl]);
    final local = DateTime(2026, 10, 14, 23, 59);
    h.now = local.toUtc();
    h.sports.games = (league, date) => [_game(league, date)];
    await h.start();
    expect(h.sports.requests.last.$2, DateTime(2026, 10, 14));
    h.now = DateTime(2026, 10, 15).toUtc();
    await h.wake();
    expect(h.sports.requests.last.$2, DateTime(2026, 10, 15));
  });

  test('F08 explicit historical games and tournament remain pinned', () async {
    final h = _Harness([DeviceContentCategory.nfl, DeviceContentCategory.pga]);
    h.sports.games = (league, date) => [_game(league, date)];
    h.golf.current = _golf('today');
    await h.start();
    final history = DateTime(2026, 9, 1);
    await h.sender.sendTeamSlate([
      _data(_game(SportsLeague.nfl, history)),
    ], selectedDate: history);
    await h.sender.sendGolf(_golf('historical'), selectedDate: history);
    h.now = DateTime(2026, 10, 15);
    await h.wake();
    expect(h.sports.requests.last.$2, history);
    expect(h.device.golf!.tournamentId, 'historical');
    expect(
      (h.session[SportsLeague.nfl] as TrackedTeamSlate).selectedDate,
      history,
    );
  });

  test('F08 missing-category retry does not poll every WAKE', () async {
    final h = _Harness([DeviceContentCategory.nba]);
    h.now = DateTime(2026, 10, 14, 12);
    await h.start();
    for (var i = 0; i < 10; i++) {
      h.now = h.now.add(const Duration(seconds: 20));
      await h.wake();
    }
    expect(h.sports.requests, hasLength(1));
    expect(h.device.controls, ['SYNC_START', 'SYNC_EMPTY']);
  });

  test(
    'F08 unchanged discovery does not retransmit or reset the catalog',
    () async {
      final h = _Harness([
        DeviceContentCategory.nfl,
        DeviceContentCategory.pga,
      ]);
      h.now = DateTime(2026, 10, 14, 12);
      h.sports.games = (league, date) => [_game(league, date)];
      h.golf.current = _golf('same');
      await h.start();
      h.now = h.now.add(const Duration(minutes: 5));
      await h.wake();
      expect(h.sports.requests, hasLength(2));
      expect(h.golf.dates, hasLength(2));
      expect(
        h.golf.ids,
        isEmpty,
      ); // No duplicate tracked fetch on discovery tick.
      expect(h.device.slates, hasLength(1));
      expect(h.device.golfWrites, hasLength(1));
      expect(h.device.controls, ['SYNC_START', 'SYNC_COMPLETE']);
    },
  );

  test(
    'F08 midnight provider outage retains peers then recovers without reset',
    () async {
      final h = _Harness([
        DeviceContentCategory.nfl,
        DeviceContentCategory.mlb,
      ]);
      h.sports.games = (league, date) => [_game(league, date)];
      await h.start();
      h.sports.failures.add(SportsLeague.nfl);
      h.now = DateTime(2026, 10, 15);
      await h.wake();
      expect(h.device.teams['NFL']!.single.eventId, 'NFL-2026-10-14');
      expect(h.device.teams['MLB']!.single.eventId, 'MLB-2026-10-15');
      expect(h.initial.snapshot.status, InitialSyncStatus.partialFailure);
      expect(h.initial.snapshot.cachedContentMayBeStale, isTrue);
      expect(h.initial.needsRetry, isTrue);
      h.sports.failures.clear();
      await h.wake();
      expect(h.device.teams['NFL']!.single.eventId, 'NFL-2026-10-15');
      expect(
        h.device.slates,
        hasLength(4),
      ); // The fresh MLB slate was not resent.
      expect(h.device.controls.where((c) => c == 'SYNC_START'), hasLength(1));
      expect(h.initial.needsRetry, isFalse);
    },
  );

  test('F08 missing categories recover in configured order', () async {
    final h = _Harness([DeviceContentCategory.mlb, DeviceContentCategory.nfl]);
    h.now = DateTime(2026, 10, 14, 12);
    h.sports.games = (league, date) =>
        league == SportsLeague.nfl ? [_game(league, date)] : [];
    await h.start();
    expect(h.device.order, ['NFL']);
    h.sports.games = (league, date) => [_game(league, date)];
    h.now = h.now.add(const Duration(minutes: 5));
    await h.wake();
    expect(h.device.order, ['MLB', 'NFL']);
    expect(h.device.controls.where((c) => c == 'SYNC_START'), hasLength(2));
    expect(h.sports.requests.map((r) => r.$1), [
      SportsLeague.mlb,
      SportsLeague.nfl,
      SportsLeague.mlb,
      SportsLeague.nfl,
    ]);
  });

  test(
    'F08 initially unavailable category recovers with F07 cache safety',
    () async {
      final h = _Harness([
        DeviceContentCategory.nfl,
        DeviceContentCategory.nba,
      ]);
      h.sports.games = (league, date) => [_game(league, date)];
      h.sports.failures.add(SportsLeague.nba);
      await h.start();
      expect(h.device.teams.keys, ['NFL']);
      expect(h.device.controls, ['SYNC_COMPLETE']);
      h.sports.failures.clear();
      await h.wake();
      expect(h.device.order, ['NFL', 'NBA']);
      expect(h.initial.snapshot.status, InitialSyncStatus.complete);
    },
  );

  test(
    'F08 new-day empty schedules clear old content only when all providers succeed',
    () async {
      final h = _Harness([
        DeviceContentCategory.nfl,
        DeviceContentCategory.pga,
      ]);
      h.sports.games = (league, date) => [_game(league, date)];
      h.golf.current = _golf('old');
      await h.start();
      h.now = DateTime(2026, 10, 15);
      h.sports.games = (_, _) => [];
      h.golf.current = null;
      h.golf.fail = true;
      await h.wake();
      expect(h.device.order, ['NFL', 'PGA']);
      expect(h.device.controls, isNot(contains('SYNC_EMPTY')));
      h.golf.fail = false;
      await h.wake();
      expect(h.device.order, isEmpty);
      expect(h.session.snapshot(), isEmpty);
      expect(h.device.controls.last, 'SYNC_EMPTY');
      expect(h.initial.snapshot.status, InitialSyncStatus.empty);
      final count = h.device.controls.length;
      h.now = h.now.add(const Duration(minutes: 5));
      await h.wake();
      expect(h.device.controls, hasLength(count));
    },
  );

  test(
    'F08 same-day empty response needs confirmation before removing cached sports',
    () async {
      final h = _Harness([
        DeviceContentCategory.nfl,
        DeviceContentCategory.pga,
      ]);
      h.now = DateTime(2026, 10, 14, 12);
      h.sports.games = (league, date) => [_game(league, date)];
      h.golf.current = _golf('old');
      await h.start();
      h.sports.games = (_, _) => [];
      h.golf.current = null;
      h.now = h.now.add(const Duration(minutes: 5));
      await h.wake();
      expect(h.device.order, ['NFL', 'PGA']);
      expect(h.initial.snapshot.cachedContentMayBeStale, isTrue);
      h.now = h.now.add(const Duration(minutes: 5));
      await h.wake();
      expect(h.device.order, isEmpty);
      expect(h.device.controls.last, 'SYNC_EMPTY');
    },
  );

  test(
    'F08 failed PGA discovery retains old tournament and retries successfully',
    () async {
      final h = _Harness([DeviceContentCategory.pga]);
      h.now = DateTime(2026, 10, 14, 12);
      h.golf.current = _golf('old');
      await h.start();
      h.golf.fail = true;
      h.now = h.now.add(const Duration(minutes: 5));
      await h.wake();
      expect(h.device.golf!.tournamentId, 'old');
      h.golf.current = _golf('new');
      h.golf.fail = false;
      await h.wake();
      expect(h.device.golf!.tournamentId, 'new');
      expect(h.golf.ids, isEmpty);
      expect(h.device.controls.where((c) => c == 'SYNC_START'), hasLength(1));
    },
  );

  test(
    'F08 failed replacement write keeps the delivered date retryable',
    () async {
      final h = _Harness([DeviceContentCategory.nfl]);
      h.sports.games = (league, date) => [_game(league, date)];
      await h.start();
      h.now = DateTime(2026, 10, 15);
      h.device.failures.add('NFL');
      await h.wake();
      expect(
        (h.session[SportsLeague.nfl] as TrackedTeamSlate).selectedDate,
        DateTime(2026, 10, 14),
      );
      expect(h.device.teams['NFL']!.single.eventId, 'NFL-2026-10-14');
      h.device.failures.clear();
      await h.wake();
      expect(
        (h.session[SportsLeague.nfl] as TrackedTeamSlate).selectedDate,
        DateTime(2026, 10, 15),
      );
    },
  );

  test('F08 concurrent discovery triggers share one provider pass', () async {
    final h = _Harness([DeviceContentCategory.nfl]);
    h.sports.games = (league, date) => [_game(league, date)];
    await h.start();
    h.now = DateTime(2026, 10, 15);
    final block = Completer<void>();
    h.sports.block = block;
    final wakes = [for (var i = 0; i < 10; i++) h.wake()];
    await Future<void>.delayed(Duration.zero);
    expect(h.sports.requests, hasLength(2));
    block.complete();
    await Future.wait(wakes);
    expect(h.sports.requests, hasLength(2));
    expect(h.device.slates, hasLength(2));
  });

  test('F08 calendar rollover handles a 23-hour DST day', () async {
    final h = _Harness([DeviceContentCategory.nfl]);
    h.now = DateTime(2026, 3, 8);
    h.sports.games = (league, date) => [_game(league, date)];
    await h.start();
    h.now = DateTime(2026, 3, 9);
    await h.wake();
    expect(
      (h.session[SportsLeague.nfl] as TrackedTeamSlate).selectedDate,
      DateTime(2026, 3, 9),
    );
  });

  test(
    'F08 rollover preserves favorites and selected NCAAF conferences',
    () async {
      final h = _Harness([DeviceContentCategory.ncaaf]);
      h.conferences = CollegeFootballPreferences([NcaafConference.sec]);
      h.favorites.add(
        const FavoriteTeam(
          league: SportsLeague.ncaaf,
          key: 'ALA',
          abbreviation: 'ALA',
          displayName: 'Alabama',
        ),
      );
      h.sports.games = (league, date) => [
        for (final key in ['UGA', 'OSU', 'ALA'])
          SportsGame(
            eventId: '$key-${_day(date)}',
            league: league.label,
            awayTeam: key,
            homeTeam: 'Other',
            awayTeamKey: key,
            awayScore: 0,
            homeScore: 0,
            status: 'UPCOMING',
            clock: '1 PM',
            scheduledStartTime: date,
          ),
      ];
      await h.start();
      h.now = DateTime(2026, 10, 15);
      await h.wake();
      expect(h.device.teams['NCAAF']!.map((g) => g.awayTeamKey), [
        'ALA',
        'UGA',
      ]);
      expect(h.device.order, ['NCAAF']);
    },
  );

  test(
    'F08 a historical send during discovery wins over the captured today selection',
    () async {
      final h = _Harness([DeviceContentCategory.nfl]);
      h.sports.games = (league, date) => [_game(league, date)];
      await h.start();
      h.now = DateTime(2026, 10, 15);
      final block = Completer<void>();
      h.sports.block = block;
      final wake = h.wake();
      await Future<void>.delayed(Duration.zero);
      final history = DateTime(2026, 9, 1);
      await h.sender.sendTeamSlate([
        _data(_game(SportsLeague.nfl, history)),
      ], selectedDate: history);
      block.complete();
      await wake;
      expect(h.device.teams['NFL']!.single.eventId, 'NFL-2026-09-01');
      await h.wake();
      expect(h.sports.requests.last.$2, history);
      expect(h.device.teams['NFL']!.single.eventId, 'NFL-2026-09-01');
    },
  );

  test('F08 live score changes retain consumer rollover mode', () async {
    final h = _Harness([DeviceContentCategory.nfl]);
    h.now = DateTime(2026, 10, 14, 12);
    var score = 1;
    h.sports.games = (league, date) => [
      SportsGame(
        eventId: 'stable-${_day(date)}',
        league: league.label,
        awayTeam: 'A',
        homeTeam: 'H',
        awayScore: score,
        homeScore: 0,
        status: 'LIVE',
        clock: 'Q1',
        scheduledStartTime: date,
      ),
    ];
    await h.start();
    score = 2;
    await h.wake();
    expect(h.device.teams['NFL']!.single.awayScore, 2);
    expect(h.session[SportsLeague.nfl]!.followsCurrentDate, isTrue);
    h.now = DateTime(2026, 10, 15);
    await h.wake();
    expect(
      (h.session[SportsLeague.nfl] as TrackedTeamSlate).selectedDate,
      DateTime(2026, 10, 15),
    );
  });

  test(
    'F07 partial reconnect resends a verified provider even if cached bytes match',
    () async {
      final h = _Harness([
        DeviceContentCategory.nfl,
        DeviceContentCategory.nba,
      ]);
      h.sports.games = (league, date) => [_game(league, date)];
      h.sports.failures.add(SportsLeague.nba);
      final date = DateTime(h.now.year, h.now.month, h.now.day);
      await h.sender.sendTeamSlate(
        [_data(_game(SportsLeague.nfl, date))],
        selectedDate: date,
        followsCurrentDate: true,
      );
      await h.start();
      expect(h.device.slates, hasLength(2));
      expect(h.device.controls, ['SYNC_COMPLETE']);
    },
  );

  test(
    'F08 old-date shrink confirmation cannot approve a rescheduled new-date removal',
    () async {
      final h = _Harness([DeviceContentCategory.nfl]);
      h.now = DateTime(2026, 10, 14, 12);
      var ids = ['A', 'B'];
      h.sports.games = (league, date) => [
        for (final id in ids)
          SportsGame(
            eventId: id,
            league: league.label,
            awayTeam: 'A',
            homeTeam: 'H',
            awayScore: 0,
            homeScore: 0,
            status: 'UPCOMING',
            clock: '1 PM',
            scheduledStartTime: date,
          ),
      ];
      await h.start();
      ids = ['A'];
      await h.wake(); // First day suspects B missing.
      expect(h.device.teams['NFL'], hasLength(2));
      ids = ['A', 'B'];
      h.now = DateTime(2026, 10, 15);
      await h.wake(); // Same stable IDs rescheduled to the new date.
      ids = ['A'];
      await h.wake();
      expect(
        h.device.teams['NFL'],
        hasLength(2),
      ); // Needs new-date confirmation.
      await h.wake();
      expect(h.device.teams['NFL'], hasLength(1));
    },
  );
}

String _day(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
SportsGame _game(SportsLeague league, DateTime date) => SportsGame(
  eventId: '${league.label}-${_day(date)}',
  league: league.label,
  awayTeam: 'A',
  homeTeam: 'H',
  awayScore: 1,
  homeScore: 2,
  status: 'LIVE',
  clock: 'Q1',
  scheduledStartTime: date,
);
GameData _data(SportsGame game) => GameData(
  eventId: game.eventId,
  league: game.league,
  awayTeam: game.awayTeam,
  homeTeam: game.homeTeam,
  awayScore: game.awayScore,
  homeScore: game.homeScore,
  status: game.status,
  clock: game.clock,
  scheduledStartTime: game.scheduledStartTime,
);
GolfLeaderboard _golf(String id) => GolfLeaderboard(
  tournamentId: id,
  tournamentName: 'Open $id',
  golfers: const [
    GolfLeaderboardRow(playerId: 'p', name: 'Player', rank: '1', score: 'E'),
  ],
  isInProgress: true,
  isOver: false,
);

class _Harness {
  _Harness(List<DeviceContentCategory> enabled) {
    preferences = DeviceContentPreferences([
      for (final category in {...enabled, ...DeviceContentCategory.values})
        DeviceContentPreference(
          category: category,
          enabled: enabled.contains(category),
        ),
    ]);
    final repository = SportsRepository(sports, golfDataSource: golf);
    sender = SessionAwareDeviceSender(transport: device, session: session);
    live = LiveRefreshCoordinator(
      repository: repository,
      transport: sender,
      session: session,
      isBleConnected: () => connected,
    );
    initial = InitialDeviceSyncCoordinator(
      repository: repository,
      sender: sender,
      isBleConnected: () => connected,
      clock: () => now,
      operationGate: gate,
      readContentPreferences: () => preferences,
      readFavorites: () => favorites,
      readCollegeFootballPreferences: () => conferences,
      onAuthoritativeSyncStarted: session.clear,
      canReplaceTeamSlate: live.canReplaceTeamSlate,
    );
  }
  DateTime now = DateTime(2026, 10, 14, 23, 59);
  bool connected = true;
  late DeviceContentPreferences preferences;
  final favorites = <FavoriteTeam>{};
  CollegeFootballPreferences conferences =
      CollegeFootballPreferences.defaults();
  final sports = _Sports();
  final golf = _Golf();
  final device = _Device();
  final session = TrackedDeviceSession();
  final gate = SportsOperationGate();
  late final SessionAwareDeviceSender sender;
  late final LiveRefreshCoordinator live;
  late final InitialDeviceSyncCoordinator initial;
  Future<void> start() => initial.startForConnectionForTest();
  Future<void> wake() async {
    if (initial.needsRetry) {
      await initial.retryPendingSync();
    } else if (!await initial.refreshDesiredContentIfDue()) {
      await gate.requestLiveRefresh(live.refreshTrackedSessionOnce);
    }
  }
}

class _Sports implements SportsDataSource {
  final requests = <(SportsLeague, DateTime)>[];
  final failures = <SportsLeague>{};
  Completer<void>? block;
  List<SportsGame> Function(SportsLeague, DateTime) games = (_, _) => [];
  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime date,
  ) async {
    requests.add((league, date));
    final pending = block;
    block = null;
    if (pending != null) await pending.future;
    if (failures.contains(league)) throw StateError('provider unavailable');
    return games(league, date);
  }
}

class _Golf implements GolfDataSource {
  GolfLeaderboard? current;
  bool fail = false;
  final dates = <DateTime>[];
  final ids = <String>[];
  final known = <String, GolfLeaderboard>{};
  @override
  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(DateTime date) async {
    dates.add(date);
    if (fail) throw StateError('golf unavailable');
    if (current case final value?) known[value.tournamentId] = value;
    return current;
  }

  @override
  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(String id) async {
    ids.add(id);
    if (fail) throw StateError('golf unavailable');
    return known[id] ?? _golf(id);
  }
}

class _Device implements DeviceTransport {
  final controls = <String>[];
  final teams = <String, List<GameData>>{};
  final order = <String>[];
  final slates = <List<GameData>>[];
  GolfLeaderboard? golf;
  final golfWrites = <GolfLeaderboard>[];
  final failures = <String>{};
  @override
  Future<void> sendControlCommand(String command) async {
    controls.add(command);
    if (command == 'SYNC_START') {
      teams.clear();
      golf = null;
      order.clear();
    }
  }

  @override
  Future<void> sendGameData(GameData gameData) async {}
  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    final league = games.first.league;
    if (failures.contains(league)) throw StateError('BLE write failure');
    if (!order.contains(league)) order.add(league);
    teams[league] = List.of(games);
    slates.add(games);
  }

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {
    if (failures.contains('PGA')) throw StateError('BLE write failure');
    if (!order.contains('PGA')) order.add('PGA');
    golf = leaderboard;
    golfWrites.add(leaderboard);
  }
}
