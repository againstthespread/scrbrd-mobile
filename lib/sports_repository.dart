import 'game_data.dart';
import 'sports_data_source.dart';
import 'sports_game.dart';
import 'sports_league.dart';

class SportsRepository {
  const SportsRepository(this._dataSource);

  final SportsDataSource _dataSource;

  Future<List<GameData>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  ) async {
    final games = await _dataSource.fetchGamesForDate(league, selectedDate);
    return games.map(_gameDataFromSportsGame).toList();
  }

  GameData _gameDataFromSportsGame(SportsGame game) {
    return GameData(
      league: game.league,
      awayTeam: game.awayTeam,
      homeTeam: game.homeTeam,
      awayScore: game.awayScore,
      homeScore: game.homeScore,
      status: game.status,
      clock: game.clock,
      statusDetail: game.statusDetail,
      scheduledStartTime: game.scheduledStartTime,
    );
  }
}
