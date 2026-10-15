import 'refresh_diagnostic_history.dart';
import 'game_data.dart';
import 'golf_data_source.dart';
import 'golf_leaderboard.dart';
import 'sports_data_source.dart';
import 'sports_game.dart';
import 'sports_league.dart';

class SportsRepository {
  SportsRepository(
    this._dataSource, {
    GolfDataSource? golfDataSource,
    RefreshDiagnosticHistory? diagnosticHistory,
  }) : diagnosticHistory =
           diagnosticHistory ?? RefreshDiagnosticHistory.session,
       _golfDataSource =
           golfDataSource ??
           (_dataSource is GolfDataSource
               ? _dataSource as GolfDataSource
               : null);

  final RefreshDiagnosticHistory diagnosticHistory;
  final SportsDataSource _dataSource;
  final GolfDataSource? _golfDataSource;

  Future<List<GameData>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate, {
    bool Function()? isCurrent,
  }) async {
    final games = await diagnosticHistory.trackProvider(
      'sports:${league.name}',
      () => _dataSource.fetchGamesForDate(league, selectedDate),
      scope: selectedDate.toIso8601String().substring(0, 10),
      isCurrent: isCurrent,
      isEmpty: (games) => games.isEmpty,
    );
    return games.map(_gameDataFromSportsGame).toList();
  }

  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(
    DateTime selectedDate, {
    bool Function()? isCurrent,
  }) async {
    final source = _golfDataSource;
    if (source == null) return null;
    return diagnosticHistory.trackProvider(
      'sports:pga',
      () async {
        return source.fetchGolfLeaderboardForDate(selectedDate);
      },
      scope: selectedDate.toIso8601String().substring(0, 10),
      isCurrent: isCurrent,
      isEmpty: (golf) => golf == null || golf.golfers.isEmpty,
    );
  }

  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(
    String tournamentId, {
    bool Function()? isCurrent,
  }) async {
    final source = _golfDataSource;
    if (source == null) {
      throw StateError('Golf data source is unavailable.');
    }
    return diagnosticHistory.trackProvider(
      'sports:pga',
      () => source.fetchGolfLeaderboardByTournamentId(tournamentId),
      scope: 'tournament:$tournamentId',
      isCurrent: isCurrent,
      isEmpty: (golf) => golf.golfers.isEmpty,
    );
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
      awayTeamKey: game.awayTeamKey,
      homeTeamKey: game.homeTeamKey,
      baseballState: game.baseballState,
      footballState: game.footballState,
    );
  }
}
