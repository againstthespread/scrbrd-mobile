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
  EspnDataSource({http.Client? client, int Function()? epochMilliseconds})
    : _client = client ?? http.Client(),
      _epochMilliseconds =
          epochMilliseconds ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const _host = 'site.api.espn.com';
  static const _timeout = Duration(seconds: 10);
  final http.Client _client;
  final int Function() _epochMilliseconds;
  final Map<String, DateTime> _golfTournamentDates = {};
  int _lastCacheBuster = -1;

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
      '_scrbrd_ts': _nextCacheBuster().toString(),
    });
    debugPrint('ESPN endpoint requested: $uri');
    debugPrint('ESPN selected date: ${_compactDate(selectedDate)}');
    final json = await _getJson(uri, logCacheDiagnostics: true);
    if (league == SportsLeague.mlb) {
      _logRawMlbEvents(json);
    }
    final games = parseEspnTeamScoreboard(league, json);
    debugPrint('ESPN returned event count: ${games.length}');
    for (final game in games) {
      debugPrint(
        'ESPN mapped game: event ID=${game.eventId}; '
        'away=${game.awayTeam} score=${game.awayScore}; '
        'home=${game.homeTeam} score=${game.homeScore}; '
        'status=${game.status}; clock=${game.clock}; '
        'statusDetail=${game.statusDetail}; '
        'onFirst=${game.baseballState?.runnerOnFirst}; '
        'onSecond=${game.baseballState?.runnerOnSecond}; '
        'onThird=${game.baseballState?.runnerOnThird}; '
        'outs=${game.baseballState?.outs}',
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
      debugPrint(
        'PGA discovery cache: tournamentId=${leaderboard.tournamentId}; '
        'selectedDate=${_compactDate(selectedDate)}',
      );
    }
    _logGolf(leaderboard);
    return leaderboard;
  }

  @override
  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(
    String tournamentId,
  ) async {
    final selectedDate = _golfTournamentDates[tournamentId];
    debugPrint(
      'PGA tracked tournament=$tournamentId; PGA provider discovered date='
      '${selectedDate == null ? '<missing>' : _compactDate(selectedDate)}',
    );
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

  @visibleForTesting
  DateTime? discoveredGolfDateForTesting(String tournamentId) =>
      _golfTournamentDates[tournamentId];

  Future<Map<String, dynamic>> _getJson(
    Uri uri, {
    bool logCacheDiagnostics = false,
  }) async {
    try {
      final response = await _client
          .get(
            uri,
            headers: logCacheDiagnostics
                ? const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'}
                : null,
          )
          .timeout(_timeout);
      if (logCacheDiagnostics) {
        _logHttpCacheDiagnostics(uri, response);
      }
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

  int _nextCacheBuster() {
    final current = _epochMilliseconds();
    final next = current > _lastCacheBuster ? current : _lastCacheBuster + 1;
    _lastCacheBuster = next;
    return next;
  }

  void _logHttpCacheDiagnostics(Uri uri, http.Response response) {
    final headers = response.headers;
    debugPrint('ESPN team response URL: $uri');
    debugPrint('ESPN team response Date: ${headers['date'] ?? '<absent>'}');
    debugPrint('ESPN team response Age: ${headers['age'] ?? '<absent>'}');
    debugPrint(
      'ESPN team response Cache-Control: '
      '${headers['cache-control'] ?? '<absent>'}',
    );
    debugPrint('ESPN team response ETag: ${headers['etag'] ?? '<absent>'}');
    for (final name in const [
      'x-cache',
      'x-cache-hits',
      'cf-cache-status',
      'x-served-by',
      'via',
      'server',
    ]) {
      final value = headers[name];
      if (value != null) {
        debugPrint('ESPN team response $name: $value');
      }
    }
    debugPrint(
      'ESPN team response body length: ${response.bodyBytes.length} bytes',
    );
  }

  void _logRawMlbEvents(Map<String, dynamic> json) {
    final events = json['events'];
    if (events is! List) return;
    for (final event in events.whereType<Map<String, dynamic>>()) {
      final competitions = event['competitions'];
      if (competitions is! List || competitions.isEmpty) continue;
      final competition = competitions.first;
      if (competition is! Map<String, dynamic>) continue;
      final competitors = competition['competitors'];
      Map<String, dynamic>? away;
      Map<String, dynamic>? home;
      if (competitors is List) {
        for (final competitor
            in competitors.whereType<Map<String, dynamic>>()) {
          if (competitor['homeAway'] == 'away') away = competitor;
          if (competitor['homeAway'] == 'home') home = competitor;
        }
      }
      final status =
          _jsonMap(competition['status']) ?? _jsonMap(event['status']);
      final type = _jsonMap(status?['type']);
      final situation = _jsonMap(competition['situation']);
      debugPrint(
        'ESPN raw MLB event: event ID=${event['id']}; '
        'awayScore=${away?['score']}; homeScore=${home?['score']}; '
        'status.type.name=${type?['name']}; '
        'status.type.state=${type?['state']}; '
        'status.period=${status?['period']}; '
        'status.displayClock=${status?['displayClock']}; '
        'status.type.shortDetail=${type?['shortDetail']}; '
        'status.type.detail=${type?['detail']}; '
        'situation.onFirst=${situation?['onFirst']}; '
        'situation.onSecond=${situation?['onSecond']}; '
        'situation.onThird=${situation?['onThird']}; '
        'situation.outs=${situation?['outs']}',
      );
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

Map<String, dynamic>? _jsonMap(Object? value) =>
    value is Map<String, dynamic> ? value : null;
