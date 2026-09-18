import 'fantasy_league_config.dart';

/// Provider-independent output for a future shared observation runtime.
class FantasyLeagueDetails {
  const FantasyLeagueDetails({
    required this.provider,
    required this.leagueId,
    required this.season,
    required this.name,
    required this.scoringPeriod,
    required this.matchupPeriod,
    required this.teams,
  });
  final FantasyProvider provider;
  final String leagueId;
  final int season;
  final String name;

  /// Live scoring period, which may differ from a multi-week matchup period.
  final int scoringPeriod;
  final int matchupPeriod;
  final List<FantasyTeamDetails> teams;
  String get id => '${provider.name}:$leagueId';
}

class FantasyTeamDetails {
  const FantasyTeamDetails({required this.id, required this.name});
  final String id;
  final String name;
}

class FantasyScoringPlayer {
  const FantasyScoringPlayer({
    required this.id,
    required this.name,
    required this.points,
  });
  final String id;
  final String name;
  final double points;
}

class FantasyScoringTeam {
  const FantasyScoringTeam({
    required this.team,
    required this.totalPoints,
    required this.starters,
  });
  final FantasyTeamDetails team;
  final double totalPoints;

  /// Only active scoring lineup players; bench and IR are omitted.
  final List<FantasyScoringPlayer> starters;
}

class FantasyMatchupSnapshot {
  const FantasyMatchupSnapshot({
    required this.league,
    required this.team,
    required this.opponent,
  });
  final FantasyLeagueDetails league;
  final FantasyScoringTeam team;

  /// Null for an ESPN bye or matchup without an opponent.
  final FantasyScoringTeam? opponent;
  String get id => league.id;
  int get scoringPeriod => league.scoringPeriod;
  int get matchupPeriod => league.matchupPeriod;
}
