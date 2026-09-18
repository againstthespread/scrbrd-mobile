import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'espn_fantasy_credentials.dart';

enum EspnFantasyFailure {
  missingCredentials,
  unauthorized,
  leagueUnavailable,
  teamUnavailable,
  matchupUnavailable,
  invalidRequest,
  invalidResponse,
  network,
}

class EspnFantasyException implements Exception {
  const EspnFantasyException(this.failure);
  final EspnFantasyFailure failure;

  @override
  String toString() => switch (failure) {
    EspnFantasyFailure.missingCredentials => 'Connect your ESPN account.',
    EspnFantasyFailure.unauthorized =>
      'ESPN credentials were rejected or expired.',
    EspnFantasyFailure.leagueUnavailable =>
      'ESPN league was not found or is inaccessible.',
    EspnFantasyFailure.teamUnavailable => 'Selected ESPN team was not found.',
    EspnFantasyFailure.matchupUnavailable =>
      'Current ESPN matchup is unavailable.',
    EspnFantasyFailure.invalidRequest =>
      'Enter a valid ESPN league and season.',
    EspnFantasyFailure.invalidResponse =>
      'ESPN returned unexpected fantasy data.',
    EspnFantasyFailure.network => 'Could not reach ESPN right now.',
  };
}

/// The only place that knows ESPN fantasy URLs, cookies, and wire responses.
class EspnFantasyClient {
  EspnFantasyClient({
    required this.credentialsStore,
    http.Client? client,
    Uri? baseUri,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _baseUri = baseUri ?? Uri.https('lm-api-reads.fantasy.espn.com', '');

  final EspnFantasyCredentialsStore credentialsStore;
  final http.Client _client;
  final bool _ownsClient;
  final Uri _baseUri;
  final Duration timeout;

  Future<Map<String, dynamic>> loadLeague({
    required int season,
    required String leagueId,
  }) => _get(season: season, leagueId: leagueId, views: const ['mTeam']);

  /// ESPN's box score view provides current-period roster entries and scores.
  Future<Map<String, dynamic>> loadBoxScore({
    required int season,
    required String leagueId,
    required int scoringPeriod,
    required int matchupPeriod,
  }) => _get(
    season: season,
    leagueId: leagueId,
    views: const ['mMatchupScore', 'mScoreboard'],
    scoringPeriod: scoringPeriod,
    matchupPeriod: matchupPeriod,
  );

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<Map<String, dynamic>> _get({
    required int season,
    required String leagueId,
    required List<String> views,
    int? scoringPeriod,
    int? matchupPeriod,
  }) async {
    if (season < 2000 ||
        season > 9999 ||
        int.tryParse(leagueId) == null ||
        int.parse(leagueId) <= 0 ||
        (scoringPeriod != null && scoringPeriod < 1) ||
        (matchupPeriod != null && matchupPeriod < 1)) {
      throw const EspnFantasyException(EspnFantasyFailure.invalidRequest);
    }
    EspnFantasyCredentials? credentials;
    try {
      credentials = await credentialsStore.read();
    } on Object {
      throw const EspnFantasyException(EspnFantasyFailure.missingCredentials);
    }
    if (credentials == null || !credentials.isValid) {
      throw const EspnFantasyException(EspnFantasyFailure.missingCredentials);
    }
    // Never include cookies in a URI, log line, or exception.
    final uri = _baseUri.replace(
      path: '/apis/v3/games/ffl/seasons/$season/segments/0/leagues/$leagueId',
      queryParameters: {
        'view': views,
        if (scoringPeriod != null) 'scoringPeriodId': '$scoringPeriod',
      },
    );
    try {
      final response = await _client
          .get(
            uri,
            headers: {
              'Cookie':
                  'SWID=${credentials.swid}; espn_s2=${credentials.espnS2}',
              'Accept': 'application/json',
              if (matchupPeriod != null)
                'X-Fantasy-Filter': jsonEncode({
                  'schedule': {
                    'filterMatchupPeriodIds': {
                      'value': [matchupPeriod],
                    },
                  },
                }),
            },
          )
          .timeout(timeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const EspnFantasyException(EspnFantasyFailure.unauthorized);
      }
      if (response.statusCode == 404) {
        throw const EspnFantasyException(EspnFantasyFailure.leagueUnavailable);
      }
      if (response.statusCode == 400) {
        throw const EspnFantasyException(EspnFantasyFailure.invalidRequest);
      }
      if (response.statusCode != 200) {
        throw const EspnFantasyException(EspnFantasyFailure.network);
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const EspnFantasyException(EspnFantasyFailure.invalidResponse);
      }
      return decoded;
    } on EspnFantasyException {
      rethrow;
    } on FormatException {
      throw const EspnFantasyException(EspnFantasyFailure.invalidResponse);
    } on TimeoutException {
      throw const EspnFantasyException(EspnFantasyFailure.network);
    } on Object {
      // HTTP failures can contain request headers; never expose raw details.
      throw const EspnFantasyException(EspnFantasyFailure.network);
    }
  }
}
