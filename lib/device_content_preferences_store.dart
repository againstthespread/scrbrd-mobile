import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_content_preferences.dart';
import 'preference_save.dart';

abstract interface class DeviceContentPreferencesStore implements Listenable {
  DeviceContentPreferences read();
  Future<void> save(DeviceContentPreferences preferences);
}

class SharedPreferencesDeviceContentPreferencesStore extends ChangeNotifier
    implements DeviceContentPreferencesStore {
  SharedPreferencesDeviceContentPreferencesStore._(
    this._preferences,
    this._value,
  );

  static const preferencesKey = 'device_content_preferences_v1';
  final SharedPreferences _preferences;
  final _saves = PreferenceSaveQueue();
  DeviceContentPreferences _value;

  static Future<SharedPreferencesDeviceContentPreferencesStore> create({
    SharedPreferences? preferences,
  }) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    return SharedPreferencesDeviceContentPreferencesStore._(
      prefs,
      _decode(readPreferenceStringList(prefs, preferencesKey)),
    );
  }

  @override
  DeviceContentPreferences read() => _value;

  @override
  Future<void> save(DeviceContentPreferences preferences) => _saves.save(
    _preferences,
    () => _preferences.setStringList(preferencesKey, [
      for (final entry in preferences.entries)
        '${entry.category.name}:${entry.enabled ? '1' : '0'}',
    ]),
    () {
      _value = preferences;
      notifyListeners();
    },
  );

  static DeviceContentPreferences _decode(List<String>? persisted) {
    if (persisted == null) return DeviceContentPreferences.defaults();
    final known = <DeviceContentCategory, bool>{};
    final order = <DeviceContentCategory>[];
    for (final raw in persisted) {
      final parts = raw.split(':');
      if (parts.length != 2) continue;
      final category = DeviceContentCategory.values
          .where((value) => value.name == parts[0])
          .firstOrNull;
      if (category == null || known.containsKey(category)) continue;
      known[category] = parts[1] != '0';
      order.add(category);
    }
    for (final category in DeviceContentCategory.values) {
      if (!known.containsKey(category)) {
        known[category] = true;
        order.add(category);
      }
    }
    return DeviceContentPreferences([
      for (final category in order)
        DeviceContentPreference(category: category, enabled: known[category]!),
    ]);
  }
}

class MemoryDeviceContentPreferencesStore extends ChangeNotifier
    implements DeviceContentPreferencesStore {
  MemoryDeviceContentPreferencesStore([DeviceContentPreferences? initial])
    : _value = initial ?? DeviceContentPreferences.defaults();
  DeviceContentPreferences _value;
  @override
  DeviceContentPreferences read() => _value;
  @override
  Future<void> save(DeviceContentPreferences preferences) async {
    _value = preferences;
    notifyListeners();
  }
}
