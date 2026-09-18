import 'package:shared_preferences/shared_preferences.dart';

abstract interface class SleeperUsernameStore {
  Future<String?> read();
  Future<void> save(String username);
}

class SharedPreferencesSleeperUsernameStore implements SleeperUsernameStore {
  static const _key = 'sleeper_discovery_username_v1';
  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(_key);
  @override
  Future<void> save(String username) async =>
      (await SharedPreferences.getInstance()).setString(_key, username.trim());
}
