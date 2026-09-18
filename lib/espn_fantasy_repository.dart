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
  var stage = 'id';
  try {
    final id = _id(json['id']);
    if (id != requestedLeagueId) {
      stage = 'id-mismatch';
      throw const FormatException();
    }
    stage = 'status';
    final status = _map(json['status']);
    // ESPN's top-level scoringPeriodId is the live scoring interval; a
    // matchupPeriodId can span multiple scoring periods. Do not substitute it.
    stage = 'scoringPeriodId';
    final scoring = _positiveInt(json['scoringPeriodId']);
    stage = 'status.currentMatchupPeriod';
    final matchup = _positiveInt(status['currentMatchupPeriod']);
    stage = 'teams';
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
    throw EspnFantasyException(
      EspnFantasyFailure.invalidResponse,
      diagnostic: 'league.$stage; ${_leagueShape(json)}',
    );
  }
}

// Fixed field names and structural types only. Never include response values,
// owner/member data, account identifiers, or request headers.
String _leagueShape(Map<String, dynamic> json) {
  final status = json['status'];
  final settings = json['settings'];
  final teams = json['teams'];
  return 'id=${_shape(json['id'])}, '
      'name=${_shape(json['name'])}, '
      'settings=${_shape(settings)}, '
      'settings.name=${_shape(settings is Map ? settings['name'] : null)}, '
      'status=${_shape(status)}, '
      'status.currentMatchupPeriod='
      '${_shape(status is Map ? status['currentMatchupPeriod'] : null)}, '
      'scoringPeriodId=${_shape(json['scoringPeriodId'])}, '
      'teams=${_shape(teams)}'
      '${teams is List ? '(${teams.length})' : ''}';
}

String _shape(Object? value) => switch (value) {
  null => 'null',
  Map() => 'map',
  List() => 'list',
  String() => 'string',
  num() => 'number',
  bool() => 'boolean',
  _ => 'other',
};

FantasyMatchupSnapshot _parseMatchup(
  Map<String, dynamic> json,
  FantasyLeagueDetails league,
  String teamId,
) {
  var stage = 'schedule';
  try {
    final schedules = _list(json['schedule']);
    stage = 'schedule.matchupPeriodId';
    final matching = schedules.map(_map).where((schedule) {
      if (_positiveInt(schedule['matchupPeriodId']) != league.matchupPeriod) {
        return false;
      }
      return _sideHasTeam(schedule['home'], teamId) ||
          _sideHasTeam(schedule['away'], teamId);
    }).toList();
    if (matching.isEmpty) {
      throw EspnFantasyException(
        EspnFantasyFailure.matchupUnavailable,
        diagnostic:
            'matchup.no-current-team; '
            '${_matchupShape(json, league, teamId)}',
      );
    }
    stage = 'schedule.duplicate-current-team';
    if (matching.length != 1) throw const FormatException();
    final schedule = matching.single;
    stage = 'schedule.home-away';
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
    throw EspnFantasyException(
      EspnFantasyFailure.invalidResponse,
      diagnostic: 'matchup.$stage; ${_matchupShape(json, league, teamId)}',
    );
  }
}

String _matchupShape(
  Map<String, dynamic> json,
  FantasyLeagueDetails league,
  String teamId,
) {
  final schedule = json['schedule'];
  var periodEntries = 0;
  var teamEntries = 0;
  if (schedule is List) {
    for (final raw in schedule) {
      if (raw is! Map) continue;
      if (raw['matchupPeriodId'] != league.matchupPeriod) continue;
      periodEntries++;
      for (final side in [raw['home'], raw['away']]) {
        if (side is Map && side['teamId']?.toString() == teamId) {
          teamEntries++;
        }
      }
    }
  }
  return 'schedule=${_shape(schedule)}'
      '${schedule is List ? '(${schedule.length})' : ''}, '
      'currentPeriodEntries=$periodEntries, selectedTeamEntries=$teamEntries, '
      'scoringPeriodId=${_shape(json['scoringPeriodId'])}, '
      'status=${_shape(json['status'])}, teams=${_shape(json['teams'])}';
}

bool _sideHasTeam(Object? value, String teamId) {
  if (value == null) return false;
  final side = _map(value);
  return _id(side['teamId']) == teamId;
}

FantasyScoringTeam _parseSide(Object? value, FantasyLeagueDetails league) {
  var stage = 'teamId';
  var entryIndex = -1;
  Object? currentEntry;
  try {
    final side = _map(value);
    final teamId = _id(side['teamId']);
    final teams = league.teams.where((team) => team.id == teamId);
    if (teams.isEmpty) throw const FormatException();
    stage = 'totalPoints';
    final points = side['totalPointsLive'] ?? side['totalPoints'];
    final total = _finite(points);
    stage = 'rosterForCurrentScoringPeriod.entries';
    final entries = _list(
      _map(side['rosterForCurrentScoringPeriod'])['entries'],
    );
    final starters = <FantasyScoringPlayer>[];
    final seen = <String>{};
    for (final raw in entries) {
      entryIndex++;
      currentEntry = raw;
      stage = 'entry.lineupSlotId';
      final entry = _map(raw);
      final slot = _positiveOrZeroInt(entry['lineupSlotId']);
      // ESPN football: 20=bench, 21=IR, 22=unassigned. Supported active
      // scoring slots are 0..19 and 23 (flex); unknown slots fail closed.
      if (!(slot <= 19 || slot == 23)) continue;
      stage = 'entry.playerId';
      final playerId = _playerId(entry['playerId']);
      if (!seen.add(playerId)) {
        stage = 'entry.duplicatePlayerId';
        throw const FormatException();
      }
      stage = 'entry.playerPoolEntry.player';
      final player = _map(_map(entry['playerPoolEntry'])['player']);
      final playerIdentity = _playerId(player['id']);
      if (playerIdentity != playerId) throw const FormatException();
      final stats = player['stats'];
      double currentPoints = 0;
      if (stats != null) {
        stage = 'entry.player.stats';
        for (final rawStat in _list(stats)) {
          final stat = _map(rawStat);
          if (stat['scoringPeriodId'] == league.scoringPeriod &&
              stat['statSourceId'] == 0) {
            stage = 'entry.player.stats.appliedTotal';
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
  } on Object {
    throw EspnFantasyException(
      EspnFantasyFailure.invalidResponse,
      diagnostic:
          'matchup.side.$stage'
          '${entryIndex >= 0 ? '[$entryIndex]' : ''}; '
          '${_sideShape(value)}; ${_entryShape(currentEntry)}',
    );
  }
}

String _entryShape(Object? value) {
  if (value is! Map) return 'failedEntry=${_shape(value)}';
  final pool = value['playerPoolEntry'];
  final player = pool is Map ? pool['player'] : null;
  return 'failedEntry.slot=${_shape(value['lineupSlotId'])}, '
      'playerId=${_idCategory(value['playerId'])}, '
      'player.id=${_idCategory(player is Map ? player['id'] : null)}, '
      'pool=${_shape(pool)}, player=${_shape(player)}';
}

String _idCategory(Object? value) {
  final parsed = value is int
      ? value
      : value is String
      ? int.tryParse(value)
      : null;
  if (parsed == null) return _shape(value);
  return parsed < 0
      ? 'negative'
      : parsed == 0
      ? 'zero'
      : 'positive';
}

String _sideShape(Object? value) {
  if (value is! Map) return 'side=${_shape(value)}';
  final roster = value['rosterForCurrentScoringPeriod'];
  final entries = roster is Map ? roster['entries'] : null;
  final first = entries is List && entries.isNotEmpty ? entries.first : null;
  final pool = first is Map ? first['playerPoolEntry'] : null;
  final player = pool is Map ? pool['player'] : null;
  final stats = player is Map ? player['stats'] : null;
  return 'teamId=${_shape(value['teamId'])}, '
      'totalPointsLive=${_shape(value['totalPointsLive'])}, '
      'totalPoints=${_shape(value['totalPoints'])}, '
      'roster=${_shape(roster)}, entries=${_shape(entries)}'
      '${entries is List ? '(${entries.length})' : ''}, '
      'firstEntry.slot=${_shape(first is Map ? first['lineupSlotId'] : null)}, '
      'firstEntry.playerId=${_shape(first is Map ? first['playerId'] : null)}, '
      'firstEntry.pool=${_shape(pool)}, player=${_shape(player)}, '
      'player.stats=${_shape(stats)}'
      '${stats is List ? '(${stats.length})' : ''}';
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

// ESPN uses negative entity IDs for D/ST. Keep them signed and stable; league
// and fantasy-team IDs continue to use the positive-only _id validator.
String _playerId(Object? value) {
  final result = value is int
      ? value.toString()
      : value is String
      ? value
      : null;
  if (result == null ||
      int.tryParse(result) == null ||
      int.parse(result) == 0) {
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
