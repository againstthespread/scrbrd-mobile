import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/device_transport.dart';
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
  test(
    'multiple WAKEs during initial sync coalesce to one deferred refresh',
    () async {
      final gate = SportsOperationGate();
      final release = Completer<void>();
      var refreshes = 0;
      final initial = gate.runInitialSync(() => release.future);

      await gate.requestLiveRefresh(() async => refreshes++);
      await gate.requestLiveRefresh(() async => refreshes++);
      await gate.requestLiveRefresh(() async => refreshes++);
      expect(refreshes, 0);

      release.complete();
      await initial;
      expect(refreshes, 1);
    },
  );

  test(
    'startup WAKE cannot duplicate an unchanged initial transmission',
    () async {
      final pendingNfl = Completer<List<SportsGame>>();
      final source = _Source(pendingNfl: pendingNfl, mlbScores: [2, 2]);
      final golf = _GolfSource(_golf('-1'), _golf('-1'));
      final repository = SportsRepository(source, golfDataSource: golf);
      final session = TrackedDeviceSession();
      final transport = _Transport();
      final sender = SessionAwareDeviceSender(
        transport: transport,
        session: session,
      );
      final gate = SportsOperationGate();
      final initial = InitialDeviceSyncCoordinator(
        repository: repository,
        sender: sender,
        isBleConnected: () => true,
        operationGate: gate,
        clock: () => _date,
      );
      final live = LiveRefreshCoordinator(
        repository: repository,
        transport: sender,
        session: session,
        isAppBackgrounded: () => false,
        isBleConnected: () => true,
        isLiveActivityActive: () async => true,
      );

      final startup = initial.startForConnectionForTest();
      await Future<void>.delayed(Duration.zero);
      await gate.requestLiveRefresh(live.refreshTrackedSessionOnce);
      await gate.requestLiveRefresh(live.refreshTrackedSessionOnce);
      expect(source.mlbFetchCount, 0);
      pendingNfl.complete(const []);
      await startup;

      expect(source.mlbFetchCount, 2);
      expect(transport.mlbSlates, hasLength(1));
      expect(transport.golf, hasLength(1));
    },
  );

  test(
    'first post-sync WAKE detects changed MLB without Games interaction',
    () async {
      final source = _Source(mlbScores: [2, 3]);
      final golf = _GolfSource(null, null);
      final repository = SportsRepository(source, golfDataSource: golf);
      final session = TrackedDeviceSession();
      final transport = _Transport();
      final sender = SessionAwareDeviceSender(
        transport: transport,
        session: session,
      );
      final gate = SportsOperationGate();
      final initial = InitialDeviceSyncCoordinator(
        repository: repository,
        sender: sender,
        isBleConnected: () => true,
        operationGate: gate,
        clock: () => _date,
      );
      final live = LiveRefreshCoordinator(
        repository: repository,
        transport: sender,
        session: session,
        isAppBackgrounded: () => false,
        isBleConnected: () => true,
        isLiveActivityActive: () async => true,
      );

      await initial.startForConnectionForTest();
      expect(
        (session[SportsLeague.mlb] as TrackedTeamSlate).games.single.awayScore,
        2,
      );
      await gate.requestLiveRefresh(live.refreshTrackedSessionOnce);

      expect(transport.mlbSlates, hasLength(2));
      expect(
        (session[SportsLeague.mlb] as TrackedTeamSlate).games.single.awayScore,
        3,
      );
    },
  );

  test(
    'initial PGA baseline and repeated WAKEs send only meaningful changes',
    () async {
      final initialGolf = _pgaLeaderboard(score: 'E', detail: 'THRU 4');
      final wakeOne = _pgaLeaderboard(score: '-1', detail: 'THRU 5');
      final wakeTwo = _pgaLeaderboard(score: '-1', detail: 'THRU 5');
      final wakeThree = _pgaLeaderboard(score: '-2', detail: 'THRU 6');
      final golf = _QueuedGolfSource(initialGolf, [
        wakeOne,
        wakeTwo,
        wakeThree,
      ]);
      final repository = SportsRepository(
        _Source(mlbScores: const []),
        golfDataSource: golf,
      );
      final session = TrackedDeviceSession();
      final transport = _Transport();
      final sender = SessionAwareDeviceSender(
        transport: transport,
        session: session,
      );
      final diagnostics = <String>[];
      final gate = SportsOperationGate();
      final initial = InitialDeviceSyncCoordinator(
        repository: repository,
        sender: sender,
        isBleConnected: () => true,
        operationGate: gate,
        clock: () => _date,
      );
      final live = LiveRefreshCoordinator(
        repository: repository,
        transport: sender,
        session: session,
        isAppBackgrounded: () => false,
        isBleConnected: () => true,
        isLiveActivityActive: () async => true,
        onDiagnostic: diagnostics.add,
      );

      await initial.startForConnectionForTest();

      expect(gate.isInitialSyncActive, isFalse);
      expect(transport.golf, [initialGolf]);
      final baseline = session[SportsLeague.pga] as TrackedGolfLeaderboard;
      expect(baseline.leaderboard.tournamentId, 'pga-live-1');
      expect(baseline.leaderboard.tournamentName, 'Live Open');
      expect(baseline.leaderboard.golfers, hasLength(2));
      expect(baseline.leaderboard.golfers.first.score, 'E');
      expect(baseline.leaderboard.golfers.first.detail, 'THRU 4');

      await gate.requestLiveRefresh(live.refreshTrackedSessionOnce);
      expect(transport.golf, [initialGolf, wakeOne]);
      expect(
        (session[SportsLeague.pga] as TrackedGolfLeaderboard)
            .leaderboard
            .golfers
            .first
            .score,
        '-1',
      );

      await gate.requestLiveRefresh(live.refreshTrackedSessionOnce);
      expect(transport.golf, [initialGolf, wakeOne]);

      await gate.requestLiveRefresh(live.refreshTrackedSessionOnce);
      expect(transport.golf, [initialGolf, wakeOne, wakeThree]);
      expect(golf.requestedTournamentIds, [
        'pga-live-1',
        'pga-live-1',
        'pga-live-1',
      ]);
      expect(diagnostics, contains('WAKE REFRESH #1 PGA'));
      expect(diagnostics, contains('WAKE REFRESH #2 PGA'));
      expect(diagnostics, contains('WAKE REFRESH #3 PGA'));
      expect(
        diagnostics,
        contains(
          allOf(contains('tracked canonical bytes='), contains('equal=false')),
        ),
      );
      expect(
        diagnostics,
        contains(
          allOf(
            contains('PGA difference: playerId=golfer-a'),
            contains('score=E'),
            contains('score=-1'),
            contains('detail=THRU 4'),
            contains('detail=THRU 5'),
          ),
        ),
      );
      expect(
        diagnostics.where((value) => value == 'PGA transfer succeeded'),
        hasLength(2),
      );
      expect(
        diagnostics.where((value) => value == 'PGA baseline replaced'),
        hasLength(2),
      );
      expect(diagnostics, contains('PGA no update: no relevant change'));
    },
  );

  test(
    'failed PGA WAKE transfer does not replace successful baseline',
    () async {
      final initialGolf = _pgaLeaderboard(score: 'E', detail: 'THRU 4');
      final freshGolf = _pgaLeaderboard(score: '-1', detail: 'THRU 5');
      final golf = _QueuedGolfSource(initialGolf, [freshGolf]);
      final repository = SportsRepository(
        _Source(mlbScores: const []),
        golfDataSource: golf,
      );
      final session = TrackedDeviceSession();
      final transport = _Transport();
      final sender = SessionAwareDeviceSender(
        transport: transport,
        session: session,
      );
      final gate = SportsOperationGate();
      final initial = InitialDeviceSyncCoordinator(
        repository: repository,
        sender: sender,
        isBleConnected: () => true,
        operationGate: gate,
        clock: () => _date,
      );
      final live = LiveRefreshCoordinator(
        repository: repository,
        transport: sender,
        session: session,
        isAppBackgrounded: () => false,
        isBleConnected: () => true,
        isLiveActivityActive: () async => true,
      );

      await initial.startForConnectionForTest();
      transport.failNextGolf = true;
      await gate.requestLiveRefresh(live.refreshTrackedSessionOnce);

      expect(transport.golf, [initialGolf]);
      final baseline = session[SportsLeague.pga] as TrackedGolfLeaderboard;
      expect(baseline.leaderboard.golfers.first.score, 'E');
      expect(baseline.leaderboard.golfers.first.detail, 'THRU 4');
    },
  );
}

final _date = DateTime(2026, 8, 22);

class _Source implements SportsDataSource {
  _Source({this.pendingNfl, required this.mlbScores});

  final Completer<List<SportsGame>>? pendingNfl;
  final List<int> mlbScores;
  int mlbFetchCount = 0;

  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  ) async {
    if (league == SportsLeague.nfl && pendingNfl != null) {
      return pendingNfl!.future;
    }
    if (league != SportsLeague.mlb) return const [];
    if (mlbScores.isEmpty) return const [];
    final index = mlbFetchCount < mlbScores.length
        ? mlbFetchCount
        : mlbScores.length - 1;
    mlbFetchCount++;
    return [_sportsGame(mlbScores[index])];
  }
}

class _GolfSource implements GolfDataSource {
  _GolfSource(this.initial, this.fresh);

  final GolfLeaderboard? initial;
  final GolfLeaderboard? fresh;

  @override
  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(DateTime date) async =>
      initial;

  @override
  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(String id) async =>
      fresh!;
}

class _QueuedGolfSource implements GolfDataSource {
  _QueuedGolfSource(this.initial, this.freshResponses);

  final GolfLeaderboard initial;
  final List<GolfLeaderboard> freshResponses;
  final requestedTournamentIds = <String>[];
  int _freshIndex = 0;

  @override
  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(DateTime date) async =>
      initial;

  @override
  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(String id) async {
    requestedTournamentIds.add(id);
    final response = freshResponses[_freshIndex];
    _freshIndex++;
    return response;
  }
}

class _Transport implements DeviceTransport {
  final mlbSlates = <List<GameData>>[];
  final golf = <GolfLeaderboard>[];
  bool failNextGolf = false;

  @override
  Future<void> sendControlCommand(String command) async {}

  @override
  Future<void> sendGameData(GameData gameData) async {}

  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    if (games.first.league == 'MLB') mlbSlates.add(List.of(games));
  }

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {
    if (failNextGolf) {
      failNextGolf = false;
      throw StateError('PGA transfer failed');
    }
    golf.add(leaderboard);
  }
}

SportsGame _sportsGame(int score) => SportsGame(
  eventId: 'mlb-1',
  league: 'MLB',
  awayTeam: 'A',
  homeTeam: 'H',
  awayScore: score,
  homeScore: 1,
  status: 'LIVE',
  clock: 'Top 5th',
  scheduledStartTime: _date,
);

GolfLeaderboard _golf(String score) => GolfLeaderboard(
  tournamentId: 'pga-1',
  tournamentName: 'Open',
  golfers: [
    GolfLeaderboardRow(playerId: '1', name: 'Player', rank: '1', score: score),
  ],
  isInProgress: true,
  isOver: false,
);

GolfLeaderboard _pgaLeaderboard({
  required String score,
  required String detail,
}) => GolfLeaderboard(
  tournamentId: 'pga-live-1',
  tournamentName: 'Live Open',
  golfers: [
    GolfLeaderboardRow(
      playerId: 'golfer-a',
      name: 'Golfer A',
      rank: '1',
      score: score,
      detail: detail,
    ),
    const GolfLeaderboardRow(
      playerId: 'golfer-b',
      name: 'Golfer B',
      rank: '2',
      score: '+1',
      detail: 'THRU 5',
    ),
  ],
  isInProgress: true,
  isOver: false,
);
