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
