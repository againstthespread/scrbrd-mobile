import 'package:shared_preferences/shared_preferences.dart';

abstract interface class SleeperLeagueIdStore {
  Future<String?> read();
  Future<void> save(String leagueId);
}

class SharedPreferencesSleeperLeagueIdStore implements SleeperLeagueIdStore {
  static const _key = 'sleeper_league_id';

  @override
  Future<String?> read() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_key);
  }

  @override
  Future<void> save(String leagueId) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_key, leagueId);
  }
}
