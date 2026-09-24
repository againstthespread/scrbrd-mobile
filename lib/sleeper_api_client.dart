import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sleeper_models.dart';
import 'sleeper_discovery.dart';

class SleeperApiException implements Exception {
  const SleeperApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SleeperApiClient {
  SleeperApiClient({http.Client? client, Uri? baseUri, Uri? projectionBaseUri})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _baseUri = baseUri ?? Uri.https('api.sleeper.app', '/v1'),
      _projectionBaseUri =
          projectionBaseUri ?? Uri.https('api.sleeper.com', '');

  static const _timeout = Duration(seconds: 12);
  final http.Client _client;
  final bool _ownsClient;
  final Uri _baseUri;
  final Uri _projectionBaseUri;

  Future<SleeperLeague> fetchLeague(String leagueId) async =>
      SleeperLeague.fromJson(await _getMap('/league/$leagueId'));

  Future<SleeperAccount?> fetchUser(String username) async {
    final normalized = username.trim();
    if (normalized.isEmpty) {
      throw const SleeperApiException('Enter a Sleeper username.');
    }
    try {
      return SleeperAccount.fromJson(await _getMap('/user/$normalized'));
    } on SleeperApiException catch (error) {
      if (error.message.contains('HTTP 404')) return null;
      rethrow;
    }
  }

  Future<List<SleeperLeague>> fetchUserNflLeagues(
    String userId,
    int season,
  ) async => (await _getList('/user/$userId/leagues/nfl/$season'))
      .map(SleeperLeague.fromJson)
      .where((league) => league.sport == null || league.sport == 'nfl')
      .toList(growable: false);

  Future<List<SleeperUser>> fetchLeagueUsers(String leagueId) async =>
      (await _getList(
        '/league/$leagueId/users',
      )).map(SleeperUser.fromJson).toList(growable: false);

  Future<List<SleeperRoster>> fetchLeagueRosters(String leagueId) async =>
      (await _getList(
        '/league/$leagueId/rosters',
      )).map(SleeperRoster.fromJson).toList(growable: false);

  Future<SleeperNflState> fetchNflState() async =>
      SleeperNflState.fromJson(await _getMap('/state/nfl'));

  Future<List<SleeperMatchup>> fetchMatchups(String leagueId, int week) async =>
      (await _getList(
        '/league/$leagueId/matchups/$week',
      )).map(SleeperMatchup.fromJson).toList(growable: false);

  Future<Map<String, SleeperFantasyPlayer>> fetchNflPlayers() async {
    final json = await _getMap('/players/nfl');
    final players = <String, SleeperFantasyPlayer>{};
    for (final entry in json.entries) {
      if (entry.value is! Map<String, dynamic>) continue;
      try {
        final player = SleeperFantasyPlayer.fromJson(
          entry.value as Map<String, dynamic>,
          sleeperPlayerId: entry.key,
        );
        players[player.sleeperPlayerId] = player;
      } on FormatException {
        // One malformed record must not make the full player index unusable.
      }
    }
    return players;
  }

  Future<SleeperPlayerProjection?> fetchNflPlayerProjection({
    required String playerId,
    required String season,
    required int week,
    required String seasonType,
  }) async {
    final normalizedId = playerId.trim();
    if (normalizedId.isEmpty ||
        season.trim().isEmpty ||
        week < 1 ||
        week > 30) {
      throw const SleeperApiException('Invalid Sleeper projection request.');
    }
    final uri = _projectionBaseUri.replace(
      path: '${_projectionBaseUri.path}/projections/nfl/player/$normalizedId',
      queryParameters: {
        'season': season.trim(),
        'season_type': seasonType.trim().toLowerCase(),
        'week': week.toString(),
      },
    );
    final decoded = await _getJsonUri(uri);
    if (decoded is! Map<String, dynamic>) {
      throw const SleeperApiException(
        'Sleeper returned an unexpected projection.',
      );
    }
    if (decoded.isEmpty) return null;
    return SleeperPlayerProjection.fromJson(decoded);
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<Map<String, dynamic>> _getMap(String path) async {
    final decoded = await _getJson(path);
    if (decoded is! Map<String, dynamic>) {
      throw const SleeperApiException('Sleeper returned an unexpected object.');
    }
    return decoded;
  }

  Future<List<Map<String, dynamic>>> _getList(String path) async {
    final decoded = await _getJson(path);
    if (decoded is! List) {
      throw const SleeperApiException('Sleeper returned an unexpected list.');
    }
    return decoded
        .map((item) {
          if (item is! Map<String, dynamic>) {
            throw const SleeperApiException(
              'Sleeper returned a malformed list item.',
            );
          }
          return item;
        })
        .toList(growable: false);
  }

  Future<Object?> _getJson(String path) async {
    final uri = _baseUri.replace(path: '${_baseUri.path}$path');
    return _getJsonUri(uri);
  }

  Future<Object?> _getJsonUri(Uri uri) async {
    try {
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode != 200) {
        throw SleeperApiException(
          'Sleeper returned HTTP ${response.statusCode}.',
        );
      }
      return jsonDecode(response.body);
    } on TimeoutException {
      throw const SleeperApiException('Sleeper request timed out.');
    } on FormatException {
      throw const SleeperApiException('Sleeper returned malformed JSON.');
    } on SleeperApiException {
      rethrow;
    } on Object catch (error) {
      throw SleeperApiException('Unable to reach Sleeper: $error');
    }
  }
}
