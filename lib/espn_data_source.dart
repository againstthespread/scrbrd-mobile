import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'espn_golf.dart';
import 'espn_team_sports.dart';
import 'golf_data_source.dart';
import 'golf_leaderboard.dart';
import 'sports_data_source.dart';
import 'sports_game.dart';
import 'sports_league.dart';

class EspnDataException implements Exception {
  const EspnDataException(this.message);
  final String message;
  @override
  String toString() => message;
}

class EspnDataSource implements SportsDataSource, GolfDataSource {
  EspnDataSource({http.Client? client}) : _client = client ?? http.Client();

  static const _host = 'site.api.espn.com';
  static const _timeout = Duration(seconds: 10);
  final http.Client _client;
  final Map<String, DateTime> _golfTournamentDates = {};

  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  ) async {
    if (league == SportsLeague.pga) {
      throw UnsupportedError('PGA uses fetchGolfLeaderboardForDate.');
    }
    final uri = Uri.https(_host, _teamPath(league), {
      'dates': _compactDate(selectedDate),
    });
    debugPrint('ESPN endpoint requested: $uri');
    debugPrint('ESPN selected date: ${_compactDate(selectedDate)}');
    final json = await _getJson(uri);
    final games = parseEspnTeamScoreboard(league, json);
    debugPrint('ESPN returned event count: ${games.length}');
    for (final game in games) {
      debugPrint(
        'ESPN event ID=${game.eventId}; status=${game.status}; '
        'clock=${game.clock}',
      );
    }
    return games;
  }

  @override
  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(
    DateTime selectedDate,
  ) async {
    final uri = Uri.https(_host, _golfPath, {
      'dates': _compactDate(selectedDate),
    });
    debugPrint('ESPN endpoint requested: $uri');
    debugPrint('ESPN selected date: ${_compactDate(selectedDate)}');
    final leaderboard = parseEspnGolfScoreboard(
      await _getJson(uri),
      selectedDate: selectedDate,
    );
    if (leaderboard != null) {
      _golfTournamentDates[leaderboard.tournamentId] = selectedDate;
    }
    _logGolf(leaderboard);
    return leaderboard;
  }

  @override
  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(
    String tournamentId,
  ) async {
    final selectedDate = _golfTournamentDates[tournamentId];
    if (selectedDate == null) {
      throw EspnDataException(
        'ESPN tournament $tournamentId has no discovered date. Refresh the '
        'selected PGA date first.',
      );
    }
    // ESPN's public scoreboard currently ignores an `event` query parameter.
    // Re-fetch the discovered date and select the same stable event ID.
    final uri = Uri.https(_host, _golfPath, {
      'dates': _compactDate(selectedDate),
    });
    debugPrint('ESPN endpoint requested: $uri');
    final leaderboard = parseEspnGolfScoreboard(
      await _getJson(uri),
      tournamentId: tournamentId,
    );
    if (leaderboard == null) {
      throw EspnDataException('ESPN tournament $tournamentId was not found.');
    }
    _logGolf(leaderboard);
    return leaderboard;
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    try {
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode != 200) {
        throw EspnDataException('ESPN returned HTTP ${response.statusCode}.');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const EspnDataException('ESPN returned an unexpected response.');
      }
      return decoded;
    } on TimeoutException {
      throw const EspnDataException('ESPN request timed out.');
    } on FormatException {
      throw const EspnDataException('ESPN returned malformed JSON.');
    } on EspnDataException {
      rethrow;
    } on Object catch (error) {
      throw EspnDataException('Unable to reach ESPN: $error');
    }
  }

  void _logGolf(GolfLeaderboard? leaderboard) {
    if (leaderboard == null) {
      debugPrint('ESPN PGA event/tournament selected: none');
      return;
    }
    debugPrint(
      'ESPN PGA event/tournament selected: ${leaderboard.tournamentName}; '
      'event ID=${leaderboard.tournamentId}',
    );
    debugPrint('ESPN PGA leaderboard row count: ${leaderboard.golfers.length}');
  }

  String _teamPath(SportsLeague league) => switch (league) {
    SportsLeague.mlb => '/apis/site/v2/sports/baseball/mlb/scoreboard',
    SportsLeague.nfl => '/apis/site/v2/sports/football/nfl/scoreboard',
    SportsLeague.nba => '/apis/site/v2/sports/basketball/nba/scoreboard',
    SportsLeague.pga => throw UnsupportedError('PGA is not a team sport.'),
  };

  static const _golfPath = '/apis/site/v2/sports/golf/pga/scoreboard';

  String _compactDate(DateTime date) =>
      '${date.year}${date.month.toString().padLeft(2, '0')}'
      '${date.day.toString().padLeft(2, '0')}';
}
