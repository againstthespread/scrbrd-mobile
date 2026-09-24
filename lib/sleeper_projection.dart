import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

import 'sleeper_api_client.dart';
import 'sleeper_models.dart';
import 'sports_league.dart';
import 'sports_repository.dart';
import 'team_catalog.dart';

enum SleeperNflGamePhase { upcoming, live, finalStatus }

abstract interface class SleeperNflGameStatusSource {
  Future<Map<String, SleeperNflGamePhase>> statusesForDates(
    Iterable<DateTime> dates,
  );
}

class SportsRepositorySleeperNflGameStatusSource
    implements SleeperNflGameStatusSource {
  SportsRepositorySleeperNflGameStatusSource(
    this.repository, {
    DateTime Function()? now,
    this.liveRefreshInterval = const Duration(seconds: 15),
    this.pastRefreshInterval = const Duration(minutes: 5),
    this.futureRefreshInterval = const Duration(hours: 1),
  }) : _now = now ?? DateTime.now;

  final SportsRepository repository;
  final DateTime Function() _now;
  final Duration liveRefreshInterval;
  final Duration pastRefreshInterval;
  final Duration futureRefreshInterval;
  final Map<String, _CachedNflDate> _cache = {};

  @override
  Future<Map<String, SleeperNflGamePhase>> statusesForDates(
    Iterable<DateTime> dates,
  ) async {
    final uniqueDates = {
      for (final date in dates) DateTime(date.year, date.month, date.day),
    };
    await Future.wait([
      for (final date in uniqueDates)
        if (_needsRefresh(date)) _refreshDateSafely(date),
    ]);
    return Map.unmodifiable({
      for (final date in uniqueDates) ...?_cache[_dateKey(date)]?.statuses,
    });
  }

  bool _needsRefresh(DateTime date) {
    final cached = _cache[_dateKey(date)];
    if (cached == null) return true;
    if (cached.statuses.isNotEmpty &&
        cached.statuses.values.every(
          (status) => status == SleeperNflGamePhase.finalStatus,
        )) {
      return false;
    }
    final now = _now();
    final today = DateTime(now.year, now.month, now.day);
    final interval = date.isAfter(today)
        ? futureRefreshInterval
        : date.isBefore(today)
        ? pastRefreshInterval
        : liveRefreshInterval;
    return now.difference(cached.fetchedAt) >= interval;
  }

  Future<void> _refreshDateSafely(DateTime date) async {
    try {
      final games = await repository.fetchGamesForDate(SportsLeague.nfl, date);
      final statuses = <String, SleeperNflGamePhase>{};
      for (final game in games) {
        final phase = switch (game.status.trim().toUpperCase()) {
          'FINAL' => SleeperNflGamePhase.finalStatus,
          'LIVE' => SleeperNflGamePhase.live,
          _ => SleeperNflGamePhase.upcoming,
        };
        final away = TeamCatalog.canonicalKey(
          SportsLeague.nfl,
          game.awayTeamKey ?? game.awayTeam,
        );
        final home = TeamCatalog.canonicalKey(
          SportsLeague.nfl,
          game.homeTeamKey ?? game.homeTeam,
        );
        if (away != null) statuses[away] = phase;
        if (home != null) statuses[home] = phase;
      }
      _cache[_dateKey(date)] = _CachedNflDate(
        fetchedAt: _now(),
        statuses: Map.unmodifiable(statuses),
      );
    } on Object {
      // Status enrichment is optional; retain any last-known statuses.
    }
  }
}

class _CachedNflDate {
  const _CachedNflDate({required this.fetchedAt, required this.statuses});

  final DateTime fetchedAt;
  final Map<String, SleeperNflGamePhase> statuses;
}

abstract interface class SleeperProjectionSource {
  Future<SleeperPlayerProjection?> fetchPlayerProjection({
    required String playerId,
    required String season,
    required int week,
    required String seasonType,
  });
}

class SleeperApiProjectionSource implements SleeperProjectionSource {
  const SleeperApiProjectionSource(this.client);

  final SleeperApiClient client;

  @override
  Future<SleeperPlayerProjection?> fetchPlayerProjection({
    required String playerId,
    required String season,
    required int week,
    required String seasonType,
  }) => client.fetchNflPlayerProjection(
    playerId: playerId,
    season: season,
    week: week,
    seasonType: seasonType,
  );
}

class SleeperProjectionScorer {
  const SleeperProjectionScorer();

  SleeperProjectionScoreResult evaluate(
    Map<String, double> projectedStats,
    Map<String, double> scoringSettings, {
    String? position,
  }) {
    if (scoringSettings.isEmpty || projectedStats.isEmpty) {
      return const SleeperProjectionScoreResult.unavailable();
    }
    var total = 0.0;
    for (final setting in scoringSettings.entries) {
      if (setting.value == 0) continue;
      if (_isClearlyIrrelevant(setting.key, position)) continue;
      final stat = _statValue(setting.key, projectedStats);
      if (stat != null) {
        total += stat * setting.value;
        continue;
      }
      if (_implicitZeroWhenAbsent.contains(setting.key)) continue;
      return SleeperProjectionScoreResult.unsupported(setting.key);
    }
    return total.isFinite
        ? SleeperProjectionScoreResult.success(total)
        : const SleeperProjectionScoreResult.unavailable();
  }

  double? score(
    Map<String, double> projectedStats,
    Map<String, double> scoringSettings,
  ) => evaluate(projectedStats, scoringSettings).points;

  double? _statValue(String key, Map<String, double> stats) {
    final exact = stats[key];
    if (exact != null) return exact;
    final fieldGoalRatio = _projectedFieldGoalMadeFallbackRatios[key];
    if (fieldGoalRatio != null) {
      final made = stats['fgm'];
      return made == null ? null : made * fieldGoalRatio;
    }
    if (key == 'fgmiss') {
      final bucketTotal = _sumWhenPresent(stats, const [
        'fgmiss_0_19',
        'fgmiss_20_29',
        'fgmiss_30_39',
        'fgmiss_40_49',
        'fgmiss_50p',
      ]);
      if (bucketTotal != null) return bucketTotal;
      final attempts = stats['fga'];
      final made = stats['fgm'];
      return attempts == null || made == null
          ? null
          : math.max(0, attempts - made);
    }
    if (key == 'kr_td') return stats['def_kr_td'];
    if (key == 'kr_yd') return stats['def_kr_yd'];
    if (key == 'st_td') {
      return _sumWhenPresent(stats, const ['def_kr_td', 'pr_td']);
    }
    if (key == 'def_st_td') return stats['st_td'];
    if (key == 'idp_blk') return stats['idp_blk_kick'];
    if (key == 'idp_def_td') {
      // Sleeper's player projection feed currently publishes the aggregate
      // defensive-return touchdown as def_pr_td. The two component fields are
      // an equivalent fallback; do not add them when the aggregate is present.
      final aggregate = stats['def_pr_td'];
      if (aggregate != null) return aggregate;
      return _sumWhenPresent(stats, const ['pass_int_td', 'def_fum_td']);
    }
    final pointsAllowed = stats['pts_allow'];
    if (pointsAllowed != null && _pointsAllowedBuckets.contains(key)) {
      return _matchesPointsAllowedBucket(key, pointsAllowed) ? 1 : 0;
    }
    final yardsAllowed = stats['yds_allow'];
    if (yardsAllowed != null && _yardsAllowedBuckets.contains(key)) {
      return _matchesYardsAllowedBucket(key, yardsAllowed) ? 1 : 0;
    }
    return null;
  }

  double? _sumWhenPresent(Map<String, double> stats, Iterable<String> keys) {
    var found = false;
    var total = 0.0;
    for (final key in keys) {
      final value = stats[key];
      if (value == null) continue;
      found = true;
      total += value;
    }
    return found ? total : null;
  }

  bool _isClearlyIrrelevant(String key, String? rawPosition) {
    final position = rawPosition?.trim().toUpperCase();
    if (position == null || position.isEmpty) return false;
    final isTeamDefense = const {'DEF', 'DST'}.contains(position);
    final isIndividualDefense = const {
      'DL',
      'DE',
      'DT',
      'NT',
      'LB',
      'DB',
      'CB',
      'S',
    }.contains(position);
    final isDefense = isTeamDefense || isIndividualDefense;
    final isOffense = const {'QB', 'RB', 'FB', 'WR', 'TE'}.contains(position);
    final isReceiver = const {'RB', 'FB', 'WR', 'TE'}.contains(position);
    final isIndividualReturner = const {
      'RB',
      'FB',
      'WR',
      'TE',
      'CB',
      'DB',
      'S',
    }.contains(position);

    if (_startsWithAny(key, const ['fg', 'xp'])) return position != 'K';
    if (_startsWithAny(key, const ['pass_', 'bonus_pass_'])) {
      return position != 'QB';
    }
    if (_startsWithAny(key, const ['rush_', 'bonus_rush_'])) {
      return !isOffense;
    }
    if (_startsWithAny(key, const ['rec_', 'bonus_rec_'])) {
      return !isReceiver;
    }
    if (_startsWithAny(key, const ['kr_', 'pr_', 'return_'])) {
      return !isIndividualReturner;
    }
    if (key.startsWith('st_')) return !isIndividualReturner;
    if (key.startsWith('def_') ||
        _pointsAllowedBuckets.contains(key) ||
        _yardsAllowedBuckets.contains(key)) {
      return !isTeamDefense;
    }
    if (key.startsWith('idp_')) return !isIndividualDefense;
    if (_defenseOnlyStats.contains(key)) return !isDefense;
    if (key == 'fum_rec_td') return isDefense;
    return false;
  }

  bool _startsWithAny(String value, Iterable<String> prefixes) =>
      prefixes.any(value.startsWith);

  bool _matchesPointsAllowedBucket(String key, double value) => switch (key) {
    'pts_allow_0' => value == 0,
    'pts_allow_1_6' => value >= 1 && value <= 6,
    'pts_allow_7_13' => value >= 7 && value <= 13,
    'pts_allow_14_20' => value >= 14 && value <= 20,
    'pts_allow_21_27' => value >= 21 && value <= 27,
    'pts_allow_28_34' => value >= 28 && value <= 34,
    'pts_allow_35p' => value >= 35,
    _ => false,
  };

  bool _matchesYardsAllowedBucket(String key, double value) => switch (key) {
    'yds_allow_0_100' => value < 100,
    'yds_allow_100_199' => value >= 100 && value < 200,
    'yds_allow_200_299' => value >= 200 && value < 300,
    'yds_allow_300_349' => value >= 300 && value < 350,
    'yds_allow_350_399' => value >= 350 && value < 400,
    'yds_allow_400_449' => value >= 400 && value < 450,
    'yds_allow_450_499' => value >= 450 && value < 500,
    'yds_allow_500_549' => value >= 500 && value < 550,
    'yds_allow_550p' => value >= 550,
    _ => false,
  };

  static const _pointsAllowedBuckets = {
    'pts_allow_0',
    'pts_allow_1_6',
    'pts_allow_7_13',
    'pts_allow_14_20',
    'pts_allow_21_27',
    'pts_allow_28_34',
    'pts_allow_35p',
  };

  static const _yardsAllowedBuckets = {
    'yds_allow_0_100',
    'yds_allow_100_199',
    'yds_allow_200_299',
    'yds_allow_300_349',
    'yds_allow_350_399',
    'yds_allow_400_449',
    'yds_allow_450_499',
    'yds_allow_500_549',
    'yds_allow_550p',
  };

  // Sleeper's own projection scorer synthesizes a missing made-FG distance
  // bucket from total projected FGM using these ratios. Exact bucket values
  // always win above. The legacy 50+ bucket and the newer 50-59/60+ buckets
  // remain independent because Sleeper allows intentional stacking.
  static const _projectedFieldGoalMadeFallbackRatios = <String, double>{
    'fgm_0_19': 0.25,
    'fgm_20_29': 0.30,
    'fgm_30_39': 0.30,
    'fgm_40_49': 0.11,
    'fgm_50_59': 0.04,
    'fgm_50p': 0.04,
    'fgm_60p': 0.03,
  };

  static const _defenseOnlyStats = {
    'blk_kick',
    'ff',
    'fum_rec',
    'int',
    'pass_def',
    'qb_hit',
    'sack',
    'safe',
    'tkl',
    'tkl_ast',
    'tkl_loss',
    'tkl_solo',
  };

  // Sleeper omits these known counting stats when the projection is zero.
  // Unknown settings remain unsupported; this list is deliberately explicit.
  static const _implicitZeroWhenAbsent = {
    'blk_kick',
    'bonus_rec_rb',
    'bonus_rec_te',
    'bonus_rec_wr',
    'bonus_rush_td_qb',
    'def_fum_td',
    'def_2pt',
    'def_kr_td',
    'def_kr_yd',
    'def_pr_td',
    'def_pr_yd',
    'def_st_ff',
    'def_st_fum_rec',
    'def_st_td',
    'def_td',
    'ff',
    'fga',
    'fgm',
    'fgm_0_19',
    'fgm_20_29',
    'fgm_30_39',
    'fgm_40_49',
    'fgm_50_59',
    'fgm_50p',
    'fgm_60p',
    'fgm_yds',
    'fgmiss_0_19',
    'fgmiss_20_29',
    'fgmiss_30_39',
    'fgmiss_40_49',
    'fgmiss_50_59',
    'fgmiss_50p',
    'fgmiss_60p',
    'fum',
    'fum_lost',
    'fum_rec',
    'fum_rec_td',
    'idp_blk',
    'idp_blk_kick',
    'idp_def_td',
    'idp_ff',
    'idp_fum_rec',
    'idp_fum_ret_yd',
    'idp_int',
    'idp_int_ret_yd',
    'idp_pass_def',
    'idp_qb_hit',
    'idp_sack',
    'idp_sack_yd',
    'idp_safe',
    'idp_tkl',
    'idp_tkl_ast',
    'idp_tkl_loss',
    'idp_tkl_solo',
    'int',
    'kr_td',
    'kr_yd',
    'pass_2pt',
    'pass_att',
    'pass_cmp',
    'pass_cmp_40p',
    'pass_fd',
    'pass_inc',
    'pass_int',
    'pass_int_td',
    'pass_sack',
    'pass_td',
    'pass_yd',
    'pr',
    'pr_td',
    'pr_yd',
    'pts_allow',
    'rec',
    'rec_0_4',
    'rec_10_19',
    'rec_20_29',
    'rec_2pt',
    'rec_30_39',
    'rec_40p',
    'rec_5_9',
    'rec_fd',
    'rec_td',
    'rec_tgt',
    'rec_yd',
    'rush_2pt',
    'rush_40p',
    'rush_att',
    'rush_fd',
    'rush_td',
    'rush_yd',
    'sack',
    'safe',
    'st_td',
    'st_ff',
    'st_fum_rec',
    'st_tkl_solo',
    'tkl_loss',
    'xpa',
    'xpm',
    'xpmiss',
    'yds_allow',
  };
}

class SleeperProjectionScoreResult {
  const SleeperProjectionScoreResult.success(this.points)
    : unsupportedScoringKey = null;

  const SleeperProjectionScoreResult.unsupported(this.unsupportedScoringKey)
    : points = null;

  const SleeperProjectionScoreResult.unavailable()
    : points = null,
      unsupportedScoringKey = null;

  final double? points;
  final String? unsupportedScoringKey;
}

class SleeperProjectionBaseline {
  const SleeperProjectionBaseline({
    required this.points,
    required this.nflTeam,
    required this.gameDate,
  });

  factory SleeperProjectionBaseline.fromJson(Map<String, dynamic> json) {
    final points = json['points'];
    final team = json['nflTeam'];
    final date = DateTime.tryParse(json['gameDate']?.toString() ?? '');
    if (points is! num ||
        !points.isFinite ||
        team is! String ||
        team.trim().isEmpty ||
        date == null) {
      throw const FormatException('Invalid Sleeper projection baseline.');
    }
    return SleeperProjectionBaseline(
      points: points.toDouble(),
      nflTeam: team.trim(),
      gameDate: DateTime(date.year, date.month, date.day),
    );
  }

  final double points;
  final String nflTeam;
  final DateTime gameDate;

  Map<String, Object> toJson() => {
    'points': points,
    'nflTeam': nflTeam,
    'gameDate': _dateKey(gameDate),
  };
}

class SleeperLeagueProjectionBaselines {
  const SleeperLeagueProjectionBaselines({
    required this.scoringSignature,
    required this.players,
  });

  final String scoringSignature;
  final Map<String, SleeperProjectionBaseline> players;
}

class SleeperProjectionBaselineSnapshot {
  const SleeperProjectionBaselineSnapshot({
    required this.season,
    required this.seasonType,
    required this.week,
    required this.leagues,
  });

  final String season;
  final String seasonType;
  final int week;
  final Map<String, SleeperLeagueProjectionBaselines> leagues;
}

abstract interface class SleeperProjectionBaselineStore {
  Future<SleeperProjectionBaselineSnapshot?> read();
  Future<void> write(SleeperProjectionBaselineSnapshot snapshot);
}

class FileSleeperProjectionBaselineStore
    implements SleeperProjectionBaselineStore {
  FileSleeperProjectionBaselineStore({this.onDiagnostic});

  static const _fileName = 'sleeper_projection_baselines.json';
  final void Function(String message)? onDiagnostic;

  @override
  Future<SleeperProjectionBaselineSnapshot?> read() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) {
        onDiagnostic?.call('Sleeper PROJ: persistence read result=missing');
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        onDiagnostic?.call(
          'Sleeper PROJ: persistence read result=invalid reason=schema',
        );
        return null;
      }
      final leagues = <String, SleeperLeagueProjectionBaselines>{};
      final rawLeagues = decoded['leagues'];
      if (rawLeagues is Map<String, dynamic>) {
        for (final leagueEntry in rawLeagues.entries) {
          final value = leagueEntry.value;
          if (value is! Map<String, dynamic>) continue;
          final signature = value['scoringSignature'];
          final rawPlayers = value['players'];
          if (signature is! String || rawPlayers is! Map<String, dynamic>) {
            continue;
          }
          final players = <String, SleeperProjectionBaseline>{};
          for (final playerEntry in rawPlayers.entries) {
            if (playerEntry.value is! Map<String, dynamic>) continue;
            try {
              players[playerEntry.key] = SleeperProjectionBaseline.fromJson(
                playerEntry.value as Map<String, dynamic>,
              );
            } on FormatException {
              // Retain other usable player baselines.
            }
          }
          leagues[leagueEntry.key] = SleeperLeagueProjectionBaselines(
            scoringSignature: signature,
            players: players,
          );
        }
      }
      final season = decoded['season'];
      final seasonType = decoded['seasonType'];
      final week = decoded['week'];
      if (season is! String || seasonType is! String || week is! int) {
        onDiagnostic?.call(
          'Sleeper PROJ: persistence read result=invalid reason=context',
        );
        return null;
      }
      final snapshot = SleeperProjectionBaselineSnapshot(
        season: season,
        seasonType: seasonType,
        week: week,
        leagues: leagues,
      );
      onDiagnostic?.call(
        'Sleeper PROJ: persistence read result=loaded '
        'season=$season type=$seasonType week=$week leagues=${leagues.length}',
      );
      return snapshot;
    } on Object catch (error) {
      onDiagnostic?.call(
        'Sleeper PROJ: persistence read result=failed '
        'error=${error.runtimeType}',
      );
      return null;
    }
  }

  @override
  Future<void> write(SleeperProjectionBaselineSnapshot snapshot) async {
    final file = await _cacheFile();
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'season': snapshot.season,
        'seasonType': snapshot.seasonType,
        'week': snapshot.week,
        'leagues': {
          for (final league in snapshot.leagues.entries)
            league.key: {
              'scoringSignature': league.value.scoringSignature,
              'players': {
                for (final player in league.value.players.entries)
                  player.key: player.value.toJson(),
              },
            },
        },
      }),
      flush: true,
    );
  }

  Future<File> _cacheFile() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}/$_fileName');
  }
}

typedef SleeperProjectionMetadataResolver =
    Future<Map<String, SleeperFantasyPlayer>> Function(
      Iterable<String> playerIds,
    );

abstract interface class SleeperProjectionEnricher {
  Future<SleeperFantasyMatchup> applyCached(SleeperFantasyMatchup matchup);
  Future<bool> refresh(SleeperFantasyMatchup matchup);
}

class SleeperSettlingProjectionService implements SleeperProjectionEnricher {
  SleeperSettlingProjectionService({
    required this.projectionSource,
    required this.metadataResolver,
    required this.gameStatusSource,
    SleeperProjectionBaselineStore? baselineStore,
    this.scorer = const SleeperProjectionScorer(),
    DateTime Function()? now,
    this.projectionRetryInterval = const Duration(minutes: 15),
    void Function(String message)? onDiagnostic,
  }) : onDiagnostic = onDiagnostic,
       baselineStore =
           baselineStore ??
           FileSleeperProjectionBaselineStore(onDiagnostic: onDiagnostic),
       _now = now ?? DateTime.now;

  final SleeperProjectionSource projectionSource;
  final SleeperProjectionMetadataResolver metadataResolver;
  final SleeperNflGameStatusSource gameStatusSource;
  final SleeperProjectionBaselineStore baselineStore;
  final SleeperProjectionScorer scorer;
  final DateTime Function() _now;
  final Duration projectionRetryInterval;
  final void Function(String message)? onDiagnostic;

  SleeperProjectionBaselineSnapshot? _snapshot;
  bool _loaded = false;
  Future<void>? _loadInProgress;
  Future<void> _writeQueue = Future.value();
  final Map<String, Future<bool>> _refreshes = {};
  final Map<String, SleeperPlayerProjection> _rawProjections = {};
  final Map<String, Future<SleeperPlayerProjection?>> _rawLoads = {};
  final Map<String, DateTime> _projectionRetryAfter = {};
  final Map<String, String> _playerTeams = {};
  final Map<String, SleeperNflGamePhase> _teamStatuses = {};
  final Set<String> _diagnosedProjectionOutcomes = {};

  @override
  Future<SleeperFantasyMatchup> applyCached(
    SleeperFantasyMatchup matchup,
  ) async {
    await _ensureContext(matchup);
    final signature = _scoringSignature(matchup.league.scoringSettings);
    final league = _snapshot!.leagues[matchup.league.leagueId];
    final baselines = league?.scoringSignature == signature
        ? league!.players
        : const <String, SleeperProjectionBaseline>{};
    final teamProjection = _settledTeamTotal(matchup.team, baselines);
    final opponentProjection = _settledTeamTotal(matchup.opponent, baselines);
    _diagnose(
      'Sleeper PROJ: baseline lookup league=${matchup.league.leagueId} '
      'stored=${baselines.length} '
      'team=${teamProjection == null ? 'missing' : 'ready'} '
      'opponent=${opponentProjection == null ? 'missing' : 'ready'}',
    );
    return matchup.withProjectedTotals(
      teamProjection: teamProjection,
      opponentProjection: opponentProjection,
    );
  }

  @override
  Future<bool> refresh(SleeperFantasyMatchup matchup) {
    final starterIds = {
      ...matchup.team.matchup.starters,
      ...matchup.opponent.matchup.starters,
    }.toList()..sort();
    final key = [
      matchup.league.season,
      matchup.seasonType,
      matchup.week,
      matchup.league.leagueId,
      _scoringSignature(matchup.league.scoringSettings),
      starterIds.join(','),
    ].join('|');
    return _refreshes.putIfAbsent(
      key,
      () => _refresh(matchup, starterIds).whenComplete(() {
        _refreshes.remove(key);
      }),
    );
  }

  Future<bool> _refresh(
    SleeperFantasyMatchup matchup,
    List<String> starterIds,
  ) async {
    await _ensureContext(matchup);
    final signature = _scoringSignature(matchup.league.scoringSettings);
    final storedLeague = _snapshot!.leagues[matchup.league.leagueId];
    final existing = storedLeague?.scoringSignature == signature
        ? storedLeague!.players
        : const <String, SleeperProjectionBaseline>{};
    _diagnose(
      'Sleeper PROJ: capture started league=${matchup.league.leagueId} '
      'season=${matchup.league.season} type=${matchup.seasonType} '
      'week=${matchup.week} starters=${starterIds.length} '
      'frozen=${existing.length}',
    );

    Map<String, SleeperFantasyPlayer> metadata;
    try {
      metadata = await metadataResolver(starterIds);
    } on Object {
      metadata = const {};
    }
    _diagnose(
      'Sleeper PROJ: metadata league=${matchup.league.leagueId} '
      'resolved=${metadata.length}/${starterIds.length}',
    );
    for (final entry in metadata.entries) {
      final team = entry.value.nflTeam;
      final canonical = team == null
          ? null
          : TeamCatalog.canonicalKey(SportsLeague.nfl, team);
      if (canonical != null) _playerTeams[entry.key] = canonical;
    }

    final raw = <String, SleeperPlayerProjection>{};
    await Future.wait([
      for (final playerId in starterIds)
        if (!existing.containsKey(playerId))
          _loadRawProjection(matchup, playerId).then((projection) {
            if (projection != null) raw[playerId] = projection;
          }),
    ]);

    final dates = <DateTime>{
      for (final playerId in starterIds)
        if (existing[playerId] case final baseline?) baseline.gameDate,
      for (final projection in raw.values) projection.gameDate,
    };
    Map<String, SleeperNflGamePhase> statuses;
    try {
      statuses = await gameStatusSource.statusesForDates(dates);
    } on Object {
      statuses = const {};
    }
    if (!_matchesContext(matchup)) {
      _diagnose(
        'Sleeper PROJ: capture discarded league=${matchup.league.leagueId} '
        'reason=context_changed',
      );
      return false;
    }
    _teamStatuses.addAll(statuses);

    final nextPlayers = <String, SleeperProjectionBaseline>{...existing};
    var changed = false;
    final failureReasons = <String, String>{};
    for (final playerId in starterIds) {
      if (nextPlayers.containsKey(playerId)) {
        continue;
      }
      final projection = raw[playerId];
      final player = metadata[playerId];
      final metadataTeam = _playerTeams[playerId];
      final projectionTeam = projection == null
          ? null
          : TeamCatalog.canonicalKey(SportsLeague.nfl, projection.team);
      final failure = projection == null
          ? 'projection_missing'
          : projection.stats.isEmpty
          ? 'projection_stats_missing'
          : player == null
          ? 'player_metadata_missing'
          : metadataTeam == null
          ? 'nfl_team_missing'
          : projectionTeam == null
          ? 'projection_team_missing'
          : projectionTeam != metadataTeam
          ? 'nfl_team_mismatch projection_team=$projectionTeam'
          : projection.playerId != playerId
          ? 'projection_player_mismatch response_player=${projection.playerId}'
          : projection.season != matchup.league.season
          ? 'projection_season_mismatch response_season=${projection.season}'
          : projection.week != matchup.week
          ? 'projection_week_mismatch response_week=${projection.week}'
          : projection.seasonType != matchup.seasonType.toLowerCase()
          ? 'projection_season_type_mismatch response_type=${projection.seasonType}'
          : _teamStatuses[metadataTeam] == null
          ? 'nfl_game_mapping_missing'
          : _teamStatuses[metadataTeam] != SleeperNflGamePhase.upcoming
          ? 'nfl_game_not_upcoming phase=${_teamStatuses[metadataTeam]!.name}'
          : null;
      if (failure != null) {
        failureReasons[playerId] = failure;
        _diagnoseStarterFailure(
          matchup,
          playerId,
          player,
          failure,
          rawFound: projection != null,
          statsUsable: projection?.stats.isNotEmpty == true,
          gameMappingSucceeded:
              metadataTeam != null &&
              projectionTeam == metadataTeam &&
              _teamStatuses[metadataTeam] != null,
        );
        continue;
      }
      final score = scorer.evaluate(
        projection!.stats,
        matchup.league.scoringSettings,
        position: player!.position,
      );
      final points = score.points;
      if (score.unsupportedScoringKey case final key?) {
        failureReasons[playerId] = 'unsupported_scoring_key key=$key';
        _diagnoseStarterFailure(
          matchup,
          playerId,
          player,
          failureReasons[playerId]!,
          rawFound: true,
          statsUsable: true,
          gameMappingSucceeded: true,
        );
        continue;
      }
      if (points == null || !points.isFinite || points.abs() > 10000) {
        failureReasons[playerId] = matchup.league.scoringSettings.isEmpty
            ? 'scoring_settings_missing'
            : 'scoring_evaluation_failed';
        _diagnoseStarterFailure(
          matchup,
          playerId,
          player,
          failureReasons[playerId]!,
          rawFound: true,
          statsUsable: true,
          gameMappingSucceeded: true,
        );
        continue;
      }
      nextPlayers[playerId] = SleeperProjectionBaseline(
        points: points,
        nflTeam: metadataTeam!,
        gameDate: projection.gameDate,
      );
      changed = true;
    }
    if (!changed) {
      _diagnoseUnavailableTeams(matchup, nextPlayers, failureReasons);
      _diagnose(
        'Sleeper PROJ: capture complete league=${matchup.league.leagueId} '
        'changed=false frozen=${nextPlayers.length}/${starterIds.length}',
      );
      return false;
    }
    final latestLeague = _snapshot!.leagues[matchup.league.leagueId];
    final latestPlayers = latestLeague?.scoringSignature == signature
        ? latestLeague!.players
        : const <String, SleeperProjectionBaseline>{};
    _snapshot!.leagues[matchup.league.leagueId] =
        SleeperLeagueProjectionBaselines(
          scoringSignature: signature,
          players: {...latestPlayers, ...nextPlayers},
        );
    final persisted = await _persistSafely();
    _diagnoseUnavailableTeams(matchup, nextPlayers, failureReasons);
    _diagnose(
      'Sleeper PROJ: capture complete league=${matchup.league.leagueId} '
      'changed=true frozen=${nextPlayers.length}/${starterIds.length} '
      'persisted=$persisted',
    );
    return true;
  }

  void _diagnoseStarterFailure(
    SleeperFantasyMatchup matchup,
    String playerId,
    SleeperFantasyPlayer? player,
    String reason, {
    required bool rawFound,
    required bool statsUsable,
    required bool gameMappingSucceeded,
  }) {
    _diagnoseOnce(
      'Sleeper projection unavailable: league=${matchup.league.leagueId} '
      'player=$playerId name=${_diagnosticName(player)} '
      'position=${player?.position ?? 'unknown'} '
      'nfl_team=${player?.nflTeam ?? 'unknown'} raw=$rawFound '
      'stats=$statsUsable scoring=false game_mapping=$gameMappingSucceeded '
      'baseline=false reason=$reason',
    );
  }

  void _diagnoseUnavailableTeams(
    SleeperFantasyMatchup matchup,
    Map<String, SleeperProjectionBaseline> baselines,
    Map<String, String> failureReasons,
  ) {
    for (final side in <(String, SleeperFantasyTeam)>[
      ('team', matchup.team),
      ('opponent', matchup.opponent),
    ]) {
      final unresolved = <String>[];
      for (final playerId in side.$2.matchup.starters) {
        final team = baselines[playerId]?.nflTeam ?? _playerTeams[playerId];
        final phase = team == null ? null : _teamStatuses[team];
        if (phase == SleeperNflGamePhase.finalStatus &&
            side.$2.matchup.playerPoints[playerId]?.isFinite == true) {
          continue;
        }
        if (!baselines.containsKey(playerId)) unresolved.add(playerId);
      }
      if (unresolved.isEmpty) continue;
      final first = unresolved.first;
      _diagnose(
        'Sleeper projection team unavailable: '
        'league=${matchup.league.leagueId} side=${side.$1} '
        'unresolved_starters=${unresolved.length} first_player=$first '
        'reason=${failureReasons[first] ?? 'baseline_missing'}',
      );
    }
  }

  double? _settledTeamTotal(
    SleeperFantasyTeam team,
    Map<String, SleeperProjectionBaseline> baselines,
  ) {
    var total = 0.0;
    for (final playerId in team.matchup.starters) {
      final baseline = baselines[playerId];
      final nflTeam = baseline?.nflTeam ?? _playerTeams[playerId];
      final phase = nflTeam == null ? null : _teamStatuses[nflTeam];
      if (phase == SleeperNflGamePhase.finalStatus) {
        final actual = team.matchup.playerPoints[playerId];
        if (actual == null || !actual.isFinite) return null;
        total += actual;
      } else {
        if (baseline == null) return null;
        total += baseline.points;
      }
    }
    return total.isFinite ? total : null;
  }

  Future<SleeperPlayerProjection?> _loadRawProjection(
    SleeperFantasyMatchup matchup,
    String playerId,
  ) async {
    final key = [
      matchup.league.season,
      matchup.seasonType,
      matchup.week,
      playerId,
    ].join('|');
    final cached = _rawProjections[key];
    if (cached != null) {
      _diagnose('Sleeper PROJ: raw cache hit player=$playerId');
      return cached;
    }
    if (_projectionRetryAfter[key]?.isAfter(_now()) ?? false) {
      _diagnose('Sleeper PROJ: raw retry deferred player=$playerId');
      return null;
    }
    final inFlight = _rawLoads[key];
    if (inFlight != null) {
      _diagnose('Sleeper PROJ: raw fetch joined player=$playerId');
      return inFlight;
    }
    return _rawLoads.putIfAbsent(key, () async {
      _diagnose('Sleeper PROJ: raw fetch start player=$playerId');
      try {
        final projection = await projectionSource.fetchPlayerProjection(
          playerId: playerId,
          season: matchup.league.season,
          week: matchup.week,
          seasonType: matchup.seasonType,
        );
        if (projection == null) {
          _diagnose('Sleeper PROJ: raw fetch missing player=$playerId');
          _projectionRetryAfter[key] = _now().add(projectionRetryInterval);
          return null;
        }
        _diagnose(
          'Sleeper PROJ: raw fetch success player=$playerId '
          'stats=${projection.stats.length}',
        );
        _rawProjections[key] = projection;
        _projectionRetryAfter.remove(key);
        return projection;
      } on Object catch (error) {
        _diagnose(
          'Sleeper PROJ: raw fetch failed player=$playerId '
          'error=${error.runtimeType}',
        );
        _projectionRetryAfter[key] = _now().add(projectionRetryInterval);
        return null;
      } finally {
        _rawLoads.remove(key);
      }
    });
  }

  Future<void> _ensureContext(SleeperFantasyMatchup matchup) async {
    if (!_loaded) {
      await (_loadInProgress ??= _load().whenComplete(() {
        _loadInProgress = null;
      }));
    }
    final current = _snapshot;
    final seasonType = matchup.seasonType.toLowerCase();
    if (current != null &&
        current.season == matchup.league.season &&
        current.seasonType == seasonType &&
        current.week == matchup.week) {
      return;
    }
    _snapshot = SleeperProjectionBaselineSnapshot(
      season: matchup.league.season,
      seasonType: seasonType,
      week: matchup.week,
      leagues: {},
    );
    _rawProjections.clear();
    _projectionRetryAfter.clear();
    _playerTeams.clear();
    _teamStatuses.clear();
    _diagnosedProjectionOutcomes.clear();
    await _persistSafely();
  }

  bool _matchesContext(SleeperFantasyMatchup matchup) {
    final current = _snapshot;
    return current != null &&
        current.season == matchup.league.season &&
        current.seasonType == matchup.seasonType.toLowerCase() &&
        current.week == matchup.week;
  }

  Future<void> _load() async {
    try {
      _snapshot = await baselineStore.read();
    } on Object {
      _snapshot = null;
    } finally {
      _loaded = true;
    }
  }

  Future<bool> _persistSafely() async {
    final snapshot = _snapshot;
    if (snapshot == null) return false;
    _writeQueue = _writeQueue
        .catchError((Object _) {})
        .then((_) => baselineStore.write(snapshot));
    try {
      await _writeQueue;
      return true;
    } on Object {
      // Persistence failure must not suppress actual matchup processing.
      _diagnose('Sleeper projection baseline persistence failed.');
      return false;
    }
  }

  void _diagnose(String message) => onDiagnostic?.call(message);

  void _diagnoseOnce(String message) {
    if (_diagnosedProjectionOutcomes.add(message)) _diagnose(message);
  }
}

String _diagnosticName(SleeperFantasyPlayer? player) {
  final name = player?.fullName.trim();
  return name == null || name.isEmpty ? 'unknown' : name.replaceAll(' ', '_');
}

String _scoringSignature(Map<String, double> settings) {
  final keys = settings.keys.toList()..sort();
  return [for (final key in keys) '$key=${settings[key]}'].join('|');
}

String _dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
