import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports_hub_mobile/fantasy_league_config.dart';
import 'package:sports_hub_mobile/fantasy_primary_league_store.dart';

void main() {
  late SharedPreferencesFantasyPrimaryLeagueStore store;
  const key = SharedPreferencesFantasyPrimaryLeagueStore.storageKey;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = SharedPreferencesFantasyPrimaryLeagueStore();
  });

  test(
    'missing primary falls back lexically and persists replacement',
    () async {
      expect(
        await store.resolve(['sleeper:c', 'sleeper:b', 'sleeper:a']),
        'sleeper:a',
      );
      expect(
        (await SharedPreferences.getInstance()).getString(key),
        'sleeper:a',
      );
    },
  );

  test('explicit primary survives store recreation', () async {
    await store.save('sleeper:b');
    expect(
      await SharedPreferencesFantasyPrimaryLeagueStore().resolve([
        'sleeper:a',
        'sleeper:b',
      ]),
      'sleeper:b',
    );
  });

  test('provider-qualified IDs do not collide', () async {
    await store.save('espn:123');
    expect(await store.resolve(['sleeper:123', 'espn:123']), 'espn:123');
    await store.save('sleeper:123');
    expect(await store.resolve(['espn:123', 'sleeper:123']), 'sleeper:123');
  });

  test('removing primary chooses deterministic remaining ID', () async {
    await store.save('sleeper:b');
    expect(await store.resolve(['sleeper:c', 'sleeper:a']), 'sleeper:a');
    expect((await SharedPreferences.getInstance()).getString(key), 'sleeper:a');
  });

  test('removing final eligible league clears primary', () async {
    await store.save('sleeper:a');
    expect(await store.resolve([]), isNull);
    expect((await SharedPreferences.getInstance()).containsKey(key), isFalse);
  });

  for (final invalid in <Object>['sleeper:missing', 'a', '', 42]) {
    test('invalid saved primary $invalid falls back safely', () async {
      SharedPreferences.setMockInitialValues({key: invalid});
      expect(await store.resolve(['sleeper:b', 'sleeper:a']), 'sleeper:a');
    });
  }

  test('reordering or adding leagues does not steal valid primary', () async {
    await store.save('sleeper:b');
    expect(await store.resolve(['sleeper:a', 'sleeper:b']), 'sleeper:b');
    expect(
      await store.resolve(['sleeper:c', 'sleeper:b', 'sleeper:a']),
      'sleeper:b',
    );
    expect(await store.resolve(['sleeper:0', 'sleeper:b']), 'sleeper:b');
  });

  test(
    'old v1 record without teamDisplayName retains IDs and alert preference',
    () async {
      SharedPreferences.setMockInitialValues({
        SharedPreferencesFantasyLeagueConfigStore.storageKey: jsonEncode({
          'sleeper:a': {
            'provider': 'sleeper',
            'leagueId': 'a',
            'teamId': '1',
            'displayName': 'League A',
            'alertsEnabled': false,
          },
        }),
      });
      final configs = SharedPreferencesFantasyLeagueConfigStore();
      final old = (await configs.readAll()).single;
      expect(old.teamDisplayName, isNull);
      expect(old.teamId, '1');
      expect(old.alertsEnabled, isFalse);
      await configs.upsert(
        FantasyLeagueConfig(
          provider: old.provider,
          leagueId: old.leagueId,
          teamId: old.teamId,
          displayName: old.displayName,
          teamDisplayName: 'Home',
          alertsEnabled: old.alertsEnabled,
        ),
      );
      final reloaded =
          (await SharedPreferencesFantasyLeagueConfigStore().readAll()).single;
      expect(reloaded.teamDisplayName, 'Home');
      expect(reloaded.id, old.id);
      expect(reloaded.alertsEnabled, isFalse);
    },
  );
}
