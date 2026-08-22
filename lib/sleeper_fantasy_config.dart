import 'package:shared_preferences/shared_preferences.dart';

class SleeperFantasyConfig {
  const SleeperFantasyConfig({
    required this.leagueId,
    this.rosterId,
    this.alertsEnabled = true,
  });

  final String leagueId;
  final int? rosterId;
  final bool alertsEnabled;

  SleeperFantasyConfig copyWith({
    String? leagueId,
    int? rosterId,
    bool? alertsEnabled,
  }) => SleeperFantasyConfig(
    leagueId: leagueId ?? this.leagueId,
    rosterId: rosterId ?? this.rosterId,
    alertsEnabled: alertsEnabled ?? this.alertsEnabled,
  );
}

abstract interface class SleeperFantasyConfigStore {
  Future<SleeperFantasyConfig?> read();
  Future<void> save(SleeperFantasyConfig config);
  Future<void> clear();
}

class SharedPreferencesSleeperFantasyConfigStore
    implements SleeperFantasyConfigStore {
  static const _leagueKey = 'sleeper_fantasy_league_id';
  static const _rosterKey = 'sleeper_fantasy_roster_id';
  static const _alertsEnabledKey = 'sleeper_fantasy_alerts_enabled';
  static const _legacyLeagueKey = 'sleeper_league_id';

  @override
  Future<SleeperFantasyConfig?> read() async {
    final preferences = await SharedPreferences.getInstance();
    final leagueId =
        preferences.getString(_leagueKey) ??
        preferences.getString(_legacyLeagueKey);
    if (leagueId == null || leagueId.trim().isEmpty) return null;
    return SleeperFantasyConfig(
      leagueId: leagueId.trim(),
      rosterId: preferences.getInt(_rosterKey),
      alertsEnabled: preferences.getBool(_alertsEnabledKey) ?? true,
    );
  }

  @override
  Future<void> save(SleeperFantasyConfig config) async {
    final preferences = await SharedPreferences.getInstance();
    final existingLeague =
        preferences.getString(_leagueKey) ??
        preferences.getString(_legacyLeagueKey);
    final leagueId = config.leagueId.trim();
    final leagueChanged = existingLeague != null && existingLeague != leagueId;
    await preferences.setString(_leagueKey, leagueId);
    await preferences.setBool(_alertsEnabledKey, config.alertsEnabled);
    if (leagueChanged) {
      await preferences.remove(_rosterKey);
    } else if (config.rosterId case final rosterId?) {
      await preferences.setInt(_rosterKey, rosterId);
    } else {
      await preferences.remove(_rosterKey);
    }
  }

  @override
  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_leagueKey);
    await preferences.remove(_rosterKey);
    await preferences.remove(_alertsEnabledKey);
  }
}
