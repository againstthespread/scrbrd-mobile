import 'espn_fantasy_client.dart';
import 'fantasy_league_config.dart';
import 'fantasy_provider_models.dart';

class EspnFantasyRepository {
  const EspnFantasyRepository(this.client);
  final EspnFantasyClient client;

  Future<FantasyLeagueDetails> loadLeague({
    required int season,
    required String leagueId,
  }) async => _parseLeague(
    await client.loadLeague(season: season, leagueId: leagueId),
    season: season,
    requestedLeagueId: leagueId,
  );

  Future<FantasyMatchupSnapshot> loadCurrentMatchup({
    required int season,
    required String leagueId,
    required String teamId,
  }) async {
    final league = await loadLeague(season: season, leagueId: leagueId);
    if (!league.teams.any((team) => team.id == teamId)) {
      throw const EspnFantasyException(EspnFantasyFailure.teamUnavailable);
    }
    final json = await client.loadBoxScore(
      season: season,
      leagueId: leagueId,
      scoringPeriod: league.scoringPeriod,
      matchupPeriod: league.matchupPeriod,
    );
    return _parseMatchup(json, league, teamId);
  }
}

FantasyLeagueDetails _parseLeague(
  Map<String, dynamic> json, {
  required int season,
  required String requestedLeagueId,
}) {
  try {
    final id = _id(json['id']);
    if (id != requestedLeagueId) throw const FormatException();
    final status = _map(json['status']);
    // ESPN's top-level scoringPeriodId is the live scoring interval; a
    // matchupPeriodId can span multiple scoring periods. Do not substitute it.
    final scoring = _positiveInt(json['scoringPeriodId']);
    final matchup = _positiveInt(status['currentMatchupPeriod']);
    final teams = _list(json['teams'])
        .map((raw) {
          final team = _map(raw);
          final teamId = _id(team['id']);
          final fullName = _nonempty(team['name']);
          final location = _nonempty(team['location']);
          final nickname = _nonempty(team['nickname']);
          return FantasyTeamDetails(
            id: teamId,
            name:
                fullName ??
                (location != null && nickname != null
                    ? '$location $nickname'
                    : nickname ??
                          location ??
                          _nonempty(team['abbrev']) ??
                          'Team $teamId'),
          );
        })
        .toList(growable: false);
    if (teams.isEmpty ||
        teams.map((t) => t.id).toSet().length != teams.length) {
      throw const FormatException();
    }
    return FantasyLeagueDetails(
      provider: FantasyProvider.espn,
      leagueId: id,
      season: season,
      name: _nonempty(json['name']) ?? 'ESPN league $id',
      scoringPeriod: scoring,
      matchupPeriod: matchup,
      teams: teams,
    );
  } on Object {
    throw const EspnFantasyException(EspnFantasyFailure.invalidResponse);
  }
}

FantasyMatchupSnapshot _parseMatchup(
  Map<String, dynamic> json,
  FantasyLeagueDetails league,
  String teamId,
) {
  try {
    final schedules = _list(json['schedule']);
    final matching = schedules.map(_map).where((schedule) {
      if (_positiveInt(schedule['matchupPeriodId']) != league.matchupPeriod) {
        return false;
      }
      return _sideHasTeam(schedule['home'], teamId) ||
          _sideHasTeam(schedule['away'], teamId);
    }).toList();
    if (matching.isEmpty) {
      throw const EspnFantasyException(EspnFantasyFailure.matchupUnavailable);
    }
    if (matching.length != 1) throw const FormatException();
    final schedule = matching.single;
    final isHome = _sideHasTeam(schedule['home'], teamId);
    final team = _parseSide(
      isHome ? schedule['home'] : schedule['away'],
      league,
    );
    final opponentRaw = isHome ? schedule['away'] : schedule['home'];
    final opponent = opponentRaw == null
        ? null
        : _parseSide(opponentRaw, league);
    return FantasyMatchupSnapshot(
      league: league,
      team: team,
      opponent: opponent,
    );
  } on EspnFantasyException {
    rethrow;
  } on Object {
    throw const EspnFantasyException(EspnFantasyFailure.invalidResponse);
  }
}

bool _sideHasTeam(Object? value, String teamId) {
  if (value == null) return false;
  final side = _map(value);
  return _id(side['teamId']) == teamId;
}

FantasyScoringTeam _parseSide(Object? value, FantasyLeagueDetails league) {
  final side = _map(value);
  final teamId = _id(side['teamId']);
  final teams = league.teams.where((team) => team.id == teamId);
  if (teams.isEmpty) throw const FormatException();
  final points = side['totalPointsLive'] ?? side['totalPoints'];
  final total = _finite(points);
  final entries = _list(_map(side['rosterForCurrentScoringPeriod'])['entries']);
  final starters = <FantasyScoringPlayer>[];
  final seen = <String>{};
  for (final raw in entries) {
    final entry = _map(raw);
    final slot = _positiveOrZeroInt(entry['lineupSlotId']);
    // ESPN football: 20=bench, 21=IR, 22=unassigned. Supported active
    // scoring slots are 0..19 and 23 (flex); unknown slots fail closed.
    if (!(slot <= 19 || slot == 23)) continue;
    final playerId = _id(entry['playerId']);
    if (!seen.add(playerId)) throw const FormatException();
    final player = _map(_map(entry['playerPoolEntry'])['player']);
    final playerIdentity = _id(player['id']);
    if (playerIdentity != playerId) throw const FormatException();
    final stats = player['stats'];
    double currentPoints = 0;
    if (stats != null) {
      for (final rawStat in _list(stats)) {
        final stat = _map(rawStat);
        if (stat['scoringPeriodId'] == league.scoringPeriod &&
            stat['statSourceId'] == 0) {
          currentPoints = _finite(stat['appliedTotal']);
          break;
        }
      }
    }
    starters.add(
      FantasyScoringPlayer(
        id: playerId,
        name: _nonempty(player['fullName']) ?? 'Player $playerId',
        points: currentPoints,
      ),
    );
  }
  return FantasyScoringTeam(
    team: teams.first,
    totalPoints: total,
    starters: List.unmodifiable(starters),
  );
}

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : throw const FormatException();
List<dynamic> _list(Object? value) =>
    value is List<dynamic> ? value : throw const FormatException();
String _id(Object? value) {
  final result = value is int
      ? value.toString()
      : value is String
      ? value
      : null;
  if (result == null ||
      int.tryParse(result) == null ||
      int.parse(result) <= 0) {
    throw const FormatException();
  }
  return result;
}

int _positiveInt(Object? value) {
  final result = _positiveOrZeroInt(value);
  if (result <= 0) throw const FormatException();
  return result;
}

int _positiveOrZeroInt(Object? value) =>
    value is int && value >= 0 ? value : throw const FormatException();
double _finite(Object? value) {
  if (value is! num || !value.toDouble().isFinite) {
    throw const FormatException();
  }
  return value.toDouble();
}

String? _nonempty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
