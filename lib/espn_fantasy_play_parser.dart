import 'dart:convert';

import 'fantasy_nfl_play.dart';

List<FantasyNflGame> parseEspnFantasyNflGames(Map<String, dynamic> json) {
  final events = json['events'];
  if (events is! List) return const [];
  final games = <FantasyNflGame>[];
  for (final rawEvent in events) {
    final event = _map(rawEvent);
    final gameId = _text(event?['id']);
    final competitions = event?['competitions'];
    final competition = competitions is List && competitions.isNotEmpty
        ? _map(competitions.first)
        : null;
    if (gameId == null || competition == null) continue;
    final status = _map(competition['status']);
    final statusType = _map(status?['type']);
    String? homeTeam;
    String? awayTeam;
    final competitors = competition['competitors'];
    if (competitors is List) {
      for (final rawCompetitor in competitors) {
        final competitor = _map(rawCompetitor);
        final team = _map(competitor?['team']);
        final abbreviation = _text(team?['abbreviation']);
        if (competitor?['homeAway'] == 'home') homeTeam = abbreviation;
        if (competitor?['homeAway'] == 'away') awayTeam = abbreviation;
      }
    }
    games.add(
      FantasyNflGame(
        gameId: gameId,
        state: _text(statusType?['state']) ?? 'pre',
        homeTeam: homeTeam,
        awayTeam: awayTeam,
      ),
    );
  }
  return games;
}

List<FantasyNflPlay> parseEspnFantasyNflPlays(
  String gameId,
  Map<String, dynamic> json,
) {
  final teamAbbreviations = _teamAbbreviations(json);
  final drives = _map(json['drives']);
  if (drives == null) return const [];
  final rawDrives = <Object?>[];
  if (drives['previous'] is List) {
    rawDrives.addAll(drives['previous'] as List);
  }
  if (drives['current'] != null) rawDrives.add(drives['current']);
  final plays = <FantasyNflPlay>[];
  for (final rawDrive in rawDrives) {
    final drive = _map(rawDrive);
    final driveTeam = _text(_map(drive?['team'])?['abbreviation']);
    final rawPlays = drive?['plays'];
    if (rawPlays is! List) continue;
    for (final rawPlay in rawPlays) {
      final play = _parsePlay(
        gameId,
        _map(rawPlay),
        driveTeam,
        teamAbbreviations,
      );
      if (play != null) plays.add(play);
    }
  }
  return plays;
}

FantasyNflPlay? _parsePlay(
  String gameId,
  Map<String, dynamic>? json,
  String? driveTeam,
  Map<String, String> teamAbbreviations,
) {
  if (json == null) return null;
  final description = _text(json['text']);
  if (description == null) return null;
  final period = _map(json['period']);
  final clock = _map(json['clock']);
  final start = _map(json['start']);
  final startTeamId = _text(_map(start?['team'])?['id']);
  final rawId = _text(json['id']);
  final sequenceNumber = _text(json['sequenceNumber']);
  final fallbackSeed = [
    gameId,
    sequenceNumber,
    period?['number'],
    clock?['displayValue'],
    json['wallclock'],
    _map(json['type'])?['text'],
    description,
  ].join('|');
  final usesFallback = rawId == null;
  final playId =
      rawId ??
      (sequenceNumber == null
          ? 'fallback-${_stableHash(fallbackSeed)}'
          : 'sequence-$sequenceNumber');
  final rawParticipants = json['participants'];
  final participants = <FantasyNflPlayParticipant>[];
  if (rawParticipants is List) {
    for (final rawParticipant in rawParticipants) {
      final participant = _map(rawParticipant);
      if (participant == null) continue;
      final athlete = _map(participant['athlete']);
      participants.add(
        FantasyNflPlayParticipant(
          espnAthleteId: _text(athlete?['id']),
          displayName:
              _text(athlete?['displayName']) ?? _text(athlete?['fullName']),
          role: _text(participant['type']),
          team: _text(_map(athlete?['team'])?['abbreviation']),
        ),
      );
    }
  }
  return FantasyNflPlay(
    playId: playId,
    gameId: gameId,
    description: description,
    possessionTeam: startTeamId == null
        ? driveTeam
        : teamAbbreviations[startTeamId] ?? driveTeam,
    yards: _int(json['statYardage']),
    type: classifyEspnFantasyNflPlay(_text(_map(json['type'])?['text'])),
    wallClock: DateTime.tryParse(_text(json['wallclock']) ?? ''),
    quarter: _int(period?['number']),
    gameClock: _text(clock?['displayValue']),
    isScoringPlay: json['scoringPlay'] == true,
    participants: List.unmodifiable(participants),
    usesFallbackIdentity: usesFallback,
  );
}

FantasyNflPlayType classifyEspnFantasyNflPlay(String? rawType) {
  final type = rawType?.toLowerCase() ?? '';
  if (type.contains('two-point') || type.contains('two point')) {
    return FantasyNflPlayType.twoPointConversion;
  }
  if (type.contains('extra point')) return FantasyNflPlayType.extraPoint;
  if (type.contains('interception')) return FantasyNflPlayType.interception;
  if (type.contains('fumble')) return FantasyNflPlayType.fumble;
  if (type.contains('field goal')) return FantasyNflPlayType.fieldGoal;
  if (type.contains('touchdown')) return FantasyNflPlayType.touchdown;
  if (type.contains('reception')) return FantasyNflPlayType.reception;
  if (type.contains('incompletion') || type == 'pass') {
    return FantasyNflPlayType.pass;
  }
  if (type.contains('rush')) return FantasyNflPlayType.rush;
  if (type.contains('sack')) return FantasyNflPlayType.sack;
  if (type.contains('safety')) return FantasyNflPlayType.safety;
  if (type.contains('punt')) return FantasyNflPlayType.punt;
  if (type.contains('kickoff')) return FantasyNflPlayType.kickoff;
  if (type.contains('penalty')) return FantasyNflPlayType.penalty;
  return FantasyNflPlayType.other;
}

Map<String, String> _teamAbbreviations(Map<String, dynamic> json) {
  final result = <String, String>{};
  final header = _map(json['header']);
  final competitions = header?['competitions'];
  if (competitions is! List || competitions.isEmpty) return result;
  final competitors = _map(competitions.first)?['competitors'];
  if (competitors is! List) return result;
  for (final rawCompetitor in competitors) {
    final competitor = _map(rawCompetitor);
    final team = _map(competitor?['team']);
    final id = _text(team?['id']) ?? _text(competitor?['id']);
    final abbreviation = _text(team?['abbreviation']);
    if (id != null && abbreviation != null) result[id] = abbreviation;
  }
  return result;
}

String _stableHash(String value) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

Map<String, dynamic>? _map(Object? value) =>
    value is Map<String, dynamic> ? value : null;
String? _text(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
