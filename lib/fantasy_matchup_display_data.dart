import 'sleeper_models.dart';
import 'fantasy_provider_models.dart';
import 'utf8_display_text.dart';
import 'fantasy_matchup_status.dart';

export 'fantasy_matchup_status.dart';

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
    final status = leagueStatus == 'complete'
        ? FantasyMatchupDisplayStatus.finalStatus
        : matchup.status ?? FantasyMatchupDisplayStatus.upcoming;
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
    return FantasyMatchupDisplayData(
      leagueName: truncateUtf8DisplayText(matchup.league.name, 48),
      userName: truncateUtf8DisplayText(matchup.team.team.name, 20),
      userScore: matchup.team.totalPoints,
      opponentName: truncateUtf8DisplayText(opponent?.team.name ?? 'BYE', 20),
      opponentScore: opponent?.totalPoints ?? 0,
      userProjectedScore: matchup.team.projectedTotalPoints,
      opponentProjectedScore: opponent?.projectedTotalPoints,
      week: matchup.matchupPeriod,
      status: matchup.status ?? FantasyMatchupDisplayStatus.upcoming,
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
