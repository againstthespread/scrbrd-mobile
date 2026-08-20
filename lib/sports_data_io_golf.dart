import 'package:flutter/foundation.dart';

import 'golf_leaderboard.dart';

class SportsDataIOGolfTournament {
  const SportsDataIOGolfTournament({
    required this.tournamentId,
    required this.name,
    required this.startDate,
    required this.endDate,
    required this.covered,
    required this.isInProgress,
    required this.isOver,
  });

  final String tournamentId;
  final String name;
  final DateTime startDate;
  final DateTime endDate;
  final bool? covered;
  final bool isInProgress;
  final bool isOver;

  factory SportsDataIOGolfTournament.fromJson(Map<String, dynamic> json) {
    final id = json['TournamentID'];
    final name = json['Name'];
    final start = DateTime.tryParse(json['StartDate']?.toString() ?? '');
    final end = DateTime.tryParse(json['EndDate']?.toString() ?? '');
    if (id == null || name is! String || start == null || end == null) {
      throw const FormatException('Invalid golf tournament.');
    }
    return SportsDataIOGolfTournament(
      tournamentId: id.toString(),
      name: name.trim(),
      startDate: start,
      endDate: end,
      covered: json['Covered'] is bool ? json['Covered'] as bool : null,
      isInProgress: json['IsInProgress'] == true,
      isOver: json['IsOver'] == true,
    );
  }
}

SportsDataIOGolfTournament? selectGolfTournamentForDate(
  List<SportsDataIOGolfTournament> tournaments,
  DateTime selectedDate,
) {
  final date = DateTime(
    selectedDate.year,
    selectedDate.month,
    selectedDate.day,
  );
  final candidates = tournaments.where((tournament) {
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
    return tournament.covered != false &&
        !date.isBefore(start) &&
        !date.isAfter(end);
  }).toList();
  candidates.sort((a, b) {
    if (a.isInProgress != b.isInProgress) return a.isInProgress ? -1 : 1;
    return a.startDate.compareTo(b.startDate);
  });
  return candidates.firstOrNull;
}

GolfLeaderboard parseSportsDataIOGolfLeaderboard(
  Map<String, dynamic> json, {
  int limit = 50,
}) {
  final tournamentJson = json['Tournament'];
  final playersJson = json['Players'];
  if (tournamentJson is! Map<String, dynamic> || playersJson is! List) {
    throw const FormatException('Invalid golf leaderboard.');
  }
  final tournament = SportsDataIOGolfTournament.fromJson(tournamentJson);
  final indexedRows =
      <({int sourceIndex, GolfLeaderboardRow row, int? rank})>[];
  for (var index = 0; index < playersJson.length; index++) {
    final value = playersJson[index];
    if (value is! Map<String, dynamic>) continue;
    final id = value['PlayerID'];
    final name = value['Name'];
    if (id == null || name is! String || name.trim().isEmpty) continue;
    final rank = _integer(value['Rank']);
    final totalScore = value['TotalScore'] is num
        ? value['TotalScore'] as num
        : num.tryParse(value['TotalScore']?.toString() ?? '');
    final through = _integer(value['TotalThrough']);
    final state = _golfRowState(
      value,
      totalScore: totalScore,
      through: through,
      tournamentIsOver: tournament.isOver,
    );
    indexedRows.add((
      sourceIndex: index,
      rank: rank,
      row: GolfLeaderboardRow(
        playerId: id.toString(),
        name: name.trim(),
        rank: rank?.toString() ?? '-',
        score: state.score,
        detail: state.detail,
      ),
    ));
  }
  indexedRows.sort((a, b) {
    final rankCompare = (a.rank ?? 9999).compareTo(b.rank ?? 9999);
    return rankCompare != 0
        ? rankCompare
        : a.sourceIndex.compareTo(b.sourceIndex);
  });
  final golfers = indexedRows.take(limit).map((entry) => entry.row).toList();
  debugPrint('SportsDataIO golf leaderboard row count: ${golfers.length}');
  return GolfLeaderboard(
    tournamentId: tournament.tournamentId,
    tournamentName: tournament.name,
    golfers: golfers,
    isInProgress: tournament.isInProgress,
    isOver: tournament.isOver,
  );
}

int? _integer(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

({String score, String? detail}) _golfRowState(
  Map<String, dynamic> json, {
  required num? totalScore,
  required int? through,
  required bool tournamentIsOver,
}) {
  final specialStatus = _golfSpecialStatus(json, through: through);
  if (specialStatus != null) {
    return (score: specialStatus, detail: null);
  }

  final score = formatGolfScore(totalScore);
  if (through == null || through <= 0) {
    return (score: score, detail: _teeTimeDetail(json['TeeTime']));
  }
  if (through >= 18 || tournamentIsOver) {
    return (score: score, detail: 'F');
  }
  return (score: score, detail: 'THRU $through');
}

String? _golfSpecialStatus(Map<String, dynamic> json, {required int? through}) {
  if (json['IsWithdrawn'] == true) return 'WD';
  final status = json['TournamentStatus']?.toString().trim().toUpperCase();
  if (status == 'WD' || status == 'WITHDRAWN') return 'WD';
  if (status == 'DQ' || status == 'DISQUALIFIED') return 'DQ';
  if (status == 'CUT' || status == 'MISSED CUT') return 'CUT';

  // SportsDataIO can report MadeCut=0 before a golfer tees off. Treat it as
  // CUT only after score/thru data proves the golfer has actually played.
  final madeCut = json['MadeCut'];
  final explicitlyMissedCut =
      (madeCut is num && madeCut == 0) || madeCut == false;
  final hasPlayed = through != null && through > 0;
  if (explicitlyMissedCut && hasPlayed) return 'CUT';
  return null;
}

String? _teeTimeDetail(Object? value) {
  final teeTime = value?.toString().trim();
  if (teeTime == null || teeTime.isEmpty) return null;
  final parsed = DateTime.tryParse(teeTime);
  if (parsed == null || !teeTime.contains('T')) return teeTime;
  final hour = parsed.hour == 0
      ? 12
      : (parsed.hour > 12 ? parsed.hour - 12 : parsed.hour);
  final minute = parsed.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${parsed.hour >= 12 ? 'PM' : 'AM'}';
}
