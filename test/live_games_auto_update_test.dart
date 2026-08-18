import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/live_games_screen.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';

void main() {
  testWidgets(
    'successful manual send starts updater and sends changed refreshed game',
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
      final updatedGame = GameData(
        eventId: 'mlb-game-42',
        league: 'MLB',
        awayTeam: 'NYY',
        homeTeam: 'BOS',
        awayScore: 3,
        homeScore: 2,
        status: 'LIVE',
        clock: 'Bot 4',
        scheduledStartTime: DateTime(2026, 8, 10, 19),
      );
      final dataSource = _FakeSportsDataSource([
        [_sportsGameFromGameData(initialGame)],
        [_sportsGameFromGameData(updatedGame)],
      ]);
      final transport = _RecordingTransport();

      await tester.pumpWidget(
        MaterialApp(
          home: LiveGamesScreen(
            repository: SportsRepository(dataSource),
            transport: transport,
            autoUpdateRefreshInterval: const Duration(seconds: 1),
          ),
        ),
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Refresh'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('NYY at BOS'));
      await tester.pumpAndSettle();

      final sendButton = find.widgetWithText(OutlinedButton, 'Send to Device');
      await tester.ensureVisible(sendButton);
      await tester.tap(sendButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));

      expect(transport.sentGames, hasLength(2));
      expect(transport.sentGames.first.awayScore, 1);
      expect(transport.sentGames.first.eventId, 'mlb-game-42');
      expect(transport.sentGames.last.awayScore, 3);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('Temporary Auto-Update Diagnostics'), findsOneWidget);
      expect(
        find.textContaining('BLE send succeeded', findRichText: true),
        findsOneWidget,
      );
    },
  );
}

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
  Future<void> sendGameData(GameData gameData) async {
    sentGames.add(gameData);
  }

  @override
  Future<void> sendGameSlate(List<GameData> games) async {}
}
