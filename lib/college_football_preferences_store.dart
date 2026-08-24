import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'college_football.dart';

abstract interface class CollegeFootballPreferencesStore implements Listenable {
  CollegeFootballPreferences read();
  Future<void> save(CollegeFootballPreferences preferences);
}

class SharedPreferencesCollegeFootballPreferencesStore extends ChangeNotifier
    implements CollegeFootballPreferencesStore {
  SharedPreferencesCollegeFootballPreferencesStore._(
    this._preferences,
    this._value,
  );
  static const preferencesKey = 'college_football_conferences_v1';
  final SharedPreferences _preferences;
  CollegeFootballPreferences _value;

  static Future<SharedPreferencesCollegeFootballPreferencesStore> create({
    SharedPreferences? preferences,
  }) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final values = prefs.getStringList(preferencesKey);
    final selected = values
        ?.map(
          (key) => NcaafConference.values
              .where((value) => value.name == key)
              .firstOrNull,
        )
        .nonNulls
        .toSet();
    return SharedPreferencesCollegeFootballPreferencesStore._(
      prefs,
      selected == null || selected.isEmpty
          ? CollegeFootballPreferences.defaults()
          : CollegeFootballPreferences(selected),
    );
  }

  @override
  CollegeFootballPreferences read() => _value;
  @override
  Future<void> save(CollegeFootballPreferences preferences) async {
    _value = preferences;
    await _preferences.setStringList(
      preferencesKey,
      NcaafConference.values
          .where(preferences.contains)
          .map((value) => value.name)
          .toList(),
    );
    notifyListeners();
  }
}

class MemoryCollegeFootballPreferencesStore extends ChangeNotifier
    implements CollegeFootballPreferencesStore {
  MemoryCollegeFootballPreferencesStore([CollegeFootballPreferences? initial])
    : _value = initial ?? CollegeFootballPreferences.defaults();
  CollegeFootballPreferences _value;
  @override
  CollegeFootballPreferences read() => _value;
  @override
  Future<void> save(CollegeFootballPreferences preferences) async {
    _value = preferences;
    notifyListeners();
  }
}
