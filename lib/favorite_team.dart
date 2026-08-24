import 'sports_league.dart';

class FavoriteTeam {
  const FavoriteTeam({
    required this.league,
    required this.key,
    required this.abbreviation,
    required this.displayName,
    this.aliases = const {},
  });

  final SportsLeague league;
  final String key;
  final String abbreviation;
  final String displayName;
  final Set<String> aliases;

  String get storageKey => '${league.name}:$key';
}
