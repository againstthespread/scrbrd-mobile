import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum FantasyProvider { sleeper, espn }

class FantasyLeagueConfig {
  const FantasyLeagueConfig({
    required this.provider,
    required this.leagueId,
    this.teamId,
    this.displayName,
    this.teamDisplayName,
    this.alertsEnabled = true,
  });

  final FantasyProvider provider;
  final String leagueId;
  final String? teamId;
  final String? displayName;
  final String? teamDisplayName;
  final bool alertsEnabled;

  /// Provider-qualified identity; team selection does not change identity.
  String get id => '${provider.name}:$leagueId';

  /// Team identity is provider-specific, but primary selection is not.
  bool get hasSelectedTeam => teamId?.trim().isNotEmpty ?? false;

  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    'leagueId': leagueId,
    'teamId': teamId,
    'displayName': displayName,
    'teamDisplayName': teamDisplayName,
    'alertsEnabled': alertsEnabled,
  };

  factory FantasyLeagueConfig.fromJson(Map<String, dynamic> json) {
    final provider = json['provider'];
    final leagueId = json['leagueId'];
    final teamId = json['teamId'];
    final displayName = json['displayName'];
    final teamDisplayName = json['teamDisplayName'];
    final alertsEnabled = json['alertsEnabled'];
    if (!FantasyProvider.values.any((value) => value.name == provider) ||
        leagueId is! String ||
        leagueId.trim().isEmpty ||
        (teamId != null && teamId is! String) ||
        (displayName != null && displayName is! String) ||
        (teamDisplayName != null && teamDisplayName is! String) ||
        alertsEnabled is! bool) {
      throw const FormatException('Invalid fantasy league configuration');
    }
    return FantasyLeagueConfig(
      provider: FantasyProvider.values.byName(provider as String),
      leagueId: leagueId,
      teamId: teamId as String?,
      displayName: displayName as String?,
      teamDisplayName: teamDisplayName as String?,
      alertsEnabled: alertsEnabled,
    );
  }
}

abstract interface class FantasyLeagueConfigStore {
  Future<List<FantasyLeagueConfig>> readAll();
  Future<void> upsert(FantasyLeagueConfig config);
  Future<void> remove(FantasyProvider provider, String leagueId);
  Future<void> clear();
}

/// Authoritative collection; legacy single-Sleeper values are imported once.
class SharedPreferencesFantasyLeagueConfigStore
    implements FantasyLeagueConfigStore {
  static const storageKey = 'fantasy_league_configs_v1';

  // Serialize read/modify/write operations across instances in this isolate.
  static Future<void>? _pending;

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = (_pending ?? Future<void>.value()).then((_) => operation());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending = tail;
    return result.whenComplete(() {
      // Release idle futures, including their async zone, between callers.
      if (identical(_pending, tail)) _pending = null;
    });
  }

  @override
  Future<List<FantasyLeagueConfig>> readAll() => _serialized(() async {
    final preferences = await SharedPreferences.getInstance();
    return (await _read(preferences)).values.toList();
  });

  @override
  Future<void> upsert(FantasyLeagueConfig config) => _serialized(() async {
    // Apply the same validation to caller input and persisted records.
    FantasyLeagueConfig.fromJson(config.toJson());
    final preferences = await SharedPreferences.getInstance();
    final configs = await _read(preferences);
    configs[config.id] = config;
    await _write(preferences, configs);
  });

  @override
  Future<void> remove(FantasyProvider provider, String leagueId) =>
      _serialized(() async {
        final preferences = await SharedPreferences.getInstance();
        final configs = await _read(preferences);
        configs.remove('${provider.name}:$leagueId');
        await _write(preferences, configs);
      });

  @override
  Future<void> clear() => _serialized(() async {
    final preferences = await SharedPreferences.getInstance();
    // Persist an empty collection so retained legacy keys cannot resurrect it.
    await _write(preferences, {});
  });

  Future<Map<String, FantasyLeagueConfig>> _read(
    SharedPreferences preferences,
  ) async {
    if (!preferences.containsKey(storageKey)) {
      final configs = <String, FantasyLeagueConfig>{};
      final rawLeague =
          preferences.get('sleeper_fantasy_league_id') ??
          preferences.get('sleeper_league_id');
      if (rawLeague is String && rawLeague.trim().isNotEmpty) {
        final roster = preferences.get('sleeper_fantasy_roster_id');
        final alerts = preferences.get('sleeper_fantasy_alerts_enabled');
        final config = FantasyLeagueConfig(
          provider: FantasyProvider.sleeper,
          leagueId: rawLeague.trim(),
          teamId: roster is int ? roster.toString() : null,
          alertsEnabled: alerts is bool ? alerts : true,
        );
        configs[config.id] = config;
      }
      // Retain legacy values for upgrade compatibility; the collection wins.
      await _write(preferences, configs);
      return configs;
    }
    final configs = <String, FantasyLeagueConfig>{};
    final raw = preferences.get(storageKey);
    if (raw is! String) return configs;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return configs;
      for (final entry in decoded.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        try {
          final config = FantasyLeagueConfig.fromJson(
            entry.value as Map<String, dynamic>,
          );
          if (entry.key == config.id) configs[config.id] = config;
        } on FormatException {
          // Retain usable records when an isolated record is corrupt.
        }
      }
    } on FormatException {
      // An initialized but corrupt collection must not re-import legacy data.
    }
    return configs;
  }

  Future<void> _write(
    SharedPreferences preferences,
    Map<String, FantasyLeagueConfig> configs,
  ) async {
    final saved = await preferences.setString(
      storageKey,
      jsonEncode({
        for (final entry in configs.entries) entry.key: entry.value.toJson(),
      }),
    );
    if (!saved) {
      throw StateError('Could not persist fantasy league configurations');
    }
  }
}
