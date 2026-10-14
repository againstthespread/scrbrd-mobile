import 'fantasy_league_config.dart';
import 'fantasy_matchup_display_data.dart';
import 'fantasy_matchup_transport.dart';
import 'fantasy_primary_league_store.dart';
import 'fantasy_provider_models.dart';
import 'sleeper_models.dart';

typedef SleeperSlateLoader =
    Future<SleeperFantasyMatchup> Function(FantasyLeagueConfig config);
typedef EspnSlateLoader =
    Future<FantasyMatchupSnapshot> Function(FantasyLeagueConfig config);

class FantasySlateBuildOutcome {
  FantasySlateBuildOutcome({
    required List<FantasyMatchupSlateEntry> entries,
    required Map<String, Object> failures,
  }) : entries = List.unmodifiable(entries),
       failures = Map.unmodifiable(failures);

  final List<FantasyMatchupSlateEntry> entries;
  final Map<String, Object> failures;
}

class FantasyMatchupSlateBuilder {
  FantasyMatchupSlateBuilder({
    required this.configStore,
    required this.primaryStore,
    required this.loadSleeper,
    required this.loadEspn,
  });

  static const capacity = 8;
  final FantasyLeagueConfigStore configStore;
  final FantasyPrimaryLeagueStore primaryStore;
  final SleeperSlateLoader loadSleeper;
  final EspnSlateLoader loadEspn;

  Future<List<FantasyMatchupSlateEntry>> build() async =>
      (await buildOutcome()).entries;

  Future<FantasySlateBuildOutcome> buildOutcome() async {
    final configs = await configStore.readAll();
    final eligible = configs.where((config) => config.hasSelectedTeam).toList();
    final primary = await primaryStore.resolve(
      eligible.map((config) => config.id),
    );
    final entries = <FantasyMatchupSlateEntry>[];
    final failures = <String, Object>{};
    for (final config in eligible) {
      try {
        final display = switch (config.provider) {
          FantasyProvider.sleeper => FantasyMatchupDisplayData.fromSleeper(
            await loadSleeper(config),
          ),
          FantasyProvider.espn => FantasyMatchupDisplayData.fromNormalized(
            await loadEspn(config),
          ),
        };
        entries.add(
          FantasyMatchupSlateEntry(identity: config.id, matchup: display),
        );
      } on Object catch (error) {
        failures[config.id] = error;
      }
    }
    entries.sort((left, right) {
      final leftPrimary = left.identity == primary;
      final rightPrimary = right.identity == primary;
      if (leftPrimary != rightPrimary) return leftPrimary ? -1 : 1;
      final name = left.matchup.leagueName.compareTo(right.matchup.leagueName);
      return name != 0 ? name : left.identity.compareTo(right.identity);
    });
    return FantasySlateBuildOutcome(
      entries: entries.take(capacity).toList(),
      failures: failures,
    );
  }
}
