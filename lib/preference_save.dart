import 'package:shared_preferences/shared_preferences.dart';

/// Recoverable persistence failure; callers retain the last committed value.
class PreferenceSaveException implements Exception {
  const PreferenceSaveException();
  @override
  String toString() => 'Could not save preferences. Please retry.';
}

/// Serialize writes and cache recovery so a failed write cannot undo a later one.
class PreferenceSaveQueue {
  // Different stores share the same legacy plugin cache. Serialize by cache
  // identity, including reloads, rather than only within one preference store.
  static final _pending = Expando<Future<void>>();

  Future<void> save(
    SharedPreferences preferences,
    Future<bool> Function() write,
    void Function() commit,
  ) {
    final previous = _pending[preferences] ?? Future<void>.value();
    final result = previous.then((_) async {
      try {
        if (!await write()) throw const PreferenceSaveException();
      } catch (_) {
        // Legacy SharedPreferences mutates its own cache before the platform
        // write. Reload it too; the store's committed snapshot stays untouched.
        try {
          await preferences.reload();
        } catch (_) {
          // Storage may still be unavailable. Keep the committed store value
          // and let the caller retry rather than reporting a successful save.
        }
        throw const PreferenceSaveException();
      }
      commit();
    });
    _pending[preferences] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

/// Platform channels can return `List<Object?>` even for valid string lists.
List<String>? readPreferenceStringList(
  SharedPreferences preferences,
  String key,
) {
  final value = preferences.get(key);
  return value is List && value.every((entry) => entry is String)
      ? value.cast<String>().toList()
      : null;
}
