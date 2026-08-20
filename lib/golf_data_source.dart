import 'golf_leaderboard.dart';

abstract class GolfDataSource {
  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(DateTime selectedDate);

  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(
    String tournamentId,
  );
}
