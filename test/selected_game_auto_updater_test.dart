import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/selected_game_auto_updater.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';

void main() {
  group('SelectedGameAutoUpdater', () {
    test('does not send when the refreshed packet is identical', () async {
      const selectedGame = GameData(
        league: 'MLB',
        awayTeam: 'NYY',
        homeTeam: 'BOS',
        awayScore: 1,
        homeScore: 2,
        status: 'LIVE',
        clock: 'Top 4',
      );
      final transport = _RecordingTransport();
      final updater = SelectedGameAutoUpdater(
        repository: SportsRepository(
          _FakeSportsDataSource([
            [_sportsGameFromGameData(selectedGame)],
          ]),
        ),
        transport: transport,
        league: SportsLeague.mlb,
        selectedDate: DateTime(2026, 8, 10),
        selectedGame: selectedGame,
        lastSentGame: selectedGame,
      );

      await updater.refreshNow();

      expect(transport.sentGames, isEmpty);
    });

    test('sends once when the selected game packet changes', () async {
      const selectedGame = GameData(
        league: 'MLB',
        awayTeam: 'NYY',
        homeTeam: 'BOS',
        awayScore: 1,
        homeScore: 2,
        status: 'LIVE',
        clock: 'Top 4',
      );
      const updatedGame = GameData(
        league: 'MLB',
        awayTeam: 'NYY',
        homeTeam: 'BOS',
        awayScore: 3,
        homeScore: 2,
        status: 'LIVE',
        clock: 'Bot 4',
      );
      final transport = _RecordingTransport();
      final updater = SelectedGameAutoUpdater(
        repository: SportsRepository(
          _FakeSportsDataSource([
            [_sportsGameFromGameData(updatedGame)],
            [_sportsGameFromGameData(updatedGame)],
          ]),
        ),
        transport: transport,
        league: SportsLeague.mlb,
        selectedDate: DateTime(2026, 8, 10),
        selectedGame: selectedGame,
        lastSentGame: selectedGame,
      );

      await updater.refreshNow();
      await updater.refreshNow();

      expect(transport.sentGames, hasLength(1));
      expect(transport.sentGames.single.awayScore, 3);
      expect(transport.sentGames.single.clock, 'Bot 4');
    });

    test('ignores other games on the same refresh', () async {
      const selectedGame = GameData(
        league: 'NBA',
        awayTeam: 'BOS',
        homeTeam: 'NY',
        awayScore: 88,
        homeScore: 91,
        status: 'LIVE',
        clock: 'Q4 5:12',
      );
      const otherGame = GameData(
        league: 'NBA',
        awayTeam: 'LAL',
        homeTeam: 'GS',
        awayScore: 100,
        homeScore: 101,
        status: 'LIVE',
        clock: 'Q4 1:00',
      );
      final transport = _RecordingTransport();
      final updater = SelectedGameAutoUpdater(
        repository: SportsRepository(
          _FakeSportsDataSource([
            [_sportsGameFromGameData(otherGame)],
          ]),
        ),
        transport: transport,
        league: SportsLeague.nba,
        selectedDate: DateTime(2026, 8, 10),
        selectedGame: selectedGame,
        lastSentGame: selectedGame,
      );

      await updater.refreshNow();

      expect(transport.sentGames, isEmpty);
    });
  });
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
}
