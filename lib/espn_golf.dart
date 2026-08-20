import 'golf_leaderboard.dart';

GolfLeaderboard? parseEspnGolfScoreboard(
  Map<String, dynamic> json, {
  DateTime? selectedDate,
  String? tournamentId,
  int limit = 50,
}) {
  final events = json['events'];
  if (events is! List) {
    throw const FormatException('Invalid ESPN golf scoreboard.');
  }
  final candidates = events.whereType<Map<String, dynamic>>().where((event) {
    if (tournamentId != null) return '${event['id']}' == tournamentId;
    return selectedDate == null || _containsDate(event, selectedDate);
  }).toList();
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) {
    final aLive = _state(a) == 'in';
    final bLive = _state(b) == 'in';
    return aLive == bLive ? 0 : (aLive ? -1 : 1);
  });
  return _parseTournament(candidates.first, limit);
}

GolfLeaderboard _parseTournament(Map<String, dynamic> event, int limit) {
  final id = _text(event['id']);
  final name = _text(event['name']);
  final competitions = event['competitions'];
  if (id == null ||
      name == null ||
      competitions is! List ||
      competitions.isEmpty) {
    throw const FormatException('Invalid ESPN golf event.');
  }
  final competition = competitions.first;
  if (competition is! Map<String, dynamic>) {
    throw const FormatException('Invalid ESPN golf competition.');
  }
  final competitors = competition['competitors'];
  if (competitors is! List) {
    throw const FormatException('Invalid ESPN golf leaderboard.');
  }
  final period = _integer(_map(competition['status'])?['period']);
  final rows = <_GolfRow>[];
  for (final value in competitors) {
    if (value is! Map<String, dynamic>) continue;
    final athlete = _map(value['athlete']);
    final playerId = _text(value['id']) ?? _text(athlete?['id']);
    final playerName =
        _text(athlete?['displayName']) ?? _text(athlete?['fullName']);
    if (playerId == null || playerName == null) continue;
    final rawScore = _text(value['score']) ?? 'E';
    final score = _isSpecial(rawScore.toUpperCase())
        ? rawScore.toUpperCase()
        : rawScore;
    rows.add(
      _GolfRow(
        playerId: playerId,
        name: playerName,
        order: _integer(value['order']) ?? rows.length + 1,
        suppliedRank: _text(value['displayRank']) ?? _text(value['rank']),
        score: score == '0' ? 'E' : score,
        detail: _golfDetail(value, period),
      ),
    );
  }
  final selected = rows.take(limit).toList();
  final mapped = <GolfLeaderboardRow>[];
  for (var index = 0; index < selected.length; index++) {
    final row = selected[index];
    final tied =
        selected
            .where(
              (other) => other.score == row.score && !_isSpecial(row.score),
            )
            .length >
        1;
    final firstTieIndex = selected.indexWhere(
      (other) => other.score == row.score,
    );
    final rank =
        row.suppliedRank ??
        (tied ? 'T${selected[firstTieIndex].order}' : '${row.order}');
    mapped.add(
      GolfLeaderboardRow(
        playerId: row.playerId,
        name: row.name,
        rank: rank,
        score: row.score,
        detail: row.detail,
      ),
    );
  }
  final state = _state(event);
  return GolfLeaderboard(
    tournamentId: id,
    tournamentName: name,
    golfers: mapped,
    isInProgress: state == 'in',
    isOver: state == 'post',
  );
}

String? _golfDetail(Map<String, dynamic> competitor, int? currentPeriod) {
  final score = _text(competitor['score'])?.toUpperCase();
  if (_isSpecial(score)) return null;
  final linescores = competitor['linescores'];
  if (linescores is! List) return null;
  Map<String, dynamic>? round;
  for (final value in linescores.whereType<Map<String, dynamic>>()) {
    if (_integer(value['period']) == currentPeriod) round = value;
  }
  round ??= linescores.whereType<Map<String, dynamic>>().lastOrNull;
  if (round == null) return null;
  final holes = round['linescores'];
  final through = holes is List ? holes.length : 0;
  if (through >= 18) return 'F';
  if (through > 0) return 'THRU $through';
  final categories = _map(round['statistics'])?['categories'];
  if (categories is List && categories.isNotEmpty) {
    final category = categories.first;
    final stats = category is Map<String, dynamic> ? category['stats'] : null;
    if (stats is List && stats.isNotEmpty) {
      return _formatTeeTime(
        _text(
          (stats.last is Map<String, dynamic>)
              ? (stats.last as Map<String, dynamic>)['displayValue']
              : null,
        ),
      );
    }
  }
  return null;
}

String? _formatTeeTime(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'(\d{1,2}):(\d{2}):\d{2}\s+([A-Z]{3})',
  ).firstMatch(value);
  if (match == null) return value;
  var hour = int.parse(match.group(1)!);
  final suffix = hour >= 12 ? 'PM' : 'AM';
  hour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
  return '$hour:${match.group(2)} $suffix';
}

bool _containsDate(Map<String, dynamic> event, DateTime selected) {
  final start = DateTime.tryParse(_text(event['date']) ?? '');
  final end = DateTime.tryParse(_text(event['endDate']) ?? '') ?? start;
  if (start == null || end == null) return false;
  final date = DateTime.utc(selected.year, selected.month, selected.day);
  final first = DateTime.utc(start.year, start.month, start.day);
  final last = DateTime.utc(end.year, end.month, end.day);
  return !date.isBefore(first) && !date.isAfter(last);
}

String _state(Map<String, dynamic> event) {
  final type = _map(_map(event['status'])?['type']);
  if (type?['completed'] == true) return 'post';
  return _text(type?['state'])?.toLowerCase() ?? 'pre';
}

bool _isSpecial(String? value) =>
    value == 'CUT' || value == 'WD' || value == 'DQ';
int? _integer(Object? value) => int.tryParse(value?.toString() ?? '');
String? _text(Object? value) {
  final result = value?.toString().trim();
  return result == null || result.isEmpty ? null : result;
}

Map<String, dynamic>? _map(Object? value) =>
    value is Map<String, dynamic> ? value : null;

class _GolfRow {
  const _GolfRow({
    required this.playerId,
    required this.name,
    required this.order,
    required this.suppliedRank,
    required this.score,
    required this.detail,
  });
  final String playerId;
  final String name;
  final int order;
  final String? suppliedRank;
  final String score;
  final String? detail;
}
