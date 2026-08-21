import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/background_score_updater.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_data_source.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';

void main() {
  group('BackgroundScoreUpdater', () {
    test('unchanged game does not write to BLE', () async {
      final game = _initialGame;
      final harness = _Harness(response: game);

      await harness.refreshOnce();

      expect(harness.transport.sentGames, isEmpty);
    });

    test('changed score writes once to BLE', () async {
      final harness = _Harness(response: _copyGame(awayScore: 3));

      await harness.refreshOnce();

      expect(harness.transport.sentGames, hasLength(1));
      expect(harness.transport.sentGames.single.awayScore, 3);
    });

    test('changed status and clock write once to BLE', () async {
      final harness = _Harness(
        response: _copyGame(status: 'FINAL', clock: 'Final'),
      );

      await harness.refreshOnce();

      expect(harness.transport.sentGames, hasLength(1));
      expect(harness.transport.sentGames.single.status, 'FINAL');
      expect(harness.transport.sentGames.single.clock, 'Final');
    });

    test('foreground MLB wake refreshes tracked content', () async {
      final harness = _Harness(response: _copyGame(awayScore: 3));
      harness.isBackgrounded = false;
      await harness.refreshOnce();

      expect(harness.dataSource.fetchCount, 1);
      expect(harness.transport.sentGames, hasLength(1));
    });

    for (final league in ['NFL', 'NBA']) {
      test('foreground $league wake refreshes tracked content', () async {
        final tracked = _teamGame(league: league, awayScore: 1);
        final harness = _Harness(
          trackedGame: tracked,
          response: _teamGame(league: league, awayScore: 2),
        )..isBackgrounded = false;

        await harness.refreshOnce();

        expect(harness.dataSource.fetchCount, 1);
        expect(harness.transport.sentGames.single.awayScore, 2);
      });
    }

    test('background MLB wake refreshes tracked content', () async {
      final harness = _Harness(response: _copyGame(awayScore: 4));

      await harness.refreshOnce();

      expect(harness.dataSource.fetchCount, 1);
      expect(harness.transport.sentGames.single.awayScore, 4);
    });

    test('MLB inning, bases, and outs changes cause one BLE write', () async {
      const baseballState = BaseballGameState(
        runnerOnFirst: true,
        runnerOnSecond: true,
        runnerOnThird: false,
        outs: 2,
      );
      final harness = _Harness(
        response: _copyGame(clock: 'Bot 5th', baseballState: baseballState),
      )..isBackgrounded = false;

      await harness.refreshOnce();

      expect(harness.transport.sentGames, hasLength(1));
      expect(harness.transport.sentGames.single.clock, 'Bot 5th');
      expect(harness.transport.sentGames.single.baseballState?.outs, 2);
    });

    test('overlapping team wakes do not launch duplicate refreshes', () async {
      final pending = Completer<GameData>();
      final diagnostics = <String>[];
      final harness = _Harness(
        response: _initialGame,
        pendingTeamResponse: pending,
        onDiagnostic: diagnostics.add,
      )..isBackgrounded = false;

      final first = harness.updater.refreshTrackedContentOnce();
      await Future<void>.delayed(Duration.zero);
      await harness.updater.refreshTrackedContentOnce();
      pending.complete(_initialGame);
      await first;

      expect(harness.dataSource.fetchCount, 1);
      expect(
        diagnostics,
        contains('refresh skipped because another refresh is in progress'),
      );
    });

    test('updater does not refresh when BLE is disconnected', () async {
      final harness = _Harness(response: _initialGame);
      harness.isConnected = false;
      await harness.refreshOnce();

      expect(harness.dataSource.fetchCount, 0);
    });

    test('updater does not run without an active Live Activity', () async {
      final harness = _Harness(response: _initialGame)
        ..isLiveActivityActive = false;

      await harness.refreshOnce();

      expect(harness.dataSource.fetchCount, 0);
    });

    test(
      'PGA refresh reuses tournament ID and writes only when changed',
      () async {
        final previous = _golf('-8');
        final fresh = _golf('-9');
        final golfSource = _FakeGolfDataSource(fresh);
        final transport = _RecordingTransport();
        final updater = BackgroundScoreUpdater(
          repository: SportsRepository(
            _FakeSportsDataSource(_initialGame),
            golfDataSource: golfSource,
          ),
          transport: transport,
          isAppBackgrounded: () => true,
          isBleConnected: () => true,
          isLiveActivityActive: () async => true,
          trackedGame: () => null,
          trackedGolf: () => previous,
        );

        await updater.refreshTrackedContentOnce();

        expect(golfSource.requestedTournamentId, 'tournament-1');
        expect(transport.sentGolf, [fresh]);
      },
    );

    test('foreground PGA refresh does not require Live Activity', () async {
      final previous = _golf('-8');
      final fresh = _golf('-9');
      final golfSource = _FakeGolfDataSource(fresh);
      final transport = _RecordingTransport();
      final updater = _golfUpdater(
        previous: () => previous,
        golfSource: golfSource,
        transport: transport,
        isBackgrounded: false,
        isLiveActivityActive: false,
      );

      await updater.refreshTrackedContentOnce();

      expect(golfSource.fetchCount, 1);
      expect(transport.sentGolf, [fresh]);
    });

    test('background PGA refresh still requires Live Activity', () async {
      final previous = _golf('-8');
      final fresh = _golf('-9');
      final golfSource = _FakeGolfDataSource(fresh);
      final transport = _RecordingTransport();
      final updater = _golfUpdater(
        previous: () => previous,
        golfSource: golfSource,
        transport: transport,
        isBackgrounded: true,
        isLiveActivityActive: true,
      );

      await updater.refreshTrackedContentOnce();

      expect(golfSource.fetchCount, 1);
      expect(transport.sentGolf, [fresh]);
    });

    test('unchanged PGA leaderboard causes no BLE write', () async {
      final previous = _golf('-8');
      final source = _FakeGolfDataSource(previous);
      final transport = _RecordingTransport();
      final updater = _golfUpdater(
        previous: () => previous,
        golfSource: source,
        transport: transport,
        isBackgrounded: false,
      );

      await updater.refreshTrackedContentOnce();

      expect(transport.sentGolf, isEmpty);
    });

    test('changed PGA THRU detail causes one BLE write', () async {
      final previous = _golf('-8', detail: 'THRU 7');
      final fresh = _golf('-8', detail: 'THRU 8');
      final source = _FakeGolfDataSource(fresh);
      final transport = _RecordingTransport();
      final updater = _golfUpdater(
        previous: () => previous,
        golfSource: source,
        transport: transport,
        isBackgrounded: false,
      );

      await updater.refreshTrackedContentOnce();

      expect(transport.sentGolf, [fresh]);
    });

    test('overlapping PGA wakes do not launch duplicate refreshes', () async {
      final previous = _golf('-8');
      final pending = Completer<GolfLeaderboard>();
      final source = _FakeGolfDataSource(previous)..pending = pending;
      final transport = _RecordingTransport();
      final diagnostics = <String>[];
      final updater = _golfUpdater(
        previous: () => previous,
        golfSource: source,
        transport: transport,
        isBackgrounded: false,
        onDiagnostic: diagnostics.add,
      );

      final first = updater.refreshTrackedContentOnce();
      await Future<void>.delayed(Duration.zero);
      await updater.refreshTrackedContentOnce();
      pending.complete(previous);
      await first;

      expect(source.fetchCount, 1);
      expect(
        diagnostics,
        contains('refresh skipped because another refresh is in progress'),
      );
    });

    test('successful PGA send becomes the next comparison baseline', () async {
      var tracked = _golf('-8');
      final fresh = _golf('-9');
      final source = _FakeGolfDataSource(fresh);
      final transport = _RecordingTransport()
        ..onGolfSent = (value) => tracked = value;
      final updater = _golfUpdater(
        previous: () => tracked,
        golfSource: source,
        transport: transport,
        isBackgrounded: false,
      );

      await updater.refreshTrackedContentOnce();
      await updater.refreshTrackedContentOnce();

      expect(transport.sentGolf, [fresh]);
    });
  });
}

GolfLeaderboard _golf(String score, {String? detail}) => GolfLeaderboard(
  tournamentId: 'tournament-1',
  tournamentName: 'Championship',
  golfers: [
    GolfLeaderboardRow(
      playerId: '400',
      name: 'Golfer',
      rank: '1',
      score: score,
      detail: detail,
    ),
  ],
  isInProgress: true,
  isOver: false,
);

BackgroundScoreUpdater _golfUpdater({
  required GolfLeaderboard? Function() previous,
  required _FakeGolfDataSource golfSource,
  required _RecordingTransport transport,
  required bool isBackgrounded,
  bool isLiveActivityActive = true,
  void Function(String)? onDiagnostic,
}) {
  return BackgroundScoreUpdater(
    repository: SportsRepository(
      _FakeSportsDataSource(_initialGame),
      golfDataSource: golfSource,
    ),
    transport: transport,
    isAppBackgrounded: () => isBackgrounded,
    isBleConnected: () => true,
    isLiveActivityActive: () async => isLiveActivityActive,
    trackedGame: () => null,
    trackedGolf: previous,
    onDiagnostic: onDiagnostic,
  );
}

final _initialGame = GameData(
  eventId: 'game-42',
  league: 'MLB',
  awayTeam: 'NYY',
  homeTeam: 'BOS',
  awayScore: 1,
  homeScore: 2,
  status: 'LIVE',
  clock: 'Top 4',
  scheduledStartTime: _gameTime,
);

final _gameTime = DateTime(2026, 8, 10, 19);

GameData _copyGame({
  int awayScore = 1,
  String status = 'LIVE',
  String clock = 'Top 4',
  BaseballGameState? baseballState,
}) {
  return GameData(
    eventId: _initialGame.eventId,
    league: _initialGame.league,
    awayTeam: _initialGame.awayTeam,
    homeTeam: _initialGame.homeTeam,
    awayScore: awayScore,
    homeScore: _initialGame.homeScore,
    status: status,
    clock: clock,
    baseballState: baseballState,
    scheduledStartTime: _initialGame.scheduledStartTime,
  );
}

GameData _teamGame({required String league, required int awayScore}) =>
    GameData(
      eventId: '$league-game-1',
      league: league,
      awayTeam: 'AWAY',
      homeTeam: 'HOME',
      awayScore: awayScore,
      homeScore: 0,
      status: 'LIVE',
      clock: '5:00',
      scheduledStartTime: _gameTime,
    );

class _Harness {
  _Harness({
    required GameData response,
    GameData? trackedGame,
    Completer<GameData>? pendingTeamResponse,
    void Function(String)? onDiagnostic,
  }) : trackedGame = trackedGame ?? _initialGame,
       dataSource = _FakeSportsDataSource(response) {
    dataSource.pending = pendingTeamResponse;
    updater = BackgroundScoreUpdater(
      repository: SportsRepository(dataSource),
      transport: transport,
      isAppBackgrounded: () => isBackgrounded,
      isBleConnected: () => isConnected,
      isLiveActivityActive: () async => isLiveActivityActive,
      trackedGame: () => this.trackedGame,
      onDiagnostic: onDiagnostic,
    );
  }

  final _RecordingTransport transport = _RecordingTransport();
  final GameData trackedGame;
  final _FakeSportsDataSource dataSource;
  late final BackgroundScoreUpdater updater;
  bool isBackgrounded = true;
  bool isConnected = true;
  bool isLiveActivityActive = true;

  Future<void> refreshOnce() async {
    await updater.refreshTrackedContentOnce();
  }
}

class _FakeSportsDataSource implements SportsDataSource {
  _FakeSportsDataSource(this.response);

  final GameData response;
  var fetchCount = 0;
  Completer<GameData>? pending;

  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  ) async {
    fetchCount += 1;
    final effectiveResponse = await (pending?.future ?? Future.value(response));
    return [
      SportsGame(
        eventId: effectiveResponse.eventId,
        league: effectiveResponse.league,
        awayTeam: effectiveResponse.awayTeam,
        homeTeam: effectiveResponse.homeTeam,
        awayScore: effectiveResponse.awayScore,
        homeScore: effectiveResponse.homeScore,
        status: effectiveResponse.status,
        clock: effectiveResponse.clock,
        statusDetail: effectiveResponse.statusDetail,
        scheduledStartTime: effectiveResponse.scheduledStartTime,
        baseballState: effectiveResponse.baseballState,
      ),
    ];
  }
}

class _RecordingTransport implements DeviceTransport {
  final sentGames = <GameData>[];
  final sentGolf = <GolfLeaderboard>[];
  void Function(GolfLeaderboard)? onGolfSent;

  @override
  Future<void> sendGameData(GameData gameData) async {
    sentGames.add(gameData);
  }

  @override
  Future<void> sendGameSlate(List<GameData> games) async {}

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {
    sentGolf.add(leaderboard);
    onGolfSent?.call(leaderboard);
  }
}

class _FakeGolfDataSource implements GolfDataSource {
  _FakeGolfDataSource(this.response);

  final GolfLeaderboard response;
  String? requestedTournamentId;
  var fetchCount = 0;
  Completer<GolfLeaderboard>? pending;

  @override
  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(
    String tournamentId,
  ) async {
    fetchCount += 1;
    requestedTournamentId = tournamentId;
    final pendingRequest = pending;
    if (pendingRequest != null) return pendingRequest.future;
    return response;
  }

  @override
  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(
    DateTime selectedDate,
  ) async {
    return response;
  }
}
