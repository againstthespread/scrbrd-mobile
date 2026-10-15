import 'sleeper_api_client.dart';
import 'sleeper_discovery.dart';
import 'sleeper_models.dart';

class SleeperFantasyException implements Exception {
  const SleeperFantasyException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SleeperLeagueSnapshot {
  const SleeperLeagueSnapshot({
    required this.league,
    required this.week,
    required this.users,
    required this.rosters,
    required this.matchups,
    this.seasonType = 'regular',
  });

  final SleeperLeague league;
  final int week;
  final String seasonType;
  final List<SleeperUser> users;
  final List<SleeperRoster> rosters;
  final List<SleeperMatchup> matchups;

  SleeperUser? userForRoster(SleeperRoster roster) {
    final ownerId = roster.ownerId;
    if (ownerId == null) return null;
    for (final user in users) {
      if (user.userId == ownerId) return user;
    }
    return null;
  }

  String rosterLabel(SleeperRoster roster) =>
      userForRoster(roster)?.label ?? 'Roster ${roster.rosterId}';

  SleeperFantasyMatchup matchupForRoster(int rosterId) {
    final roster = _singleBy(
      rosters,
      (item) => item.rosterId == rosterId,
      'Roster $rosterId was not found.',
    );
    final matchup = _singleBy(
      matchups,
      (item) => item.rosterId == rosterId,
      'Roster $rosterId has no matchup for week $week.',
    );
    final matchupId = matchup.matchupId;
    if (matchupId == null) {
      throw SleeperFantasyException(
        'Roster $rosterId has no opponent for week $week.',
      );
    }
    final opponentMatchup = _singleBy(
      matchups,
      (item) =>
          item.matchupId == matchupId && item.rosterId != matchup.rosterId,
      'No opponent was found for roster $rosterId in week $week.',
    );
    final opponentRoster = _singleBy(
      rosters,
      (item) => item.rosterId == opponentMatchup.rosterId,
      'Opponent roster ${opponentMatchup.rosterId} was not found.',
    );
    return SleeperFantasyMatchup(
      league: league,
      week: week,
      seasonType: seasonType,
      team: SleeperFantasyTeam(
        roster: roster,
        user: userForRoster(roster),
        matchup: matchup,
      ),
      opponent: SleeperFantasyTeam(
        roster: opponentRoster,
        user: userForRoster(opponentRoster),
        matchup: opponentMatchup,
      ),
    );
  }
}

class SleeperFantasyRepository {
  SleeperFantasyRepository(
    this._apiClient, {
    DateTime Function()? clock,
    this.weekRefreshInterval = const Duration(hours: 6),
    this.metadataRefreshInterval = const Duration(hours: 1),
    this.metadataRetryInterval = const Duration(minutes: 1),
  }) : _clock = clock ?? DateTime.now;

  final SleeperApiClient _apiClient;
  final DateTime Function() _clock;
  final Duration weekRefreshInterval;
  final Duration metadataRefreshInterval;
  final Duration metadataRetryInterval;
  final Map<String, SleeperLeagueSnapshot> _snapshots = {};
  final Map<String, DateTime> _weekCheckedAt = {};
  final Map<String, DateTime> _metadataFetchedAt = {};
  final Map<String, DateTime> _metadataRetryAfter = {};
  final Map<String, int> _metadataRevision = {};
  final Map<String, Future<SleeperLeagueSnapshot>> _refreshes = {};

  Future<(SleeperLeague, List<SleeperUser>, List<SleeperRoster>)>
  _fetchMetadata(String id) async {
    final result = await (
      _apiClient.fetchLeague(id),
      _apiClient.fetchLeagueUsers(id),
      _apiClient.fetchLeagueRosters(id),
    ).wait;
    if (result.$1.leagueId != id) {
      throw const SleeperFantasyException(
        'Sleeper returned a different league.',
      );
    }
    return result;
  }

  void _recordMetadataSuccess(String id, int revision) {
    if ((_metadataRevision[id] ?? 0) != revision) return;
    _metadataFetchedAt[id] = _clock();
    _metadataRetryAfter.remove(id);
  }

  /// Keep usable metadata; require another observation after a config edit.
  void expireMetadata(String leagueId) {
    final id = leagueId.trim();
    _metadataRevision[id] = (_metadataRevision[id] ?? 0) + 1;
    _metadataFetchedAt.remove(id);
    _metadataRetryAfter.remove(id);
  }

  Future<SleeperLeagueSnapshot> loadLeague(String leagueId) async {
    final normalizedId = leagueId.trim();
    if (normalizedId.isEmpty) {
      throw const SleeperFantasyException('Enter a Sleeper league ID.');
    }
    final revision = _metadataRevision[normalizedId] ?? 0;
    final (metadata, nflState) = await (
      _fetchMetadata(normalizedId),
      _apiClient.fetchNflState(),
    ).wait;
    final (league, users, rosters) = metadata;
    final fantasyWeek = nflState.fantasyWeek;
    final matchups = await _apiClient.fetchMatchups(normalizedId, fantasyWeek);
    final snapshot = SleeperLeagueSnapshot(
      league: league,
      week: fantasyWeek,
      seasonType: nflState.seasonType,
      users: users,
      rosters: rosters,
      matchups: matchups,
    );
    _snapshots[normalizedId] = snapshot;
    _weekCheckedAt[normalizedId] = _clock();
    _recordMetadataSuccess(normalizedId, revision);
    return snapshot;
  }

  /// High-frequency path: normally performs only GET /league/{id}/matchups/{week}.
  Future<SleeperLeagueSnapshot> refreshMatchups(String leagueId) {
    final normalizedId = leagueId.trim();
    return _refreshes.putIfAbsent(
      normalizedId,
      () => _refreshMatchups(normalizedId).whenComplete(() {
        _refreshes.remove(normalizedId);
      }),
    );
  }

  Future<SleeperLeagueSnapshot> _refreshMatchups(String normalizedId) async {
    var cached = _snapshots[normalizedId];
    if (cached == null) return loadLeague(normalizedId);

    DateTime? checkedAt;
    var periodChanged = false;
    final lastCheck = _weekCheckedAt[normalizedId];
    if (lastCheck == null ||
        _clock().difference(lastCheck) >= weekRefreshInterval) {
      final nflState = await _apiClient.fetchNflState();
      checkedAt = _clock();
      final fantasyWeek = nflState.fantasyWeek;
      if (fantasyWeek != cached.week ||
          nflState.seasonType != cached.seasonType) {
        periodChanged = true;
        cached = SleeperLeagueSnapshot(
          league: cached.league,
          week: fantasyWeek,
          seasonType: nflState.seasonType,
          users: cached.users,
          rosters: cached.rosters,
          matchups: const [],
        );
      }
    }

    // Do not commit a week check or metadata freshness if matchup fetch fails
    // (F09). The next refresh must still be able to retry the transition.
    final matchups = await _apiClient.fetchMatchups(normalizedId, cached.week);
    var league = cached.league;
    var users = cached.users;
    var rosters = cached.rosters;
    final now = _clock();
    final metadataAt = _metadataFetchedAt[normalizedId];
    final metadataDue =
        periodChanged ||
        metadataAt == null ||
        now.isBefore(metadataAt) ||
        now.difference(metadataAt) >= metadataRefreshInterval;
    final retryAfter = _metadataRetryAfter[normalizedId];
    if (metadataDue &&
        (periodChanged || retryAfter == null || !now.isBefore(retryAfter))) {
      final revision = _metadataRevision[normalizedId] ?? 0;
      try {
        (league, users, rosters) = await _fetchMetadata(normalizedId);
        _recordMetadataSuccess(normalizedId, revision);
      } on Object {
        // Keep the previous coherent metadata bundle while scores can advance.
        // A failed refresh is never recorded as a fresh metadata observation.
        if ((_metadataRevision[normalizedId] ?? 0) == revision) {
          _metadataFetchedAt.remove(normalizedId);
          _metadataRetryAfter[normalizedId] = _clock().add(
            metadataRetryInterval,
          );
        }
      }
    }
    final refreshed = SleeperLeagueSnapshot(
      league: league,
      week: cached.week,
      seasonType: cached.seasonType,
      users: users,
      rosters: rosters,
      matchups: matchups,
    );
    _snapshots[normalizedId] = refreshed;
    // A failed fetch must leave the old check expired so rollover retries.
    if (checkedAt != null) _weekCheckedAt[normalizedId] = checkedAt;
    return refreshed;
  }

  void invalidate(String leagueId) {
    expireMetadata(leagueId);
    _snapshots.remove(leagueId.trim());
    _weekCheckedAt.remove(leagueId.trim());
  }

  Future<(SleeperAccount, List<SleeperDiscoveredLeague>)> discoverLeagues(
    String username,
    int season,
  ) async {
    final account = await _apiClient.fetchUser(username);
    if (account == null) {
      throw const SleeperFantasyException('Sleeper username was not found.');
    }
    final leagues = await _apiClient.fetchUserNflLeagues(
      account.userId,
      season,
    );
    final discovered = <SleeperDiscoveredLeague>[];
    for (final league in leagues) {
      try {
        final (users, rosters) = await (
          _apiClient.fetchLeagueUsers(league.leagueId),
          _apiClient.fetchLeagueRosters(league.leagueId),
        ).wait;
        final owned = rosters
            .where((roster) => roster.ownerId == account.userId)
            .toList();
        final roster = owned.length == 1 ? owned.single : null;
        final owner = roster == null
            ? null
            : users.where((user) => user.userId == roster.ownerId).firstOrNull;
        discovered.add(
          SleeperDiscoveredLeague(
            league: league,
            rosterId: roster?.rosterId,
            teamDisplayName: owner?.label,
            rosters: [
              for (final candidate in rosters)
                SleeperDiscoveryRoster(
                  rosterId: candidate.rosterId,
                  name:
                      users
                          .where((user) => user.userId == candidate.ownerId)
                          .firstOrNull
                          ?.label ??
                      'Roster ${candidate.rosterId}',
                ),
            ],
          ),
        );
      } on Object {
        discovered.add(
          SleeperDiscoveredLeague(
            league: league,
            rosterId: null,
            teamDisplayName: null,
            rosters: const [],
          ),
        );
      }
    }
    discovered.sort((a, b) => a.league.name.compareTo(b.league.name));
    return (account, List<SleeperDiscoveredLeague>.unmodifiable(discovered));
  }
}

T _singleBy<T>(List<T> items, bool Function(T) predicate, String error) {
  for (final item in items) {
    if (predicate(item)) return item;
  }
  throw SleeperFantasyException(error);
}
