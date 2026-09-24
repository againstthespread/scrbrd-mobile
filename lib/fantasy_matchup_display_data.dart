import 'sleeper_models.dart';
import 'fantasy_provider_models.dart';
import 'utf8_display_text.dart';

enum FantasyMatchupDisplayStatus {
  upcoming('UPCOMING'),
  live('LIVE'),
  finalStatus('FINAL');

  const FantasyMatchupDisplayStatus(this.wireValue);
  final String wireValue;
}

class FantasyMatchupDisplayData {
  const FantasyMatchupDisplayData({
    required this.leagueName,
    required this.userName,
    required this.userScore,
    required this.opponentName,
    required this.opponentScore,
    required this.week,
    required this.status,
    this.userProjectedScore,
    this.opponentProjectedScore,
  });

  factory FantasyMatchupDisplayData.fromSleeper(SleeperFantasyMatchup matchup) {
    final leagueStatus = matchup.league.status.trim().toLowerCase();
    final hasScoring =
        matchup.team.matchup.points != 0 ||
        matchup.opponent.matchup.points != 0 ||
        matchup.team.matchup.playerPoints.values.any((value) => value != 0) ||
        matchup.opponent.matchup.playerPoints.values.any((value) => value != 0);
    final status = leagueStatus == 'complete'
        ? FantasyMatchupDisplayStatus.finalStatus
        : hasScoring
        ? FantasyMatchupDisplayStatus.live
        : FantasyMatchupDisplayStatus.upcoming;
    return FantasyMatchupDisplayData(
      leagueName: truncateUtf8DisplayText(matchup.league.name, 48),
      userName: truncateUtf8DisplayText(matchup.team.name, 20),
      userScore: matchup.team.matchup.points,
      opponentName: truncateUtf8DisplayText(matchup.opponent.name, 20),
      opponentScore: matchup.opponent.matchup.points,
      userProjectedScore: matchup.team.projectedTotalPoints,
      opponentProjectedScore: matchup.opponent.projectedTotalPoints,
      week: matchup.week,
      status: status,
    );
  }

  factory FantasyMatchupDisplayData.fromNormalized(
    FantasyMatchupSnapshot matchup,
  ) {
    final opponent = matchup.opponent;
    final hasScoring =
        matchup.team.totalPoints != 0 || (opponent?.totalPoints ?? 0) != 0;
    return FantasyMatchupDisplayData(
      leagueName: truncateUtf8DisplayText(matchup.league.name, 48),
      userName: truncateUtf8DisplayText(matchup.team.team.name, 20),
      userScore: matchup.team.totalPoints,
      opponentName: truncateUtf8DisplayText(opponent?.team.name ?? 'BYE', 20),
      opponentScore: opponent?.totalPoints ?? 0,
      userProjectedScore: matchup.team.projectedTotalPoints,
      opponentProjectedScore: opponent?.projectedTotalPoints,
      week: matchup.matchupPeriod,
      status: hasScoring
          ? FantasyMatchupDisplayStatus.live
          : FantasyMatchupDisplayStatus.upcoming,
    );
  }

  final String leagueName;
  final String userName;
  final double userScore;
  final String opponentName;
  final double opponentScore;
  final double? userProjectedScore;
  final double? opponentProjectedScore;
  final int week;
  final FantasyMatchupDisplayStatus status;

  @override
  bool operator ==(Object other) =>
      other is FantasyMatchupDisplayData &&
      leagueName == other.leagueName &&
      userName == other.userName &&
      userScore == other.userScore &&
      opponentName == other.opponentName &&
      opponentScore == other.opponentScore &&
      userProjectedScore == other.userProjectedScore &&
      opponentProjectedScore == other.opponentProjectedScore &&
      week == other.week &&
      status == other.status;

  @override
  int get hashCode => Object.hash(
    leagueName,
    userName,
    userScore,
    opponentName,
    opponentScore,
    userProjectedScore,
    opponentProjectedScore,
    week,
    status,
  );
}
