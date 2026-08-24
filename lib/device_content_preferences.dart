import 'sports_league.dart';

enum DeviceContentCategory {
  nfl('NFL'),
  ncaaf('NCAAF'),
  nba('NBA'),
  mlb('MLB'),
  pga('PGA Golf'),
  fantasy('Fantasy');

  const DeviceContentCategory(this.displayName);
  final String displayName;

  SportsLeague? get sportsLeague => switch (this) {
    nfl => SportsLeague.nfl,
    ncaaf => SportsLeague.ncaaf,
    nba => SportsLeague.nba,
    mlb => SportsLeague.mlb,
    pga => SportsLeague.pga,
    fantasy => null,
  };
}

class DeviceContentPreference {
  const DeviceContentPreference({
    required this.category,
    required this.enabled,
  });
  final DeviceContentCategory category;
  final bool enabled;

  DeviceContentPreference copyWith({bool? enabled}) => DeviceContentPreference(
    category: category,
    enabled: enabled ?? this.enabled,
  );
}

class DeviceContentPreferences {
  DeviceContentPreferences(Iterable<DeviceContentPreference> entries)
    : entries = List.unmodifiable(entries) {
    if (this.entries.length != DeviceContentCategory.values.length ||
        this.entries.map((entry) => entry.category).toSet().length !=
            DeviceContentCategory.values.length) {
      throw ArgumentError('Every device content category must appear once.');
    }
  }

  factory DeviceContentPreferences.defaults() => DeviceContentPreferences([
    for (final category in DeviceContentCategory.values)
      DeviceContentPreference(category: category, enabled: true),
  ]);

  final List<DeviceContentPreference> entries;
  bool isEnabled(DeviceContentCategory category) =>
      entries.firstWhere((entry) => entry.category == category).enabled;
  Iterable<DeviceContentCategory> get enabledCategories =>
      entries.where((entry) => entry.enabled).map((entry) => entry.category);

  DeviceContentPreferences reordered(int oldIndex, int newIndex) {
    final values = List<DeviceContentPreference>.of(entries);
    if (newIndex > oldIndex) newIndex--;
    final entry = values.removeAt(oldIndex);
    values.insert(newIndex, entry);
    return DeviceContentPreferences(values);
  }

  DeviceContentPreferences withEnabled(
    DeviceContentCategory category,
    bool enabled,
  ) => DeviceContentPreferences([
    for (final entry in entries)
      entry.category == category ? entry.copyWith(enabled: enabled) : entry,
  ]);
}

enum DeviceContentPreset { everything, fantasyFocus, sportsOnly }

DeviceContentPreferences preferencesForPreset(DeviceContentPreset preset) {
  final order = switch (preset) {
    DeviceContentPreset.everything => DeviceContentCategory.values,
    DeviceContentPreset.fantasyFocus => const [
      DeviceContentCategory.fantasy,
      DeviceContentCategory.nfl,
      DeviceContentCategory.ncaaf,
      DeviceContentCategory.nba,
      DeviceContentCategory.mlb,
      DeviceContentCategory.pga,
    ],
    DeviceContentPreset.sportsOnly => const [
      DeviceContentCategory.nfl,
      DeviceContentCategory.ncaaf,
      DeviceContentCategory.nba,
      DeviceContentCategory.mlb,
      DeviceContentCategory.pga,
      DeviceContentCategory.fantasy,
    ],
  };
  return DeviceContentPreferences([
    for (final category in order)
      DeviceContentPreference(
        category: category,
        enabled:
            preset != DeviceContentPreset.sportsOnly ||
            category != DeviceContentCategory.fantasy,
      ),
  ]);
}
