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
  }) : _cache = cache ?? FileSleeperPlayerCache(),
       _now = now ?? DateTime.now;

  final SleeperApiClient apiClient;
  final SleeperPlayerCache _cache;
  final DateTime Function() _now;
  final Duration cacheLifetime;
  Map<String, SleeperFantasyPlayer>? _memoryIndex;
  Future<Map<String, SleeperFantasyPlayer>>? _loadInProgress;

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

  /// Resolves from memory/disk only and never downloads the full player index.
  Future<Map<String, SleeperFantasyPlayer>> resolveCachedPlayersSafely(
    Iterable<String> playerIds,
  ) async {
    try {
      var index = _memoryIndex;
      if (index == null) {
        final cached = await _cache.read();
        index = cached?.players ?? const {};
        _memoryIndex = cached?.players;
      }
      return {
        for (final id in playerIds.toSet())
          // ignore: use_null_aware_elements
          if (index[id] case final player?) id: player,
      };
    } on Object {
      return const {};
    }
  }

  Future<Map<String, SleeperFantasyPlayer>> _loadIndex() {
    final memoryIndex = _memoryIndex;
    if (memoryIndex != null) return Future.value(memoryIndex);
    return _loadInProgress ??= _loadAndCache().whenComplete(
      () => _loadInProgress = null,
    );
  }

  Future<Map<String, SleeperFantasyPlayer>> _loadAndCache() async {
    final cached = await _cache.read();
    final now = _now();
    if (cached != null && now.difference(cached.fetchedAt) < cacheLifetime) {
      return _memoryIndex = cached.players;
    }
    try {
      final players = await apiClient.fetchNflPlayers();
      _memoryIndex = players;
      try {
        await _cache.write(
          CachedSleeperPlayers(fetchedAt: now, players: players),
        );
      } on Object {
        // A cache write failure must not discard successfully fetched metadata.
      }
      return players;
    } on Object {
      if (cached != null) return _memoryIndex = cached.players;
      rethrow;
    }
  }
}
