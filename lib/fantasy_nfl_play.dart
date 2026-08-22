enum FantasyNflPlayType {
  pass,
  rush,
  reception,
  touchdown,
  fieldGoal,
  extraPoint,
  twoPointConversion,
  interception,
  fumble,
  sack,
  safety,
  punt,
  kickoff,
  penalty,
  other,
}

class FantasyNflPlayParticipant {
  const FantasyNflPlayParticipant({
    required this.espnAthleteId,
    required this.displayName,
    required this.role,
    required this.team,
  });

  final String? espnAthleteId;
  final String? displayName;
  final String? role;
  final String? team;
}

class FantasyNflPlay {
  const FantasyNflPlay({
    required this.playId,
    required this.gameId,
    required this.description,
    required this.possessionTeam,
    required this.yards,
    required this.type,
    required this.wallClock,
    required this.quarter,
    required this.gameClock,
    required this.isScoringPlay,
    required this.participants,
    required this.usesFallbackIdentity,
  });

  final String playId;
  final String gameId;
  final String description;
  final String? possessionTeam;
  final int? yards;
  final FantasyNflPlayType type;
  final DateTime? wallClock;
  final int? quarter;
  final String? gameClock;
  final bool isScoringPlay;
  final List<FantasyNflPlayParticipant> participants;
  final bool usesFallbackIdentity;
}

class FantasyNflGame {
  const FantasyNflGame({
    required this.gameId,
    required this.state,
    required this.homeTeam,
    required this.awayTeam,
  });

  final String gameId;
  final String state;
  final String? homeTeam;
  final String? awayTeam;

  bool get isComplete => state == 'post';
}
