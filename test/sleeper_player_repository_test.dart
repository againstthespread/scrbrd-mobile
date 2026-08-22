import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sports_hub_mobile/sleeper_api_client.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';
import 'package:sports_hub_mobile/sleeper_player_repository.dart';

void main() {
  group('Sleeper fantasy player parsing', () {
    test('preserves identity, name, position, team, and ESPN ID', () {
      final player = SleeperFantasyPlayer.fromJson({
        'player_id': '7564',
        'full_name': "Ja'Marr Chase",
        'first_name': "Ja'Marr",
        'last_name': 'Chase',
        'position': 'WR',
        'team': 'CIN',
        'espn_id': 4362628,
      });

      expect(player.sleeperPlayerId, '7564');
      expect(player.fullName, "Ja'Marr Chase");
      expect(player.firstName, "Ja'Marr");
      expect(player.lastName, 'Chase');
      expect(player.position, 'WR');
      expect(player.nflTeam, 'CIN');
      expect(player.espnPlayerId, '4362628');
    });

    test('missing ESPN ID is valid and full name can be derived', () {
      final player = SleeperFantasyPlayer.fromJson({
        'player_id': '9756',
        'first_name': 'Example',
        'last_name': 'Player',
        'position': 'RB',
        'team': 'BUF',
        'espn_id': '',
      });

      expect(player.fullName, 'Example Player');
      expect(player.espnPlayerId, isNull);
    });

    test('map key supplies stable Sleeper ID when payload omits player_id', () {
      final player = SleeperFantasyPlayer.fromJson({
        'full_name': 'Cincinnati Bengals',
        'position': 'DEF',
        'team': 'CIN',
      }, sleeperPlayerId: 'CIN');

      expect(player.sleeperPlayerId, 'CIN');
      expect(player.fullName, 'Cincinnati Bengals');
    });
  });

  test(
    'already resolved players do not trigger duplicate network fetches',
    () async {
      var requests = 0;
      final repository = _repository(
        onRequest: () => requests++,
        cache: _MemoryPlayerCache(),
      );

      expect((await repository.resolvePlayers(['7564']))['7564'], isNotNull);
      expect((await repository.resolvePlayers(['7564']))['7564'], isNotNull);
      expect(requests, 1);
    },
  );

  test('multiple starter IDs resolve from one indexed request', () async {
    var requests = 0;
    final repository = _repository(
      onRequest: () => requests++,
      cache: _MemoryPlayerCache(),
    );

    final players = await repository.resolvePlayers(['7564', '9756', '7564']);

    expect(players.keys, containsAll(['7564', '9756']));
    expect(requests, 1);
  });

  test('fresh persistent cache avoids a network request', () async {
    var requests = 0;
    final now = DateTime.utc(2026, 8, 22, 12);
    final cache = _MemoryPlayerCache(
      value: CachedSleeperPlayers(
        fetchedAt: now.subtract(const Duration(hours: 2)),
        players: {'7564': _chase},
      ),
    );
    final repository = _repository(
      onRequest: () => requests++,
      cache: cache,
      now: () => now,
    );

    final players = await repository.resolvePlayers(['7564']);

    expect(players['7564']?.fullName, "Ja'Marr Chase");
    expect(requests, 0);
  });

  test('unresolved player is omitted for safe ID fallback', () async {
    final repository = _repository(cache: _MemoryPlayerCache());

    final players = await repository.resolvePlayers(['missing']);

    expect(players, isEmpty);
    expect(players['missing']?.fullName ?? 'missing', 'missing');
  });

  test('stale cache remains usable when metadata fetch fails', () async {
    final now = DateTime.utc(2026, 8, 22, 12);
    final apiClient = SleeperApiClient(
      client: MockClient((_) async => http.Response('unavailable', 503)),
    );
    final repository = SleeperPlayerRepository(
      apiClient: apiClient,
      cache: _MemoryPlayerCache(
        value: CachedSleeperPlayers(
          fetchedAt: now.subtract(const Duration(days: 2)),
          players: {'7564': _chase},
        ),
      ),
      now: () => now,
    );

    final players = await repository.resolvePlayers(['7564']);

    expect(players['7564']?.fullName, "Ja'Marr Chase");
  });

  test(
    'metadata failure safely returns empty without breaking refresh caller',
    () async {
      final apiClient = SleeperApiClient(
        client: MockClient((_) async => http.Response('unavailable', 503)),
      );
      final repository = SleeperPlayerRepository(
        apiClient: apiClient,
        cache: _MemoryPlayerCache(),
      );

      expect(await repository.resolvePlayersSafely(['7564']), isEmpty);
    },
  );

  test(
    'metadata implementation has no ESPN play, BLE, firmware, or timer coupling',
    () {
      final sources = [
        File('lib/sleeper_player_repository.dart').readAsStringSync(),
        File('lib/sleeper_api_client.dart').readAsStringSync(),
      ].join().toLowerCase();

      expect(sources, isNot(contains('summary')));
      expect(sources, isNot(contains('play-by-play')));
      expect(sources, isNot(contains('device_transport')));
      expect(sources, isNot(contains('bluetooth')));
      expect(sources, isNot(contains('firmware')));
      expect(sources, isNot(contains('timer.periodic')));
    },
  );
}

SleeperPlayerRepository _repository({
  void Function()? onRequest,
  required SleeperPlayerCache cache,
  DateTime Function()? now,
}) {
  final client = MockClient((request) async {
    onRequest?.call();
    expect(request.url.path, '/v1/players/nfl');
    return http.Response(
      jsonEncode({
        '7564': _chase.toJson(),
        '9756': {
          'player_id': '9756',
          'full_name': 'Example Player',
          'first_name': 'Example',
          'last_name': 'Player',
          'position': 'RB',
          'team': 'BUF',
        },
      }),
      200,
    );
  });
  return SleeperPlayerRepository(
    apiClient: SleeperApiClient(client: client),
    cache: cache,
    now: now,
  );
}

const _chase = SleeperFantasyPlayer(
  sleeperPlayerId: '7564',
  fullName: "Ja'Marr Chase",
  firstName: "Ja'Marr",
  lastName: 'Chase',
  position: 'WR',
  nflTeam: 'CIN',
  espnPlayerId: '4362628',
);

class _MemoryPlayerCache implements SleeperPlayerCache {
  _MemoryPlayerCache({this.value});

  CachedSleeperPlayers? value;

  @override
  Future<CachedSleeperPlayers?> read() async => value;

  @override
  Future<void> write(CachedSleeperPlayers cache) async => value = cache;
}
