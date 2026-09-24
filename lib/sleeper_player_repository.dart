import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'sleeper_api_client.dart';
import 'sleeper_models.dart';

class CachedSleeperPlayers {
  const CachedSleeperPlayers({required this.fetchedAt, required this.players});

  final DateTime fetchedAt;
  final Map<String, SleeperFantasyPlayer> players;
}

abstract interface class SleeperPlayerCache {
  Future<CachedSleeperPlayers?> read();
  Future<void> write(CachedSleeperPlayers cache);
}

class FileSleeperPlayerCache implements SleeperPlayerCache {
  static const _fileName = 'sleeper_nfl_players.json';

  @override
  Future<CachedSleeperPlayers?> read() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final fetchedAt = DateTime.tryParse(
        decoded['fetchedAt']?.toString() ?? '',
      );
      final rawPlayers = decoded['players'];
      if (fetchedAt == null || rawPlayers is! Map<String, dynamic>) return null;
      final players = <String, SleeperFantasyPlayer>{};
      for (final entry in rawPlayers.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        try {
          final player = SleeperFantasyPlayer.fromJson(
            entry.value as Map<String, dynamic>,
            sleeperPlayerId: entry.key,
          );
          players[player.sleeperPlayerId] = player;
        } on FormatException {
          // Ignore isolated corrupt records while retaining the usable cache.
        }
      }
      return CachedSleeperPlayers(fetchedAt: fetchedAt, players: players);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(CachedSleeperPlayers cache) async {
    final file = await _cacheFile();
    await file.writeAsString(
      jsonEncode({
        'fetchedAt': cache.fetchedAt.toUtc().toIso8601String(),
        'players': {
          for (final entry in cache.players.entries)
            entry.key: entry.value.toJson(),
        },
      }),
      flush: true,
    );
  }

  Future<File> _cacheFile() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}/$_fileName');
  }
}

class SleeperPlayerRepository {
  SleeperPlayerRepository({
    required this.apiClient,
    SleeperPlayerCache? cache,
    DateTime Function()? now,
    this.cacheLifetime = const Duration(hours: 24),
    this.missingPlayerRetryInterval = const Duration(hours: 1),
    this.refreshFailureRetryInterval = const Duration(minutes: 5),
  }) : _cache = cache ?? FileSleeperPlayerCache(),
       _now = now ?? DateTime.now;

  final SleeperApiClient apiClient;
  final SleeperPlayerCache _cache;
  final DateTime Function() _now;
  final Duration cacheLifetime;
  final Duration missingPlayerRetryInterval;
  final Duration refreshFailureRetryInterval;
  Map<String, SleeperFantasyPlayer>? _memoryIndex;
  DateTime? _memoryFetchedAt;
  bool _cacheRead = false;
  Future<Map<String, SleeperFantasyPlayer>>? _cacheReadInProgress;
  Future<Map<String, SleeperFantasyPlayer>>? _loadInProgress;
  final Map<String, DateTime> _retryMissingAfter = {};
  DateTime? _refreshFailureRetryAfter;

  Future<Map<String, SleeperFantasyPlayer>> resolvePlayers(
    Iterable<String> playerIds,
  ) async {
    final requestedIds = playerIds.toSet();
    if (requestedIds.isEmpty) return const {};
    final index = await _loadIndex();
    final resolved = <String, SleeperFantasyPlayer>{};
    for (final playerId in requestedIds) {
      final player = index[playerId];
      if (player != null) resolved[playerId] = player;
    }
    return resolved;
  }

  Future<Map<String, SleeperFantasyPlayer>> resolvePlayersSafely(
    Iterable<String> playerIds,
  ) async {
    try {
      return await resolvePlayers(playerIds);
    } on Object {
      return const {};
    }
  }

  /// Resolves cached metadata first, refreshing the shared full index only
  /// when requested IDs are missing. Metadata failures remain non-fatal.
  Future<Map<String, SleeperFantasyPlayer>> resolvePlayersWithRefreshSafely(
    Iterable<String> playerIds,
  ) async {
    final requestedIds = playerIds.toSet();
    if (requestedIds.isEmpty) return const {};
    Map<String, SleeperFantasyPlayer> index;
    try {
      index = await _loadCachedIndex();
    } on Object {
      index = const {};
    }
    var resolved = _selectPlayers(index, requestedIds);
    final now = _now();
    final missing = requestedIds
        .where(
          (id) =>
              !resolved.containsKey(id) &&
              !(_retryMissingAfter[id]?.isAfter(now) ?? false),
        )
        .toSet();
    if (missing.isEmpty) return resolved;
    if (_refreshFailureRetryAfter?.isAfter(now) ?? false) return resolved;

    try {
      index = await _refreshIndex();
      _refreshFailureRetryAfter = null;
      resolved = {...resolved, ..._selectPlayers(index, requestedIds)};
      final retryAfter = _now().add(missingPlayerRetryInterval);
      for (final id in missing) {
        if (resolved.containsKey(id)) {
          _retryMissingAfter.remove(id);
        } else {
          _retryMissingAfter[id] = retryAfter;
        }
      }
    } on Object {
      _refreshFailureRetryAfter = _now().add(refreshFailureRetryInterval);
    }
    return resolved;
  }

  /// Resolves from memory/disk only and never downloads the full player index.
  Future<Map<String, SleeperFantasyPlayer>> resolveCachedPlayersSafely(
    Iterable<String> playerIds,
  ) async {
    try {
      return _selectPlayers(await _loadCachedIndex(), playerIds.toSet());
    } on Object {
      return const {};
    }
  }

  Future<Map<String, SleeperFantasyPlayer>> _loadIndex() async {
    Map<String, SleeperFantasyPlayer> cached;
    try {
      cached = await _loadCachedIndex();
    } on Object {
      cached = const {};
    }
    final fetchedAt = _memoryFetchedAt;
    if (fetchedAt != null && _now().difference(fetchedAt) < cacheLifetime) {
      return cached;
    }
    try {
      return await _refreshIndex();
    } on Object {
      if (_memoryFetchedAt != null) return cached;
      rethrow;
    }
  }

  Future<Map<String, SleeperFantasyPlayer>> _loadCachedIndex() {
    final memoryIndex = _memoryIndex;
    if (_cacheRead && memoryIndex != null) return Future.value(memoryIndex);
    return _cacheReadInProgress ??= _readCache().whenComplete(
      () => _cacheReadInProgress = null,
    );
  }

  Future<Map<String, SleeperFantasyPlayer>> _readCache() async {
    final cached = await _cache.read();
    _cacheRead = true;
    _memoryFetchedAt = cached?.fetchedAt;
    return _memoryIndex = cached?.players ?? const {};
  }

  Future<Map<String, SleeperFantasyPlayer>> _refreshIndex() {
    return _loadInProgress ??= _fetchAndCache().whenComplete(
      () => _loadInProgress = null,
    );
  }

  Future<Map<String, SleeperFantasyPlayer>> _fetchAndCache() async {
    final now = _now();
    final players = await apiClient.fetchNflPlayers();
    _cacheRead = true;
    _memoryIndex = players;
    _memoryFetchedAt = now;
    try {
      await _cache.write(
        CachedSleeperPlayers(fetchedAt: now, players: players),
      );
    } on Object {
      // A cache write failure must not discard successfully fetched metadata.
    }
    return players;
  }

  Map<String, SleeperFantasyPlayer> _selectPlayers(
    Map<String, SleeperFantasyPlayer> index,
    Set<String> playerIds,
  ) => {
    for (final id in playerIds)
      // ignore: use_null_aware_elements
      if (index[id] case final player?) id: player,
  };
}
