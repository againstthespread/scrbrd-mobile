class SleeperLeague {
  const SleeperLeague({
    required this.leagueId,
    required this.name,
    required this.season,
    required this.status,
    required this.scoringSettings,
    required this.rosterPositions,
  });

  factory SleeperLeague.fromJson(Map<String, dynamic> json) {
    return SleeperLeague(
      leagueId: _requiredString(json, 'league_id'),
      name: _requiredString(json, 'name'),
      season: _string(json['season']),
      status: _string(json['status']),
      scoringSettings: _numberMap(json['scoring_settings']),
      rosterPositions: _stringList(json['roster_positions']),
    );
  }

  final String leagueId;
  final String name;
  final String season;
  final String status;
  final Map<String, double> scoringSettings;
  final List<String> rosterPositions;
}

class SleeperUser {
  const SleeperUser({
    required this.userId,
    required this.displayName,
    this.teamName,
  });

  factory SleeperUser.fromJson(Map<String, dynamic> json) {
    final metadata = _map(json['metadata']);
    final teamName = _nullableString(metadata?['team_name']);
    return SleeperUser(
      userId: _requiredString(json, 'user_id'),
      displayName: _requiredString(json, 'display_name'),
      teamName: teamName,
    );
  }

  final String userId;
  final String displayName;
  final String? teamName;

  String get label => teamName ?? displayName;
}

class SleeperRoster {
  const SleeperRoster({
    required this.rosterId,
    required this.ownerId,
    required this.players,
    required this.starters,
  });

  factory SleeperRoster.fromJson(Map<String, dynamic> json) {
    return SleeperRoster(
      rosterId: _requiredInt(json, 'roster_id'),
      ownerId: _nullableString(json['owner_id']),
      players: _stringList(json['players']),
      starters: _stringList(json['starters']),
    );
  }

  final int rosterId;
  final String? ownerId;
  final List<String> players;
  final List<String> starters;
}

class SleeperMatchup {
  const SleeperMatchup({
    required this.rosterId,
    required this.matchupId,
    required this.points,
    required this.starters,
    required this.playerPoints,
  });

  factory SleeperMatchup.fromJson(Map<String, dynamic> json) {
    final starters = _stringList(json['starters']);
    final playerPoints = _numberMap(json['players_points']);
    final starterPoints = json['starters_points'];
    if (playerPoints.isEmpty && starterPoints is List) {
      for (
        var index = 0;
        index < starters.length && index < starterPoints.length;
        index++
      ) {
        final points = starterPoints[index];
        if (points is num) playerPoints[starters[index]] = points.toDouble();
      }
    }
    return SleeperMatchup(
      rosterId: _requiredInt(json, 'roster_id'),
      matchupId: _nullableInt(json['matchup_id']),
      points:
          _nullableDouble(json['custom_points']) ??
          _nullableDouble(json['points']) ??
          0,
      starters: starters,
      playerPoints: playerPoints,
    );
  }

  final int rosterId;
  final int? matchupId;
  final double points;
  final List<String> starters;
  final Map<String, double> playerPoints;
}

class SleeperNflState {
  const SleeperNflState({required this.week, required this.season});

  factory SleeperNflState.fromJson(Map<String, dynamic> json) {
    final week = _nullableInt(json['week']) ?? _nullableInt(json['leg']);
    if (week == null || week < 1) {
      throw const FormatException('Sleeper NFL state has no current week.');
    }
    return SleeperNflState(week: week, season: _string(json['season']));
  }

  final int week;
  final String season;
}

class SleeperFantasyPlayer {
  const SleeperFantasyPlayer({
    required this.sleeperPlayerId,
    required this.fullName,
    required this.firstName,
    required this.lastName,
    required this.position,
    required this.nflTeam,
    required this.espnPlayerId,
  });

  factory SleeperFantasyPlayer.fromJson(
    Map<String, dynamic> json, {
    String? sleeperPlayerId,
  }) {
    final playerId =
        _nullableString(json['player_id']) ?? sleeperPlayerId?.trim();
    if (playerId == null || playerId.isEmpty) {
      throw const FormatException('Missing Sleeper field: player_id');
    }
    final firstName = _nullableString(json['first_name']) ?? '';
    final lastName = _nullableString(json['last_name']) ?? '';
    final suppliedFullName = _nullableString(json['full_name']);
    final derivedFullName = [
      firstName,
      lastName,
    ].where((part) => part.isNotEmpty).join(' ');
    return SleeperFantasyPlayer(
      sleeperPlayerId: playerId,
      fullName:
          suppliedFullName ??
          (derivedFullName.isEmpty ? playerId : derivedFullName),
      firstName: firstName,
      lastName: lastName,
      position: _nullableString(json['position']),
      nflTeam: _nullableString(json['team']),
      espnPlayerId: _nullableString(json['espn_id']),
    );
  }

  final String sleeperPlayerId;
  final String fullName;
  final String firstName;
  final String lastName;
  final String? position;
  final String? nflTeam;
  final String? espnPlayerId;

  Map<String, Object?> toJson() => {
    'player_id': sleeperPlayerId,
    'full_name': fullName,
    'first_name': firstName,
    'last_name': lastName,
    'position': position,
    'team': nflTeam,
    'espn_id': espnPlayerId,
  };
}

class SleeperStarterPoints {
  const SleeperStarterPoints({required this.playerId, required this.points});

  final String playerId;
  final double? points;
}

class SleeperFantasyTeam {
  const SleeperFantasyTeam({
    required this.roster,
    required this.user,
    required this.matchup,
  });

  final SleeperRoster roster;
  final SleeperUser? user;
  final SleeperMatchup matchup;

  String get name => user?.label ?? 'Roster ${roster.rosterId}';

  List<SleeperStarterPoints> get starters => matchup.starters
      .map(
        (playerId) => SleeperStarterPoints(
          playerId: playerId,
          points: matchup.playerPoints[playerId],
        ),
      )
      .toList(growable: false);
}

class SleeperFantasyMatchup {
  const SleeperFantasyMatchup({
    required this.league,
    required this.week,
    required this.team,
    required this.opponent,
  });

  final SleeperLeague league;
  final int week;
  final SleeperFantasyTeam team;
  final SleeperFantasyTeam opponent;
}

Map<String, dynamic>? _map(Object? value) =>
    value is Map<String, dynamic> ? value : null;

String _requiredString(Map<String, dynamic> json, String key) {
  final value = _nullableString(json[key]);
  if (value == null) throw FormatException('Missing Sleeper field: $key');
  return value;
}

String _string(Object? value) => value?.toString() ?? '';

String? _nullableString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = _nullableInt(json[key]);
  if (value == null) throw FormatException('Missing Sleeper field: $key');
  return value;
}

int? _nullableInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

double? _nullableDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

List<String> _stringList(Object? value) => value is List
    ? value.map((item) => item.toString()).toList(growable: false)
    : const [];

Map<String, double> _numberMap(Object? value) {
  if (value is! Map) return <String, double>{};
  final result = <String, double>{};
  for (final entry in value.entries) {
    final points = _nullableDouble(entry.value);
    if (points != null) result[entry.key.toString()] = points;
  }
  return result;
}
