import 'sports_game.dart';
import 'sports_league.dart';

abstract class SportsDataSource {
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  );
}
