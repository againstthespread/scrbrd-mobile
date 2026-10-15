import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports_hub_mobile/device_content_preferences.dart';
import 'package:sports_hub_mobile/device_content_preferences_store.dart';
import 'package:sports_hub_mobile/device_content_screen.dart';
import 'package:sports_hub_mobile/favorites_screen.dart';
import 'package:sports_hub_mobile/college_football_screen.dart';
import 'package:sports_hub_mobile/college_football.dart';
import 'package:sports_hub_mobile/college_football_preferences_store.dart';
import 'package:sports_hub_mobile/favorites_store.dart';
import 'package:sports_hub_mobile/team_catalog.dart';

class Storage extends Fake implements SharedPreferences {
  final Map<String, Object> disk = {};
  final Map<String, Object> cache = {};
  bool fail = false;
  int failuresRemaining = 0;
  bool reloadFails = false;
  bool throws = false;
  Completer<void>? pending;
  @override
  Object? get(String key) => cache[key];
  @override
  List<String>? getStringList(String key) => cache[key] as List<String>?;
  @override
  Future<bool> setStringList(String key, List<String> value) async {
    cache[key] = List<String>.of(
      value,
    ); // Matches the plugin's optimistic cache.
    await pending?.future;
    if (throws) throw StateError('storage unavailable');
    if (fail || failuresRemaining-- > 0) return false;
    disk[key] = List<String>.of(value);
    return true;
  }

  @override
  Future<void> reload() async {
    if (reloadFails) throw StateError('storage still unavailable');
    cache
      ..clear()
      ..addAll(disk);
  }
}

void main() {
  for (final throwing in [false, true]) {
    test(
      'content retains committed value and retries after failure throws=$throwing',
      () async {
        final storage = Storage();
        final store =
            await SharedPreferencesDeviceContentPreferencesStore.create(
              preferences: storage,
            );
        final initial = store.read();
        final next = initial.withEnabled(DeviceContentCategory.nba, false);
        var notifications = 0;
        store.addListener(() => notifications++);
        storage.fail = !throwing;
        storage.throws = throwing;
        await expectLater(store.save(next), throwsA(anything));
        expect(store.read(), same(initial));
        expect(notifications, 0);
        expect(storage.cache, storage.disk);
        storage.fail = false;
        storage.throws = false;
        await store.save(next);
        expect(store.read(), same(next));
        expect(notifications, 1);
      },
    );
    test(
      'conferences retain committed value on failure throws=$throwing',
      () async {
        final storage = Storage();
        final store =
            await SharedPreferencesCollegeFootballPreferencesStore.create(
              preferences: storage,
            );
        final initial = store.read();
        storage.fail = !throwing;
        storage.throws = throwing;
        await expectLater(
          store.save(CollegeFootballPreferences([NcaafConference.sec])),
          throwsA(anything),
        );
        expect(store.read(), same(initial));
        expect(storage.cache, storage.disk);
      },
    );
    test(
      'favorites do not commit failed transitions throws=$throwing',
      () async {
        final storage = Storage();
        final store = await SharedPreferencesFavoritesStore.create(
          preferences: storage,
        );
        final team = TeamCatalog.teams.first;
        storage.fail = !throwing;
        storage.throws = throwing;
        await expectLater(store.setFavorite(team, true), throwsA(anything));
        expect(store.readFavorites(), isEmpty);
        expect(storage.cache, storage.disk);
        storage.fail = false;
        storage.throws = false;
        await store.setFavorite(team, true);
        storage.fail = true;
        await expectLater(store.setFavorite(team, false), throwsA(anything));
        expect(store.readFavorites(), {team});
      },
    );
  }
  test(
    'queued favorite additions preserve both and publish only after persistence',
    () async {
      final storage = Storage()..pending = Completer<void>();
      final store = await SharedPreferencesFavoritesStore.create(
        preferences: storage,
      );
      final teams = TeamCatalog.teams.take(2).toList();
      final first = store.setFavorite(teams[0], true);
      final second = store.setFavorite(teams[1], true);
      await Future<void>.delayed(Duration.zero);
      expect(store.readFavorites(), isEmpty);
      storage.pending!.complete();
      await Future.wait([first, second]);
      expect(store.readFavorites(), teams.toSet());
      expect(
        storage.disk[SharedPreferencesFavoritesStore.preferencesKey],
        teams.map((t) => t.storageKey).toList(),
      );
    },
  );
  testWidgets('content failed save retains switch and offers retry', (
    tester,
  ) async {
    final storage = Storage()..fail = true;
    final store = await SharedPreferencesDeviceContentPreferencesStore.create(
      preferences: storage,
    );
    await tester.pumpWidget(
      MaterialApp(home: DeviceContentScreen(store: store)),
    );
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
    expect(find.text('Retry'), findsOneWidget);
    storage.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
  });
  test('failed queued write does not poison the next write', () async {
    final storage = Storage()..failuresRemaining = 1;
    final store = await SharedPreferencesFavoritesStore.create(
      preferences: storage,
    );
    final teams = TeamCatalog.teams.take(2).toList();
    final failed = expectLater(
      store.setFavorite(teams[0], true),
      throwsA(anything),
    );
    final success = store.setFavorite(teams[1], true);
    await Future.wait([failed, success]);
    expect(store.readFavorites(), {teams[1]});
    expect(storage.disk[SharedPreferencesFavoritesStore.preferencesKey], [
      teams[1].storageKey,
    ]);
  });
  test(
    'failed reload still retains committed snapshot and permits retry',
    () async {
      final storage = Storage()
        ..fail = true
        ..reloadFails = true;
      final store = await SharedPreferencesDeviceContentPreferencesStore.create(
        preferences: storage,
      );
      final initial = store.read();
      final next = initial.withEnabled(DeviceContentCategory.mlb, false);
      await expectLater(store.save(next), throwsA(anything));
      expect(store.read(), same(initial));
      storage.fail = false;
      await store.save(next);
      expect(store.read(), same(next));
    },
  );
  test(
    'wrong-type legacy values safely default without rewriting storage',
    () async {
      final storage = Storage();
      storage.disk.addAll({
        SharedPreferencesDeviceContentPreferencesStore.preferencesKey: 42,
        SharedPreferencesCollegeFootballPreferencesStore.preferencesKey:
            'invalid',
        SharedPreferencesFavoritesStore.preferencesKey: false,
      });
      await storage.reload();
      final content =
          await SharedPreferencesDeviceContentPreferencesStore.create(
            preferences: storage,
          );
      final conferences =
          await SharedPreferencesCollegeFootballPreferencesStore.create(
            preferences: storage,
          );
      final favorites = await SharedPreferencesFavoritesStore.create(
        preferences: storage,
      );
      expect(
        content.read().enabledCategories.length,
        DeviceContentCategory.values.length,
      );
      expect(conferences.read().conferences, NcaafConference.values.toSet());
      expect(favorites.readFavorites(), isEmpty);
      expect(
        storage.disk[SharedPreferencesDeviceContentPreferencesStore
            .preferencesKey],
        42,
      );
    },
  );
  testWidgets(
    'content does not publish a pending save or accept duplicate toggles',
    (tester) async {
      final storage = Storage()..pending = Completer<void>();
      final store = await SharedPreferencesDeviceContentPreferencesStore.create(
        preferences: storage,
      );
      await tester.pumpWidget(
        MaterialApp(home: DeviceContentScreen(store: store)),
      );
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
      storage.pending!.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
    },
  );
  testWidgets('favorites failed save shows retry without changing star', (
    tester,
  ) async {
    final storage = Storage()..fail = true;
    final store = await SharedPreferencesFavoritesStore.create(
      preferences: storage,
    );
    await tester.pumpWidget(MaterialApp(home: FavoritesScreen(store: store)));
    await tester.tap(find.text(TeamCatalog.teams.first.displayName));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(store.readFavorites(), isEmpty);
    expect(find.text('Retry'), findsOneWidget);
    storage.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(store.readFavorites(), {TeamCatalog.teams.first});
  });
  testWidgets('conference failure keeps checkbox and retry applies intent', (
    tester,
  ) async {
    final storage = Storage()..fail = true;
    final store = await SharedPreferencesCollegeFootballPreferencesStore.create(
      preferences: storage,
    );
    await tester.pumpWidget(
      MaterialApp(home: CollegeFootballScreen(store: store)),
    );
    await tester.tap(find.text('ACC'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(store.read().contains(NcaafConference.acc), isTrue);
    expect(find.text('Retry'), findsOneWidget);
    storage.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(store.read().contains(NcaafConference.acc), isFalse);
  });
  test(
    'failed content reload cannot race a different store using the same cache',
    () async {
      final storage = Storage()
        ..failuresRemaining = 1
        ..pending = Completer<void>();
      final content =
          await SharedPreferencesDeviceContentPreferencesStore.create(
            preferences: storage,
          );
      final favorites = await SharedPreferencesFavoritesStore.create(
        preferences: storage,
      );
      final failure = expectLater(
        content.save(
          content.read().withEnabled(DeviceContentCategory.nba, false),
        ),
        throwsA(anything),
      );
      final success = favorites.setFavorite(TeamCatalog.teams.first, true);
      await Future<void>.delayed(Duration.zero);
      expect(
        storage.cache.containsKey(
          SharedPreferencesFavoritesStore.preferencesKey,
        ),
        isFalse,
      );
      storage.pending!.complete();
      await Future.wait([failure, success]);
      expect(storage.cache, storage.disk);
      expect(favorites.readFavorites(), {TeamCatalog.teams.first});
    },
  );
  test(
    'platform-decoded lists preserve existing preferences and ordering',
    () async {
      final storage = Storage();
      storage.disk.addAll({
        SharedPreferencesDeviceContentPreferencesStore.preferencesKey:
            <Object?>['fantasy:0', 'nba:1'],
        SharedPreferencesCollegeFootballPreferencesStore.preferencesKey:
            <Object?>['sec', 'unknown'],
        SharedPreferencesFavoritesStore.preferencesKey: <Object?>[
          TeamCatalog.teams.first.storageKey,
          'unknown',
        ],
      });
      await storage.reload();
      final content =
          await SharedPreferencesDeviceContentPreferencesStore.create(
            preferences: storage,
          );
      final conferences =
          await SharedPreferencesCollegeFootballPreferencesStore.create(
            preferences: storage,
          );
      final favorites = await SharedPreferencesFavoritesStore.create(
        preferences: storage,
      );
      expect(
        content.read().entries.first.category,
        DeviceContentCategory.fantasy,
      );
      expect(content.read().isEnabled(DeviceContentCategory.fantasy), isFalse);
      expect(conferences.read().conferences, {NcaafConference.sec});
      expect(favorites.readFavorites(), {TeamCatalog.teams.first});
    },
  );
}
