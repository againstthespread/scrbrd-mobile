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

  Future<List<FantasyMatchupSlateEntry>> build() async {
    final configs = await configStore.readAll();
    final eligible = configs.where((config) => config.hasSelectedTeam).toList();
    final primary = await primaryStore.resolve(
      eligible.map((config) => config.id),
    );
    final entries = <FantasyMatchupSlateEntry>[];
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
      } on Object {
        // A provider failure omits only its league from this display slate.
      }
    }
    entries.sort((left, right) {
      final leftPrimary = left.identity == primary;
      final rightPrimary = right.identity == primary;
      if (leftPrimary != rightPrimary) return leftPrimary ? -1 : 1;
      final name = left.matchup.leagueName.compareTo(right.matchup.leagueName);
      return name != 0 ? name : left.identity.compareTo(right.identity);
    });
    return List.unmodifiable(entries.take(capacity));
  }
}
