import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/background_score_updater.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
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

    test('updater does not refresh when app is foregrounded', () async {
      final harness = _Harness(response: _initialGame);
      harness.isBackgrounded = false;
      await harness.refreshOnce();

      expect(harness.dataSource.fetchCount, 0);
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
  });
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
    scheduledStartTime: _initialGame.scheduledStartTime,
  );
}

class _Harness {
  _Harness({required GameData response})
    : dataSource = _FakeSportsDataSource(response) {
    updater = BackgroundScoreUpdater(
      repository: SportsRepository(dataSource),
      transport: transport,
      isAppBackgrounded: () => isBackgrounded,
      isBleConnected: () => isConnected,
      isLiveActivityActive: () async => isLiveActivityActive,
      trackedGame: () => _initialGame,
    );
  }

  final _RecordingTransport transport = _RecordingTransport();
  final _FakeSportsDataSource dataSource;
  late final BackgroundScoreUpdater updater;
  bool isBackgrounded = true;
  bool isConnected = true;
  bool isLiveActivityActive = true;

  Future<void> refreshOnce() async {
    await updater.refreshTrackedGameOnce();
  }
}

class _FakeSportsDataSource implements SportsDataSource {
  _FakeSportsDataSource(this.response);

  final GameData response;
  var fetchCount = 0;

  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  ) async {
    fetchCount += 1;
    return [
      SportsGame(
        eventId: response.eventId,
        league: response.league,
        awayTeam: response.awayTeam,
        homeTeam: response.homeTeam,
        awayScore: response.awayScore,
        homeScore: response.homeScore,
        status: response.status,
        clock: response.clock,
        statusDetail: response.statusDetail,
        scheduledStartTime: response.scheduledStartTime,
      ),
    ];
  }
}

class _RecordingTransport implements DeviceTransport {
  final sentGames = <GameData>[];

  @override
  Future<void> sendGameData(GameData gameData) async {
    sentGames.add(gameData);
  }
}
