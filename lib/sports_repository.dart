import 'game_data.dart';
import 'golf_data_source.dart';
import 'golf_leaderboard.dart';
import 'sports_data_source.dart';
import 'sports_game.dart';
import 'sports_league.dart';

class SportsRepository {
  SportsRepository(this._dataSource, {GolfDataSource? golfDataSource})
    : _golfDataSource =
          golfDataSource ??
          (_dataSource is GolfDataSource
              ? _dataSource as GolfDataSource
              : null);

  final SportsDataSource _dataSource;
  final GolfDataSource? _golfDataSource;

  Future<List<GameData>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  ) async {
    final games = await _dataSource.fetchGamesForDate(league, selectedDate);
    return games.map(_gameDataFromSportsGame).toList();
  }

  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(
    DateTime selectedDate,
  ) async {
    final source = _golfDataSource;
    if (source == null) return null;
    return source.fetchGolfLeaderboardForDate(selectedDate);
  }

  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(
    String tournamentId,
  ) async {
    final source = _golfDataSource;
    if (source == null) {
      throw StateError('Golf data source is unavailable.');
    }
    return source.fetchGolfLeaderboardByTournamentId(tournamentId);
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
      eventId: game.eventId,
    );
  }
}
