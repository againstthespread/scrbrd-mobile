import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports_hub_mobile/device_content_preferences.dart';
import 'package:sports_hub_mobile/device_content_preferences_store.dart';
import 'package:sports_hub_mobile/sports_league.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('default profile enables all categories in canonical order', () async {
    final store = await SharedPreferencesDeviceContentPreferencesStore.create();
    expect(
      store.read().entries.map((entry) => entry.category),
      DeviceContentCategory.values,
    );
    expect(store.read().entries.every((entry) => entry.enabled), isTrue);
  });

  test('custom order and enabled state persist and reload', () async {
    final store = await SharedPreferencesDeviceContentPreferencesStore.create();
    var value = preferencesForPreset(DeviceContentPreset.fantasyFocus);
    value = value.withEnabled(DeviceContentCategory.nba, false);
    await store.save(value);
    final reloaded =
        await SharedPreferencesDeviceContentPreferencesStore.create();
    expect(
      reloaded.read().entries.first.category,
      DeviceContentCategory.fantasy,
    );
    expect(reloaded.read().isEnabled(DeviceContentCategory.nba), isFalse);
  });

  test('all disabled is valid', () {
    var value = DeviceContentPreferences.defaults();
    for (final category in DeviceContentCategory.values) {
      value = value.withEnabled(category, false);
    }
    expect(value.enabledCategories, isEmpty);
  });

  test(
    'unknown keys are ignored and missing categories merge at default tail',
    () async {
      SharedPreferences.setMockInitialValues({
        SharedPreferencesDeviceContentPreferencesStore.preferencesKey: [
          'mlb:1',
          'future_soccer:0',
          'nfl:0',
        ],
      });
      final store =
          await SharedPreferencesDeviceContentPreferencesStore.create();
      expect(store.read().entries.map((entry) => entry.category), [
        DeviceContentCategory.mlb,
        DeviceContentCategory.nfl,
        DeviceContentCategory.nba,
        DeviceContentCategory.pga,
        DeviceContentCategory.fantasy,
      ]);
      expect(store.read().isEnabled(DeviceContentCategory.nfl), isFalse);
      expect(store.read().isEnabled(DeviceContentCategory.nba), isTrue);
    },
  );

  test('presets are ordinary preferences and remain manually editable', () {
    final everything = preferencesForPreset(DeviceContentPreset.everything);
    final fantasy = preferencesForPreset(DeviceContentPreset.fantasyFocus);
    final sports = preferencesForPreset(DeviceContentPreset.sportsOnly);
    expect(everything.entries.every((entry) => entry.enabled), isTrue);
    expect(fantasy.entries.first.category, DeviceContentCategory.fantasy);
    expect(sports.isEnabled(DeviceContentCategory.fantasy), isFalse);
    final edited = fantasy
        .reordered(0, 3)
        .withEnabled(DeviceContentCategory.pga, false);
    expect(edited.entries[2].category, DeviceContentCategory.fantasy);
    expect(edited.isEnabled(DeviceContentCategory.pga), isFalse);
  });

  test('device category conversion keeps Fantasy outside SportsLeague', () {
    expect(DeviceContentCategory.nfl.sportsLeague, SportsLeague.nfl);
    expect(DeviceContentCategory.pga.sportsLeague, SportsLeague.pga);
    expect(DeviceContentCategory.fantasy.sportsLeague, isNull);
    expect(SportsLeague.values, isNot(contains(DeviceContentCategory.fantasy)));
  });
}
