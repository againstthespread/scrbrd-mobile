import 'fantasy_league_config.dart';
import 'sleeper_fantasy_config.dart';

SleeperFantasyConfig sleeperConfig(FantasyLeagueConfig config) =>
    SleeperFantasyConfig(
      leagueId: config.leagueId,
      rosterId: int.tryParse(config.teamId ?? ''),
      alertsEnabled: config.alertsEnabled,
    );

FantasyLeagueConfig leagueConfig(SleeperFantasyConfig config) =>
    FantasyLeagueConfig(
      provider: FantasyProvider.sleeper,
      leagueId: config.leagueId,
      teamId: config.rosterId?.toString(),
      alertsEnabled: config.alertsEnabled,
    );

/// Compatibility view for legacy coordinator methods and tests.
/// Its edit selection is independent of the persisted device primary.
class SleeperFantasyConfigCollectionAdapter
    implements SleeperFantasyConfigStore {
  SleeperFantasyConfigCollectionAdapter(this.store);
  final FantasyLeagueConfigStore store;
  String? selectedLeagueId;

  @override
  Future<SleeperFantasyConfig?> read() async {
    final configs = (await store.readAll())
        .where((config) => config.provider == FantasyProvider.sleeper)
        .toList();
    if (configs.isEmpty) return null;
    final selected = configs.where(
      (config) => config.leagueId == selectedLeagueId,
    );
    return sleeperConfig(selected.isEmpty ? configs.first : selected.first);
  }

  @override
  Future<void> save(SleeperFantasyConfig config) async {
    final existing = (await store.readAll()).where(
      (item) =>
          item.provider == FantasyProvider.sleeper &&
          item.leagueId == config.leagueId,
    );
    await store.upsert(
      FantasyLeagueConfig(
        provider: FantasyProvider.sleeper,
        leagueId: config.leagueId,
        teamId: config.rosterId?.toString(),
        displayName: existing.isEmpty ? null : existing.first.displayName,
        teamDisplayName:
            existing.isEmpty ||
                existing.first.teamId != config.rosterId?.toString()
            ? null
            : existing.first.teamDisplayName,
        alertsEnabled: config.alertsEnabled,
      ),
    );
    selectedLeagueId = config.leagueId;
  }

  @override
  Future<void> clear() async {
    final config = await read();
    if (config != null) {
      await store.remove(FantasyProvider.sleeper, config.leagueId);
    }
    selectedLeagueId = null;
  }
}

/// Transitional constructor support for existing single-store tests/embedders.
/// Production uses the collection directly and never writes the legacy store.
class LegacySleeperConfigCollectionAdapter implements FantasyLeagueConfigStore {
  LegacySleeperConfigCollectionAdapter(this.store);
  final SleeperFantasyConfigStore store;

  @override
  Future<List<FantasyLeagueConfig>> readAll() async {
    final config = await store.read();
    return [if (config != null) leagueConfig(config)];
  }

  @override
  Future<void> upsert(FantasyLeagueConfig config) async {
    if (config.provider != FantasyProvider.sleeper) {
      throw ArgumentError('Legacy adapter supports Sleeper only');
    }
    await store.save(sleeperConfig(config));
  }

  @override
  Future<void> remove(FantasyProvider provider, String leagueId) async {
    final config = await store.read();
    if (provider == FantasyProvider.sleeper && config?.leagueId == leagueId) {
      await store.clear();
    }
  }

  @override
  Future<void> clear() => store.clear();
}
