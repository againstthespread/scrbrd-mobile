import 'sports_game.dart';
import 'sports_league.dart';

List<SportsGame> parseEspnTeamScoreboard(
  SportsLeague league,
  Map<String, dynamic> json,
) {
  if (league == SportsLeague.pga) {
    throw UnsupportedError('PGA uses the ESPN golf parser.');
  }
  final events = json['events'];
  if (events is! List) {
    throw const FormatException('Invalid ESPN scoreboard.');
  }
  final games = <SportsGame>[];
  for (final value in events) {
    if (value is! Map<String, dynamic>) continue;
    try {
      games.add(_parseEvent(league, value));
    } on FormatException {
      continue;
    }
  }
  return games;
}

SportsGame _parseEvent(SportsLeague league, Map<String, dynamic> event) {
  final eventId = _nonEmpty(event['id']);
  final competitions = event['competitions'];
  if (eventId == null || competitions is! List || competitions.isEmpty) {
    throw const FormatException('Invalid ESPN event.');
  }
  final competition = competitions.first;
  if (competition is! Map<String, dynamic>) {
    throw const FormatException('Invalid ESPN competition.');
  }
  final competitors = competition['competitors'];
  if (competitors is! List) {
    throw const FormatException('Invalid ESPN competitors.');
  }
  Map<String, dynamic>? away;
  Map<String, dynamic>? home;
  for (final value in competitors) {
    if (value is! Map<String, dynamic>) continue;
    switch (_nonEmpty(value['homeAway'])?.toLowerCase()) {
      case 'away':
        away = value;
      case 'home':
        home = value;
    }
  }
  if (away == null || home == null) {
    throw const FormatException('ESPN event is missing teams.');
  }
  final statusJson = _map(competition['status']) ?? _map(event['status']);
  final type = _map(statusJson?['type']);
  final status = _canonicalStatus(type);
  final start = DateTime.tryParse(
    _nonEmpty(competition['date']) ?? _nonEmpty(event['date']) ?? '',
  )?.toLocal();
  final detail = _statusDetail(type);
  return SportsGame(
    league: league.label,
    awayTeam: _teamName(away),
    homeTeam: _teamName(home),
    awayScore: _score(away['score']),
    homeScore: _score(home['score']),
    status: status,
    clock: _clock(league, statusJson, type, status, start),
    statusDetail: detail,
    scheduledStartTime: start,
    eventId: eventId,
    baseballState: league == SportsLeague.mlb && status == 'LIVE'
        ? _baseballState(competition)
        : null,
  );
}

BaseballGameState? _baseballState(Map<String, dynamic> competition) {
  final situation = _map(competition['situation']);
  if (situation == null ||
      situation['onFirst'] is! bool ||
      situation['onSecond'] is! bool ||
      situation['onThird'] is! bool) {
    return null;
  }
  final outs = _integer(situation['outs']);
  if (outs == null || outs < 0 || outs > 2) return null;
  return BaseballGameState(
    runnerOnFirst: situation['onFirst'] as bool,
    runnerOnSecond: situation['onSecond'] as bool,
    runnerOnThird: situation['onThird'] as bool,
    outs: outs,
  );
}

String _teamName(Map<String, dynamic> competitor) {
  final team = _map(competitor['team']);
  final value =
      _nonEmpty(team?['abbreviation']) ??
      _nonEmpty(team?['shortDisplayName']) ??
      _nonEmpty(team?['displayName']);
  if (value == null) throw const FormatException('Missing ESPN team.');
  return value;
}

String _canonicalStatus(Map<String, dynamic>? type) {
  final name = _nonEmpty(type?['name'])?.toUpperCase() ?? '';
  final state = _nonEmpty(type?['state'])?.toLowerCase() ?? '';
  if (type?['completed'] == true || state == 'post' || name.contains('FINAL')) {
    return 'FINAL';
  }
  if (state == 'in' || name.contains('IN_PROGRESS')) return 'LIVE';
  return 'UPCOMING';
}

String _clock(
  SportsLeague league,
  Map<String, dynamic>? statusJson,
  Map<String, dynamic>? type,
  String status,
  DateTime? start,
) {
  final detail = _statusDetail(type);
  if (status == 'FINAL') return detail ?? 'FINAL';
  if (status == 'UPCOMING') {
    return detail ?? (start == null ? 'UPCOMING' : _formatTime(start));
  }
  if (league == SportsLeague.mlb) {
    return _mlbClock(statusJson, detail);
  }
  final period = _integer(statusJson?['period']);
  final displayClock = _nonEmpty(statusJson?['displayClock']);
  if (period != null && displayClock != null) return 'Q$period $displayClock';
  return detail ?? displayClock ?? status;
}

String _mlbClock(Map<String, dynamic>? statusJson, String? detail) {
  final inning =
      _integer(statusJson?['period']) ??
      int.tryParse(RegExp(r'\d+').firstMatch(detail ?? '')?.group(0) ?? '');
  if (inning == null || inning < 1) return detail ?? 'LIVE';

  final normalizedDetail = detail?.trim().toLowerCase() ?? '';
  final half = switch (normalizedDetail) {
    final value when RegExp(r'\btop\b').hasMatch(value) => 'Top',
    final value when RegExp(r'\bbot(?:tom)?\b').hasMatch(value) => 'Bot',
    _ => null,
  };
  final ordinal = _ordinal(inning);
  return half == null ? ordinal : '$half $ordinal';
}

String _ordinal(int value) {
  final lastTwoDigits = value % 100;
  if (lastTwoDigits >= 11 && lastTwoDigits <= 13) return '${value}th';
  return switch (value % 10) {
    1 => '${value}st',
    2 => '${value}nd',
    3 => '${value}rd',
    _ => '${value}th',
  };
}

String? _statusDetail(Map<String, dynamic>? type) =>
    _nonEmpty(type?['shortDetail']) ??
    _nonEmpty(type?['detail']) ??
    _nonEmpty(type?['description']);

String _formatTime(DateTime value) {
  final hour = value.hour == 0
      ? 12
      : (value.hour > 12 ? value.hour - 12 : value.hour);
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${value.hour >= 12 ? 'PM' : 'AM'}';
}

int _score(Object? value) => int.tryParse(value?.toString() ?? '') ?? 0;
int? _integer(Object? value) => int.tryParse(value?.toString() ?? '');
String? _nonEmpty(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

Map<String, dynamic>? _map(Object? value) =>
    value is Map<String, dynamic> ? value : null;
