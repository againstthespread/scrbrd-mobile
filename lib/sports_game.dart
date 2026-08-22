class SportsGame {
  const SportsGame({
    required this.league,
    required this.awayTeam,
    required this.homeTeam,
    required this.awayScore,
    required this.homeScore,
    required this.status,
    required this.clock,
    this.statusDetail,
    this.scheduledStartTime,
    this.eventId,
    this.baseballState,
    this.footballState,
  });

  final String league;
  final String awayTeam;
  final String homeTeam;
  final int awayScore;
  final int homeScore;
  final String status;
  final String clock;
  final String? statusDetail;
  final DateTime? scheduledStartTime;
  final String? eventId;
  final BaseballGameState? baseballState;
  final FootballGameState? footballState;
}

enum FootballPossession { away, home }

class FootballGameState {
  const FootballGameState({
    required this.possession,
    required this.down,
    required this.distance,
    required this.isGoalToGo,
  });

  final FootballPossession possession;
  final int down;
  final int distance;
  final bool isGoalToGo;
}

class BaseballGameState {
  const BaseballGameState({
    required this.runnerOnFirst,
    required this.runnerOnSecond,
    required this.runnerOnThird,
    required this.outs,
  });

  final bool runnerOnFirst;
  final bool runnerOnSecond;
  final bool runnerOnThird;
  final int outs;
}
