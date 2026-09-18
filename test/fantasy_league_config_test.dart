import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports_hub_mobile/fantasy_league_config.dart';

void main() {
  late SharedPreferencesFantasyLeagueConfigStore store;
  const first = FantasyLeagueConfig(
    provider: FantasyProvider.sleeper,
    leagueId: 'a',
    teamId: '1',
    displayName: 'Example league',
    alertsEnabled: false,
  );
  const second = FantasyLeagueConfig(
    provider: FantasyProvider.sleeper,
    leagueId: 'b',
    teamId: '2',
  );
  const espn = FantasyLeagueConfig(
    provider: FantasyProvider.espn,
    leagueId: 'a',
    teamId: 'team-a',
  );
  const key = SharedPreferencesFantasyLeagueConfigStore.storageKey;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = SharedPreferencesFantasyLeagueConfigStore();
  });

  test('empty store returns no configurations', () async {
    expect(await store.readAll(), isEmpty);
  });

  test('one league round trips all fields through a new store', () async {
    await store.upsert(first);
    final reloaded = SharedPreferencesFantasyLeagueConfigStore();
    expect((await reloaded.readAll()).single.toJson(), first.toJson());
  });

  test(
    'multiple leagues and providers coexist without ID collisions',
    () async {
      await store.upsert(first);
      await store.upsert(second);
      await store.upsert(espn);
      final configs = await store.readAll();
      expect(configs.map((c) => c.id).toSet(), {first.id, second.id, espn.id});
      expect(configs.map((c) => c.toJson()), [
        first.toJson(),
        second.toJson(),
        espn.toJson(),
      ]);
    },
  );

  test('upsert changes only the matching provider and league', () async {
    await store.upsert(first);
    await store.upsert(second);
    await store.upsert(espn);
    const updated = FantasyLeagueConfig(
      provider: FantasyProvider.sleeper,
      leagueId: 'a',
      teamId: '3',
      alertsEnabled: true,
    );
    await store.upsert(updated);
    expect((await store.readAll()).map((c) => c.toJson()), [
      updated.toJson(),
      second.toJson(),
      espn.toJson(),
    ]);
    await store.upsert(
      const FantasyLeagueConfig(
        provider: FantasyProvider.sleeper,
        leagueId: 'a',
      ),
    );
    expect((await store.readAll()).first.teamId, isNull);
  });

  test(
    'remove preserves other leagues including same ID in another provider',
    () async {
      for (final config in [first, second, espn]) {
        await store.upsert(config);
      }
      await store.remove(first.provider, first.leagueId);
      await store.remove(first.provider, 'missing');
      expect((await store.readAll()).map((c) => c.id), [second.id, espn.id]);
    },
  );

  test(
    'clear persists an empty collection without legacy resurrection',
    () async {
      SharedPreferences.setMockInitialValues({'sleeper_league_id': 'legacy'});
      await store.upsert(first);
      await store.clear();
      expect(
        await SharedPreferencesFantasyLeagueConfigStore().readAll(),
        isEmpty,
      );
      final preferences = await SharedPreferences.getInstance();
      expect(jsonDecode(preferences.getString(key)!), isEmpty);
      expect(preferences.getString('sleeper_league_id'), 'legacy');
    },
  );

  test(
    'single-Sleeper migration preserves fields and every legacy key',
    () async {
      final legacy = <String, Object>{
        'sleeper_fantasy_league_id': ' current ',
        'sleeper_fantasy_roster_id': 7,
        'sleeper_fantasy_alerts_enabled': false,
        'sleeper_league_id': 'older',
      };
      SharedPreferences.setMockInitialValues(legacy);
      final migrated = (await store.readAll()).single;
      expect(migrated.provider, FantasyProvider.sleeper);
      expect(migrated.leagueId, 'current');
      expect(migrated.teamId, '7');
      expect(migrated.alertsEnabled, isFalse);
      expect((await store.readAll()).single.toJson(), migrated.toJson());
      final preferences = await SharedPreferences.getInstance();
      for (final entry in legacy.entries) {
        expect(preferences.get(entry.key), entry.value);
      }
      await preferences.setString('sleeper_fantasy_league_id', 'changed');
      expect((await store.readAll()).single.leagueId, 'current');
    },
  );

  test(
    'older legacy ID migrates with default team and alert settings',
    () async {
      SharedPreferences.setMockInitialValues({'sleeper_league_id': 'older'});
      final migrated = (await store.readAll()).single;
      expect(migrated.leagueId, 'older');
      expect(migrated.provider, FantasyProvider.sleeper);
      expect(migrated.teamId, isNull);
      expect(migrated.alertsEnabled, isTrue);
      expect((await store.readAll()).length, 1);
    },
  );

  test('concurrent writes across instances preserve every league', () async {
    await Future.wait([
      store.upsert(first),
      SharedPreferencesFantasyLeagueConfigStore().upsert(second),
      store.upsert(espn),
    ]);
    expect((await store.readAll()).length, 3);
  });

  for (final invalid in <Object>['broken json', '[]', 'null', 42]) {
    test(
      'invalid collection $invalid fails safely without legacy import',
      () async {
        SharedPreferences.setMockInitialValues({
          key: invalid,
          'sleeper_league_id': 'legacy',
        });
        expect(await store.readAll(), isEmpty);
        expect((await SharedPreferences.getInstance()).get(key), invalid);
      },
    );
  }

  test('invalid records are skipped while valid records survive', () async {
    SharedPreferences.setMockInitialValues({
      key: jsonEncode({
        first.id: first.toJson(),
        'bad-provider': {...second.toJson(), 'provider': 'unknown'},
        'bad-team': {...second.toJson(), 'teamId': 2},
        'bad-alerts': {...second.toJson(), 'alertsEnabled': 'false'},
        'bad-league': {...second.toJson(), 'leagueId': ''},
        'bad-name': {...second.toJson(), 'displayName': 1},
        'mismatched-key': second.toJson(),
        'not-a-record': 42,
      }),
    });
    expect((await store.readAll()).single.toJson(), first.toJson());
  });

  test(
    'invalid input is rejected without changing saved configurations',
    () async {
      await store.upsert(first);
      await expectLater(
        store.upsert(
          const FantasyLeagueConfig(
            provider: FantasyProvider.sleeper,
            leagueId: ' ',
          ),
        ),
        throwsFormatException,
      );
      expect((await store.readAll()).single.toJson(), first.toJson());
    },
  );
}
