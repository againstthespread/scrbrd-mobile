import 'favorite_team.dart';
import 'game_data.dart';
import 'sports_league.dart';

class FavoriteGamePrioritizer {
  const FavoriteGamePrioritizer();

  List<GameData> prioritize(
    SportsLeague league,
    List<GameData> games,
    Iterable<FavoriteTeam> favorites,
  ) {
    if (league == SportsLeague.pga) return List.of(games);
    final keys = favorites
        .where((team) => team.league == league)
        .map((team) => team.key)
        .toSet();
    if (keys.isEmpty) return List.of(games);
    final preferred = <GameData>[];
    final remaining = <GameData>[];
    for (final game in games) {
      (keys.contains(game.awayTeamKey) || keys.contains(game.homeTeamKey)
              ? preferred
              : remaining)
          .add(game);
    }
    return [...preferred, ...remaining];
  }
}
