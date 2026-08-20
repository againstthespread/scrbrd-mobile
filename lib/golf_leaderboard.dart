class GolfLeaderboard {
  const GolfLeaderboard({
    required this.tournamentId,
    required this.tournamentName,
    required this.golfers,
    required this.isInProgress,
    required this.isOver,
  });

  final String tournamentId;
  final String tournamentName;
  final List<GolfLeaderboardRow> golfers;
  final bool isInProgress;
  final bool isOver;

  static const golfersPerPage = 5;

  int get pageCount => (golfers.length + golfersPerPage - 1) ~/ golfersPerPage;
}

class GolfLeaderboardRow {
  const GolfLeaderboardRow({
    required this.playerId,
    required this.name,
    required this.rank,
    required this.score,
    this.detail,
  });

  final String playerId;
  final String name;
  final String rank;
  final String score;
  final String? detail;
}

String formatGolfScore(num? totalScore, {String? specialStatus}) {
  final normalizedStatus = specialStatus?.trim().toUpperCase();
  if (normalizedStatus == 'CUT' ||
      normalizedStatus == 'WD' ||
      normalizedStatus == 'DQ') {
    return normalizedStatus!;
  }
  if (totalScore == null || totalScore == 0) return 'E';
  final value = totalScore == totalScore.roundToDouble()
      ? totalScore.toInt().toString()
      : totalScore.toStringAsFixed(1);
  return totalScore > 0 ? '+$value' : value;
}
