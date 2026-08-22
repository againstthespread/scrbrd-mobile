import 'sleeper_models.dart';

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
      leagueName: matchup.league.name,
      userName: matchup.team.name,
      userScore: matchup.team.matchup.points,
      opponentName: matchup.opponent.name,
      opponentScore: matchup.opponent.matchup.points,
      week: matchup.week,
      status: status,
    );
  }

  final String leagueName;
  final String userName;
  final double userScore;
  final String opponentName;
  final double opponentScore;
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
      week == other.week &&
      status == other.status;

  @override
  int get hashCode => Object.hash(
    leagueName,
    userName,
    userScore,
    opponentName,
    opponentScore,
    week,
    status,
  );
}
