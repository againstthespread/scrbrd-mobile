import 'package:shared_preferences/shared_preferences.dart';

abstract interface class SleeperRosterIdStore {
  Future<int?> read();
  Future<void> save(int rosterId);
}

class SharedPreferencesSleeperRosterIdStore implements SleeperRosterIdStore {
  static const _key = 'sleeper_roster_id';

  @override
  Future<int?> read() async =>
      (await SharedPreferences.getInstance()).getInt(_key);

  @override
  Future<void> save(int rosterId) async {
    await (await SharedPreferences.getInstance()).setInt(_key, rosterId);
  }
}
