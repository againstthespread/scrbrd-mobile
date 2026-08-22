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

class _Transport implements DeviceTransport {
  final mlbSlates = <List<GameData>>[];
  final golf = <GolfLeaderboard>[];

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
