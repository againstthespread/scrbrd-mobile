import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'golf_data_source.dart';
import 'golf_leaderboard.dart';
import 'sports_data_io_golf.dart';
import 'sports_data_io_game.dart';
import 'sports_data_source.dart';
import 'sports_game.dart';
import 'sports_league.dart';

class MissingSportsDataIOApiKeyException implements Exception {
  const MissingSportsDataIOApiKeyException();

  @override
  String toString() {
    return 'Missing SPORTSDATAIO_API_KEY. Pass it with --dart-define.';
  }
}

class SportsDataException implements Exception {
  const SportsDataException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SportsDataIODataSource implements SportsDataSource, GolfDataSource {
  SportsDataIODataSource({http.Client? client})
    : _client = client ?? http.Client();

  static const _apiKey = String.fromEnvironment('SPORTSDATAIO_API_KEY');
  static const _apiHost = 'api.sportsdata.io';
  static const _apiProduct = 'standard SportsDataIO API';
  static const _apiKeyHeader = 'Ocp-Apim-Subscription-Key';
  static const _timeout = Duration(seconds: 10);

  final http.Client _client;

  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  ) async {
    _logConfiguration();
    debugPrint('SportsDataIO selected league: ${league.label}');

    if (_apiKey.trim().isEmpty) {
      throw const MissingSportsDataIOApiKeyException();
    }

    final uri = Uri.https(_apiHost, _endpointPath(league, selectedDate));
    debugPrint('SportsDataIO request URL: $uri');

    late http.Response response;
    try {
      response = await _client
          .get(uri, headers: {_apiKeyHeader: _apiKey})
          .timeout(_timeout);
    } on TimeoutException {
      throw const SportsDataException('SportsDataIO request timed out.');
    } on http.ClientException catch (error) {
      throw SportsDataException('Network error: ${error.message}');
    } on Object {
      throw const SportsDataException('Unable to reach SportsDataIO.');
    }

    debugPrint('SportsDataIO HTTP status: ${response.statusCode}');

    if (response.statusCode != 200) {
      throw SportsDataException(
        'SportsDataIO returned HTTP ${response.statusCode}.',
      );
    }

    final Object decodedJson;
    try {
      decodedJson = jsonDecode(response.body);
    } on FormatException {
      throw const SportsDataException('SportsDataIO returned malformed JSON.');
    }

    if (decodedJson is! List) {
      throw const SportsDataException(
        'SportsDataIO returned an unexpected response.',
      );
    }

    debugPrint('SportsDataIO raw game count: ${decodedJson.length}');

    final games = <SportsGame>[];
    for (final item in decodedJson) {
      if (item is! Map<String, dynamic>) {
        continue;
      }

      try {
        games.add(SportsDataIOGame.fromJson(league, item).toSportsGame(league));
      } on FormatException {
        continue;
      }
    }

    final filteredGames = games.where((game) {
      final scheduledStartTime = game.scheduledStartTime;
      if (scheduledStartTime == null) {
        return true;
      }

      return _isSameLocalDate(scheduledStartTime, selectedDate);
    }).toList();

    filteredGames.sort(_compareByScheduledStartTime);
    debugPrint(
      'SportsDataIO mapped/filtered game count: ${filteredGames.length}',
    );

    return filteredGames;
  }

  @override
  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(
    DateTime selectedDate,
  ) async {
    debugPrint('SportsDataIO golf selected date: ${_datePath(selectedDate)}');
    final schedule = await _getJsonList(
      '/golf/v2/json/Tournaments/${selectedDate.year}',
    );
    final tournaments = <SportsDataIOGolfTournament>[];
    for (final value in schedule) {
      if (value is! Map<String, dynamic>) continue;
      try {
        final tournament = SportsDataIOGolfTournament.fromJson(value);
        tournaments.add(tournament);
      } on FormatException {
        continue;
      }
    }
    final dateOnly = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
    );
    final dateCandidates = tournaments.where((tournament) {
      final start = DateTime(
        tournament.startDate.year,
        tournament.startDate.month,
        tournament.startDate.day,
      );
      final end = DateTime(
        tournament.endDate.year,
        tournament.endDate.month,
        tournament.endDate.day,
      );
      return !dateOnly.isBefore(start) && !dateOnly.isAfter(end);
    }).toList();
    for (final tournament in dateCandidates) {
      debugPrint(
        'SportsDataIO golf candidate: ${tournament.name}; '
        'TournamentID=${tournament.tournamentId}; Covered=${tournament.covered}; '
        'IsInProgress=${tournament.isInProgress}; IsOver=${tournament.isOver}',
      );
    }
    final selected = selectGolfTournamentForDate(tournaments, selectedDate);
    debugPrint('SportsDataIO golf candidates found: ${dateCandidates.length}');
    if (selected == null) {
      debugPrint('SportsDataIO golf selected tournament: none');
      return null;
    }
    debugPrint(
      'SportsDataIO golf selected tournament: ${selected.name}; '
      'TournamentID=${selected.tournamentId}',
    );
    return fetchGolfLeaderboardByTournamentId(selected.tournamentId);
  }

  @override
  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(
    String tournamentId,
  ) async {
    final decoded = await _getJsonObject(
      '/golf/v2/json/Leaderboard/$tournamentId',
    );
    return parseSportsDataIOGolfLeaderboard(decoded);
  }

  Future<List<dynamic>> _getJsonList(String path) async {
    final decoded = await _getJson(path);
    if (decoded is! List) {
      throw const SportsDataException(
        'SportsDataIO returned an unexpected response.',
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _getJsonObject(String path) async {
    final decoded = await _getJson(path);
    if (decoded is! Map<String, dynamic>) {
      throw const SportsDataException(
        'SportsDataIO returned an unexpected response.',
      );
    }
    return decoded;
  }

  Future<Object?> _getJson(String path) async {
    _logConfiguration();
    if (_apiKey.trim().isEmpty) {
      throw const MissingSportsDataIOApiKeyException();
    }
    final uri = Uri.https(_apiHost, path);
    debugPrint('SportsDataIO request URL: $uri');
    try {
      final response = await _client
          .get(uri, headers: {_apiKeyHeader: _apiKey})
          .timeout(_timeout);
      debugPrint('SportsDataIO HTTP status: ${response.statusCode}');
      if (response.statusCode != 200) {
        throw SportsDataException(
          'SportsDataIO returned HTTP ${response.statusCode}.',
        );
      }
      return jsonDecode(response.body);
    } on TimeoutException {
      throw const SportsDataException('SportsDataIO request timed out.');
    } on FormatException {
      throw const SportsDataException('SportsDataIO returned malformed JSON.');
    } on SportsDataException {
      rethrow;
    } on Object catch (error) {
      throw SportsDataException('Unable to reach SportsDataIO: $error');
    }
  }

  int _compareByScheduledStartTime(SportsGame a, SportsGame b) {
    final aStart = a.scheduledStartTime;
    final bStart = b.scheduledStartTime;

    if (aStart == null && bStart == null) {
      return 0;
    }

    if (aStart == null) {
      return 1;
    }

    if (bStart == null) {
      return -1;
    }

    return aStart.compareTo(bStart);
  }

  bool _isSameLocalDate(DateTime value, DateTime selectedDate) {
    return value.year == selectedDate.year &&
        value.month == selectedDate.month &&
        value.day == selectedDate.day;
  }

  void _logConfiguration() {
    final trimmedKey = _apiKey.trim();
    debugPrint('SportsDataIO API product: $_apiProduct');
    debugPrint('SportsDataIO API host: $_apiHost');
    debugPrint('SportsDataIO API key present: ${trimmedKey.isNotEmpty}');
    debugPrint('SportsDataIO API key length: ${trimmedKey.length}');
    debugPrint('SportsDataIO API key header: $_apiKeyHeader');
  }

  String _datePath(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  String _endpointPath(SportsLeague league, DateTime selectedDate) {
    final datePath = _datePath(selectedDate);

    return switch (league) {
      SportsLeague.nfl =>
        '/v3/${league.pathSegment}/scores/json/ScoresByDate/$datePath',
      SportsLeague.nba || SportsLeague.mlb =>
        '/v3/${league.pathSegment}/scores/json/GamesByDate/$datePath',
      SportsLeague.pga => throw UnsupportedError('PGA uses the Golf API.'),
    };
  }
}
