import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/live_games_screen.dart';
import 'package:sports_hub_mobile/session_aware_device_sender.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  testWidgets(
    'successful manual send does not start a recurring foreground timer',
    (tester) async {
      final initialGame = GameData(
        eventId: 'mlb-game-42',
        league: 'MLB',
        awayTeam: 'NYY',
        homeTeam: 'BOS',
        awayScore: 1,
        homeScore: 2,
        status: 'LIVE',
        clock: 'Top 4',
        scheduledStartTime: DateTime(2026, 8, 10, 19),
      );
      final dataSource = _FakeSportsDataSource([
        [_sportsGameFromGameData(initialGame)],
      ]);
      final transport = _RecordingTransport();

      await tester.pumpWidget(
        MaterialApp(
          home: LiveGamesScreen(
            repository: SportsRepository(dataSource),
            transport: transport,
            developerMode: true,
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.tap(find.text('NYY at BOS'));
      await tester.pumpAndSettle();

      final sendButton = find.widgetWithText(OutlinedButton, 'Send to Device');
      await tester.ensureVisible(sendButton);
      await tester.tap(sendButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));

      expect(transport.sentGames, hasLength(1));
      expect(transport.sentGames.first.awayScore, 1);
      expect(transport.sentGames.first.eventId, 'mlb-game-42');
      expect(dataSource.fetchCount, 1);
    },
  );

  testWidgets('Games refresh does not initialize TrackedDeviceSession', (
    tester,
  ) async {
    final dataSource = _FakeSportsDataSource([
      [_sportsGameFromGameData(_gameForRefresh)],
      [_sportsGameFromGameData(_gameForRefresh)],
    ]);
    final session = TrackedDeviceSession();
    final sender = SessionAwareDeviceSender(
      transport: _RecordingTransport(),
      session: session,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LiveGamesScreen(
          repository: SportsRepository(dataSource),
          transport: sender,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(session.snapshot(), isEmpty);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(session.snapshot(), isEmpty);
  });
}

final _gameForRefresh = GameData(
  eventId: 'mlb-refresh',
  league: 'MLB',
  awayTeam: 'NYY',
  homeTeam: 'BOS',
  awayScore: 1,
  homeScore: 0,
  status: 'LIVE',
  clock: 'Top 3rd',
  scheduledStartTime: DateTime(2026, 8, 22),
);

SportsGame _sportsGameFromGameData(GameData gameData) {
  return SportsGame(
    league: gameData.league,
    awayTeam: gameData.awayTeam,
    homeTeam: gameData.homeTeam,
    awayScore: gameData.awayScore,
    homeScore: gameData.homeScore,
    status: gameData.status,
    clock: gameData.clock,
    statusDetail: gameData.statusDetail,
    scheduledStartTime: gameData.scheduledStartTime,
    eventId: gameData.eventId,
  );
}

class _FakeSportsDataSource implements SportsDataSource {
  _FakeSportsDataSource(this._responses);

  final List<List<SportsGame>> _responses;
  var _fetchCount = 0;
  int get fetchCount => _fetchCount;

  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  ) async {
    final responseIndex = _fetchCount >= _responses.length
        ? _responses.length - 1
        : _fetchCount;
    final response = _responses[responseIndex];
    _fetchCount += 1;
    return response;
  }
}

class _RecordingTransport implements DeviceTransport {
  final sentGames = <GameData>[];

  @override
  Future<void> sendControlCommand(String command) async {}

  @override
  Future<void> sendGameData(GameData gameData) async {
    sentGames.add(gameData);
  }

  @override
  Future<void> sendGameSlate(List<GameData> games) async {}

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {}
}
