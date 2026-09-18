import 'package:shared_preferences/shared_preferences.dart';

/// Primary is a display preference, independent of per-league alert settings.
/// Callers supply eligible provider-qualified identities; fallback is lexical.
abstract interface class FantasyPrimaryLeagueStore {
  Future<String?> resolve(Iterable<String> eligibleIds);
  Future<void> save(String? id);
}

class SharedPreferencesFantasyPrimaryLeagueStore
    implements FantasyPrimaryLeagueStore {
  static const storageKey = 'fantasy_primary_league_id_v1';
  static Future<void>? _pending;

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = (_pending ?? Future<void>.value()).then((_) => operation());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending = tail;
    return result.whenComplete(() {
      if (identical(_pending, tail)) _pending = null;
    });
  }

  @override
  Future<String?> resolve(Iterable<String> eligibleIds) =>
      _serialized(() async {
        final preferences = await SharedPreferences.getInstance();
        final ids = eligibleIds.toSet().toList()..sort();
        final saved = preferences.get(storageKey);
        if (saved is String && ids.contains(saved)) return saved;
        final replacement = ids.isEmpty ? null : ids.first;
        await _write(preferences, replacement);
        return replacement;
      });

  @override
  Future<void> save(String? id) => _serialized(() async {
    await _write(await SharedPreferences.getInstance(), id);
  });

  Future<void> _write(SharedPreferences preferences, String? id) async {
    final saved = id == null
        ? await preferences.remove(storageKey)
        : await preferences.setString(storageKey, id);
    if (!saved) throw StateError('Could not save primary fantasy league');
  }
}

/// Used only by the legacy single-store constructor/test compatibility path.
class MemoryFantasyPrimaryLeagueStore implements FantasyPrimaryLeagueStore {
  String? _id;

  @override
  Future<String?> resolve(Iterable<String> eligibleIds) async {
    final ids = eligibleIds.toSet().toList()..sort();
    if (!ids.contains(_id)) _id = ids.isEmpty ? null : ids.first;
    return _id;
  }

  @override
  Future<void> save(String? id) async => _id = id;
}
