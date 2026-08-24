import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'favorite_team.dart';
import 'sports_league.dart';
import 'team_catalog.dart';

abstract interface class FavoritesStore implements Listenable {
  Set<FavoriteTeam> readFavorites();
  Future<void> setFavorite(FavoriteTeam team, bool enabled);
  bool isFavorite(SportsLeague league, String key);
  Set<FavoriteTeam> favoritesForLeague(SportsLeague league);
}

class MemoryFavoritesStore extends ChangeNotifier implements FavoritesStore {
  final Set<FavoriteTeam> _favorites = {};
  @override
  Set<FavoriteTeam> readFavorites() => Set.unmodifiable(_favorites);
  @override
  bool isFavorite(SportsLeague league, String key) =>
      _favorites.any((team) => team.league == league && team.key == key);
  @override
  Set<FavoriteTeam> favoritesForLeague(SportsLeague league) =>
      Set.unmodifiable(_favorites.where((team) => team.league == league));
  @override
  Future<void> setFavorite(FavoriteTeam team, bool enabled) async {
    enabled ? _favorites.add(team) : _favorites.remove(team);
    notifyListeners();
  }
}

class SharedPreferencesFavoritesStore extends ChangeNotifier
    implements FavoritesStore {
  SharedPreferencesFavoritesStore._(this._preferences, this._favorites);

  static const preferencesKey = 'favorite_team_keys_v1';
  final SharedPreferences _preferences;
  final Set<FavoriteTeam> _favorites;

  static Future<SharedPreferencesFavoritesStore> create({
    SharedPreferences? preferences,
  }) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final loaded = <FavoriteTeam>{};
    for (final value in prefs.getStringList(preferencesKey) ?? const []) {
      final team = TeamCatalog.byStorageKey(value);
      if (team != null) loaded.add(team);
    }
    return SharedPreferencesFavoritesStore._(prefs, loaded);
  }

  @override
  Set<FavoriteTeam> readFavorites() => Set.unmodifiable(_favorites);

  @override
  bool isFavorite(SportsLeague league, String key) =>
      _favorites.any((team) => team.league == league && team.key == key);

  @override
  Set<FavoriteTeam> favoritesForLeague(SportsLeague league) =>
      Set.unmodifiable(_favorites.where((team) => team.league == league));

  @override
  Future<void> setFavorite(FavoriteTeam team, bool enabled) async {
    enabled ? _favorites.add(team) : _favorites.remove(team);
    final ordered = TeamCatalog.teams
        .where(_favorites.contains)
        .map((team) => team.storageKey)
        .toList();
    await _preferences.setStringList(preferencesKey, ordered);
    notifyListeners();
  }
}
