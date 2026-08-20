import 'package:flutter/foundation.dart';

import 'sports_game.dart';
import 'sports_league.dart';

class SportsDataIOGame {
  const SportsDataIOGame({
    required this.awayTeam,
    required this.homeTeam,
    required this.awayScore,
    required this.homeScore,
    required this.status,
    required this.clock,
    this.statusDetail,
    this.scheduledStartTime,
    this.eventId,
  });

  final String awayTeam;
  final String homeTeam;
  final int awayScore;
  final int homeScore;
  final String status;
  final String clock;
  final String? statusDetail;
  final DateTime? scheduledStartTime;
  final String? eventId;

  factory SportsDataIOGame.fromJson(
    SportsLeague league,
    Map<String, dynamic> json,
  ) {
    final awayTeam = _requiredString(json, 'AwayTeam');
    final homeTeam = _requiredString(json, 'HomeTeam');
    final statusDetail = _optionalString(json, 'Status');
    final status = _statusFromJson(json, statusDetail);
    final scores = _scoresFromJson(league, json);
    final scheduledStartTime = _scheduledStartTimeFromJson(json);
    final eventId = _eventIdFromJson(json);
    final clock = _clockFromJson(json, league, status, scheduledStartTime);

    final game = SportsDataIOGame(
      awayTeam: awayTeam,
      homeTeam: homeTeam,
      awayScore: scores.awayScore,
      homeScore: scores.homeScore,
      status: status,
      clock: clock,
      statusDetail: statusDetail,
      scheduledStartTime: scheduledStartTime,
      eventId: eventId,
    );

    _logScoreMapping(league, json, game);
    return game;
  }

  SportsGame toSportsGame(SportsLeague league) {
    return SportsGame(
      league: league.label,
      awayTeam: awayTeam,
      homeTeam: homeTeam,
      awayScore: awayScore,
      homeScore: homeScore,
      status: status,
      clock: clock,
      statusDetail: statusDetail,
      scheduledStartTime: scheduledStartTime,
      eventId: eventId,
    );
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }

    throw FormatException('Missing or invalid $key');
  }

  static _MappedScores _scoresFromJson(
    SportsLeague league,
    Map<String, dynamic> json,
  ) {
    final fields = switch (league) {
      SportsLeague.nfl => ('AwayScore', 'HomeScore'),
      SportsLeague.nba => ('AwayTeamScore', 'HomeTeamScore'),
      SportsLeague.mlb => ('AwayTeamRuns', 'HomeTeamRuns'),
      SportsLeague.pga => throw UnsupportedError('PGA is not a team sport.'),
    };

    return _MappedScores(
      awayScore: _scoreOrZero(json[fields.$1]),
      homeScore: _scoreOrZero(json[fields.$2]),
    );
  }

  static int _scoreOrZero(Object? value) {
    return _tryParseScore(value) ?? 0;
  }

  static int? _tryParseScore(Object? value) {
    if (value is int && value >= 0) {
      return value;
    }

    if (value is num && value >= 0) {
      return value.toInt();
    }

    if (value is String) {
      final parsedValue = int.tryParse(value);
      if (parsedValue != null && parsedValue >= 0) {
        return parsedValue;
      }
    }

    return null;
  }

  static String? _optionalString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }

    return null;
  }

  static String _statusFromJson(
    Map<String, dynamic> json,
    String? statusDetail,
  ) {
    final normalizedStatus = statusDetail?.trim().toLowerCase();

    if (normalizedStatus != null) {
      if (_finalStatuses.contains(normalizedStatus)) {
        return 'FINAL';
      }

      if (_liveStatuses.contains(normalizedStatus)) {
        return 'LIVE';
      }

      if (_upcomingStatuses.contains(normalizedStatus)) {
        return 'UPCOMING';
      }
    }

    if (json['IsOver'] == true) {
      return 'FINAL';
    }

    if (json['IsInProgress'] == true) {
      return 'LIVE';
    }

    return 'UPCOMING';
  }

  static DateTime? _scheduledStartTimeFromJson(Map<String, dynamic> json) {
    final dateTime = _optionalString(json, 'DateTime');
    final date = _optionalString(json, 'Date');
    final day = _optionalString(json, 'Day');

    return _tryParseLocalDateTime(dateTime) ??
        _tryParseLocalDateTime(date) ??
        _tryParseLocalDateTime(day);
  }

  static String? _eventIdFromJson(Map<String, dynamic> json) {
    const eventIdFields = [
      'GlobalGameID',
      'GlobalGameId',
      'GameID',
      'GameId',
      'ScoreID',
      'ScoreId',
      'GameKey',
    ];

    for (final field in eventIdFields) {
      final value = json[field];
      if (value == null) {
        continue;
      }

      final eventId = value.toString().trim();
      if (eventId.isNotEmpty) {
        return eventId;
      }
    }

    return null;
  }

  static DateTime? _tryParseLocalDateTime(String? value) {
    if (value == null) {
      return null;
    }

    return DateTime.tryParse(value)?.toLocal();
  }

  static String _clockFromJson(
    Map<String, dynamic> json,
    SportsLeague league,
    String status,
    DateTime? scheduledStartTime,
  ) {
    if (status == 'UPCOMING' && scheduledStartTime != null) {
      return _formatTime(scheduledStartTime);
    }

    if (league == SportsLeague.mlb) {
      return _baseballClockFromJson(json, status, scheduledStartTime);
    }

    return _periodClockFromJson(json, status, scheduledStartTime);
  }

  static String _periodClockFromJson(
    Map<String, dynamic> json,
    String status,
    DateTime? scheduledStartTime,
  ) {
    final quarter = _optionalValueAsString(json, 'Quarter');
    final period = _optionalValueAsString(json, 'Period');
    final quarterDescription = _optionalString(json, 'QuarterDescription');
    final timeRemaining = _optionalString(json, 'TimeRemaining');
    final periodValue = quarter ?? period;

    if (quarterDescription is String && quarterDescription.trim().isNotEmpty) {
      return quarterDescription.trim();
    }

    if (periodValue != null && timeRemaining != null) {
      return 'Q$periodValue $timeRemaining';
    }

    if (periodValue != null) {
      return 'Q$periodValue';
    }

    if (scheduledStartTime != null) {
      return _formatTime(scheduledStartTime);
    }

    return status;
  }

  static String _baseballClockFromJson(
    Map<String, dynamic> json,
    String status,
    DateTime? scheduledStartTime,
  ) {
    final inning = _optionalValueAsString(json, 'Inning');
    final inningHalf =
        _optionalString(json, 'InningHalf') ??
        _optionalString(json, 'InningHalfDescription');
    final inningDescription = _optionalString(json, 'InningDescription');

    if (inningDescription != null) {
      return inningDescription;
    }

    if (inning != null && inningHalf != null) {
      return '${_shortInningHalf(inningHalf)} $inning';
    }

    if (inning != null) {
      return 'Inning $inning';
    }

    if (scheduledStartTime != null) {
      return _formatTime(scheduledStartTime);
    }

    return status;
  }

  static String? _optionalValueAsString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) {
      return null;
    }

    final stringValue = value.toString().trim();
    if (stringValue.isEmpty) {
      return null;
    }

    return stringValue;
  }

  static String _shortInningHalf(String inningHalf) {
    final normalized = inningHalf.trim().toLowerCase();
    if (normalized.startsWith('top') || normalized == 't') {
      return 'Top';
    }

    if (normalized.startsWith('bot') || normalized == 'b') {
      return 'Bot';
    }

    return inningHalf.trim();
  }

  static void _logScoreMapping(
    SportsLeague league,
    Map<String, dynamic> json,
    SportsDataIOGame game,
  ) {
    final primaryScoreFields = switch (league) {
      SportsLeague.nfl => ('AwayScore', 'HomeScore'),
      SportsLeague.nba => ('AwayTeamScore', 'HomeTeamScore'),
      SportsLeague.mlb => ('AwayTeamRuns', 'HomeTeamRuns'),
      SportsLeague.pga => throw UnsupportedError('PGA is not a team sport.'),
    };

    debugPrint('SportsDataIO score mapping league: ${league.label}');
    debugPrint(
      'SportsDataIO score mapping away team: '
      '${_diagnosticField(json, 'AwayTeam')} '
      'id=${_diagnosticAny(json, ['AwayTeamID', 'AwayTeamId', 'GlobalAwayTeamID', 'GlobalAwayTeamId'])}',
    );
    debugPrint(
      'SportsDataIO score mapping home team: '
      '${_diagnosticField(json, 'HomeTeam')} '
      'id=${_diagnosticAny(json, ['HomeTeamID', 'HomeTeamId', 'GlobalHomeTeamID', 'GlobalHomeTeamId'])}',
    );
    debugPrint(
      'SportsDataIO raw away score: ${primaryScoreFields.$1}='
      '${json[primaryScoreFields.$1]}',
    );
    debugPrint(
      'SportsDataIO raw home score: ${primaryScoreFields.$2}='
      '${json[primaryScoreFields.$2]}',
    );
    debugPrint(
      'SportsDataIO alternate score fields present: '
      '${_alternateScoreFields(json, primaryScoreFields)}',
    );
    debugPrint(
      'SportsDataIO canonical score: awayScore=${game.awayScore}, '
      'homeScore=${game.homeScore}, status=${game.status}',
    );
  }

  static Object? _diagnosticField(Map<String, dynamic> json, String key) {
    return json.containsKey(key) ? json[key] : '<missing>';
  }

  static Object? _diagnosticAny(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      if (json.containsKey(key)) {
        return '$key=${json[key]}';
      }
    }

    return '<missing>';
  }

  static List<String> _alternateScoreFields(
    Map<String, dynamic> json,
    (String, String) primaryScoreFields,
  ) {
    const knownScoreFields = [
      'AwayScore',
      'HomeScore',
      'AwayTeamScore',
      'HomeTeamScore',
      'AwayTeamScore2',
      'HomeTeamScore2',
      'AwayTeamRuns',
      'HomeTeamRuns',
      'AwayRuns',
      'HomeRuns',
    ];

    return knownScoreFields
        .where(
          (field) =>
              field != primaryScoreFields.$1 &&
              field != primaryScoreFields.$2 &&
              json.containsKey(field),
        )
        .map((field) => '$field=${json[field]}')
        .toList();
  }

  static String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour == 0
        ? 12
        : dateTime.hour > 12
        ? dateTime.hour - 12
        : dateTime.hour;
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final period = dateTime.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  static const _finalStatuses = {
    'final',
    'f',
    'f/ot',
    'completed',
    'closed',
    'complete',
    'post-game',
    'postgame',
    'game over',
    'ended',
  };

  static const _liveStatuses = {
    'inprogress',
    'in progress',
    'live',
    'active',
    'halftime',
    'half',
    'in-progress',
    'started',
  };

  static const _upcomingStatuses = {
    'scheduled',
    'created',
    'pre-game',
    'pregame',
    'postponed',
    'delayed',
    'canceled',
    'cancelled',
    'suspended',
    'unknown',
  };
}

class _MappedScores {
  const _MappedScores({required this.awayScore, required this.homeScore});

  final int awayScore;
  final int homeScore;
}
