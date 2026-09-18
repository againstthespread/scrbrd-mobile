import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/fantasy_league_config.dart';
import 'package:sports_hub_mobile/fantasy_matchup_slate_builder.dart';
import 'package:sports_hub_mobile/fantasy_primary_league_store.dart';
import 'package:sports_hub_mobile/fantasy_provider_models.dart';

void main() {
  late _Store store;
  late MemoryFantasyPrimaryLeagueStore primary;
  late Set<String> failures;
  late FantasyMatchupSlateBuilder builder;
  setUp(() {
    store = _Store();
    primary = MemoryFantasyPrimaryLeagueStore();
    failures = {};
    builder = FantasyMatchupSlateBuilder(
      configStore: store,
      primaryStore: primary,
      loadSleeper: (c) async => throw StateError('unused ${c.id}'),
      loadEspn: (c) async {
        if (failures.contains(c.id)) throw StateError('failed');
        return _matchup(c);
      },
    );
  });
  Future<void> add(
    String id, {
    String name = 'League',
    bool selected = true,
  }) async => store.upsert(
    FantasyLeagueConfig(
      provider: FantasyProvider.espn,
      leagueId: id,
      teamId: selected ? '1' : null,
      displayName: name,
    ),
  );
  test('one valid league preserves provider identity', () async {
    await add('a');
    final slate = await builder.build();
    expect(slate.single.identity, 'espn:a');
  });
  test('primary is first and remaining names sort', () async {
    await add('a', name: 'Zulu');
    await add('b', name: 'Alpha');
    await add('c', name: 'Beta');
    await primary.save('espn:a');
    expect((await builder.build()).map((e) => e.identity), [
      'espn:a',
      'espn:b',
      'espn:c',
    ]);
  });
  test(
    'failed primary is omitted and selected-team requirement applies',
    () async {
      await add('a');
      await add('b');
      await add('c', selected: false);
      await primary.save('espn:a');
      failures.add('espn:a');
      expect((await builder.build()).map((e) => e.identity), ['espn:b']);
    },
  );
  test('caps output at eight while retaining primary', () async {
    for (var i = 0; i < 10; i++) {
      await add('$i', name: 'L$i');
    }
    await primary.save('espn:9');
    final slate = await builder.build();
    expect(slate, hasLength(8));
    expect(slate.first.identity, 'espn:9');
  });
  test('empty configurations return empty without changing primary', () async {
    await primary.save('espn:a');
    expect(await builder.build(), isEmpty);
    expect(await primary.resolve(['espn:a']), 'espn:a');
  });
}

class _Store implements FantasyLeagueConfigStore {
  final List<FantasyLeagueConfig> values = [];
  @override
  Future<void> clear() async => values.clear();
  @override
  Future<void> remove(FantasyProvider p, String id) async =>
      values.removeWhere((c) => c.provider == p && c.leagueId == id);
  @override
  Future<List<FantasyLeagueConfig>> readAll() async => List.of(values);
  @override
  Future<void> upsert(FantasyLeagueConfig c) async {
    values.removeWhere((v) => v.id == c.id);
    values.add(c);
  }
}

FantasyMatchupSnapshot _matchup(FantasyLeagueConfig c) =>
    FantasyMatchupSnapshot(
      league: FantasyLeagueDetails(
        provider: FantasyProvider.espn,
        leagueId: c.leagueId,
        season: 2026,
        name: c.displayName ?? c.leagueId,
        scoringPeriod: 1,
        matchupPeriod: 1,
        teams: const [],
      ),
      team: const FantasyScoringTeam(
        team: FantasyTeamDetails(id: '1', name: 'Me'),
        totalPoints: 1,
        starters: [],
      ),
      opponent: const FantasyScoringTeam(
        team: FantasyTeamDetails(id: '2', name: 'Them'),
        totalPoints: 0,
        starters: [],
      ),
    );
