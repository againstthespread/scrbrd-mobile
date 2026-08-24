import 'college_football.dart';
import 'game_data.dart';
import 'power_four_team_catalog.dart';
import 'sports_league.dart';

class PowerFourGameFilter {
  const PowerFourGameFilter();

  List<GameData> filter(
    List<GameData> games,
    Iterable<NcaafConference> selectedConferences,
  ) {
    final selected = selectedConferences.toSet();
    final result = <GameData>[];
    final seenIds = <String>{};
    for (final game in games) {
      final away = PowerFourTeamCatalog.conferenceForKey(game.awayTeamKey);
      final home = PowerFourTeamCatalog.conferenceForKey(game.homeTeamKey);
      if (!selected.contains(away) && !selected.contains(home)) continue;
      final id = game.eventId?.trim();
      if (id != null && id.isNotEmpty && !seenIds.add(id)) continue;
      result.add(game);
    }
    return result;
  }
}

List<GameData> applyCollegeFootballFilter(
  SportsLeague league,
  List<GameData> games,
  CollegeFootballPreferences preferences,
) => league == SportsLeague.ncaaf
    ? const PowerFourGameFilter().filter(games, preferences.conferences)
    : List.of(games);
