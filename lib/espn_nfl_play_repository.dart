import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'espn_fantasy_play_parser.dart';
import 'fantasy_nfl_play.dart';
import 'fantasy_nfl_play_tracker.dart';

class EspnNflPlayException implements Exception {
  const EspnNflPlayException(this.message);
  final String message;
  @override
  String toString() => message;
}

class EspnNflPlayRepository {
  EspnNflPlayRepository({
    http.Client? client,
    FantasyNflPlayTracker? tracker,
    int Function()? epochMilliseconds,
    Uri? baseUri,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _tracker = tracker ?? FantasyNflPlayTracker(),
       _epochMilliseconds =
           epochMilliseconds ?? (() => DateTime.now().millisecondsSinceEpoch),
       _baseUri = baseUri ?? Uri.https('site.api.espn.com');

  static const _timeout = Duration(seconds: 12);
  final http.Client _client;
  final bool _ownsClient;
  final FantasyNflPlayTracker _tracker;
  final int Function() _epochMilliseconds;
  final Uri _baseUri;
  final Set<String> _finalizedGames = {};
  int _lastCacheBuster = -1;

  Future<List<FantasyNflPlay>> refresh(DateTime date) async {
    final scoreboard = await _getJson(
      '/apis/site/v2/sports/football/nfl/scoreboard',
      {'dates': _compactDate(date), '_scrbrd_ts': _nextCacheBuster()},
    );
    final games = parseEspnFantasyNflGames(scoreboard);
    final results = await Future.wait(
      games.map((game) async {
        if (_finalizedGames.contains(game.gameId)) {
          return const <FantasyNflPlay>[];
        }
        if (game.isComplete && !_tracker.hasObservedGame(game.gameId)) {
          _finalizedGames.add(game.gameId);
          return const <FantasyNflPlay>[];
        }
        try {
          final summary = await _getJson(
            '/apis/site/v2/sports/football/nfl/summary',
            {'event': game.gameId, '_scrbrd_ts': _nextCacheBuster()},
          );
          final plays = parseEspnFantasyNflPlays(game.gameId, summary);
          final fresh = _tracker.observe(game.gameId, plays);
          if (game.isComplete) _finalizedGames.add(game.gameId);
          return fresh;
        } on Object {
          return const <FantasyNflPlay>[];
        }
      }),
    );
    return List.unmodifiable(results.expand((plays) => plays));
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<Map<String, dynamic>> _getJson(
    String path,
    Map<String, Object> query,
  ) async {
    final uri = _baseUri.replace(path: path, queryParameters: query);
    try {
      final response = await _client
          .get(
            uri,
            headers: const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
          )
          .timeout(_timeout);
      if (response.statusCode != 200) {
        throw EspnNflPlayException(
          'ESPN returned HTTP ${response.statusCode}.',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const EspnNflPlayException(
          'ESPN returned an unexpected payload.',
        );
      }
      return decoded;
    } on TimeoutException {
      throw const EspnNflPlayException('ESPN play request timed out.');
    } on FormatException {
      throw const EspnNflPlayException('ESPN returned malformed JSON.');
    } on EspnNflPlayException {
      rethrow;
    } on Object catch (error) {
      throw EspnNflPlayException('Unable to reach ESPN plays: $error');
    }
  }

  String _nextCacheBuster() {
    final now = _epochMilliseconds();
    final next = now > _lastCacheBuster ? now : _lastCacheBuster + 1;
    _lastCacheBuster = next;
    return next.toString();
  }
}

String _compactDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}'
    '${date.month.toString().padLeft(2, '0')}'
    '${date.day.toString().padLeft(2, '0')}';
