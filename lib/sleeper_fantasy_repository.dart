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
  }) : _clock = clock ?? DateTime.now;

  final SleeperApiClient _apiClient;
  final DateTime Function() _clock;
  final Duration weekRefreshInterval;
  final Map<String, SleeperLeagueSnapshot> _snapshots = {};
  final Map<String, DateTime> _weekCheckedAt = {};

  Future<SleeperLeagueSnapshot> loadLeague(String leagueId) async {
    final normalizedId = leagueId.trim();
    if (normalizedId.isEmpty) {
      throw const SleeperFantasyException('Enter a Sleeper league ID.');
    }
    final (league, users, rosters, nflState) = await (
      _apiClient.fetchLeague(normalizedId),
      _apiClient.fetchLeagueUsers(normalizedId),
      _apiClient.fetchLeagueRosters(normalizedId),
      _apiClient.fetchNflState(),
    ).wait;
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
    return snapshot;
  }

  /// High-frequency path: normally performs only GET /league/{id}/matchups/{week}.
  Future<SleeperLeagueSnapshot> refreshMatchups(String leagueId) async {
    final normalizedId = leagueId.trim();
    var cached = _snapshots[normalizedId];
    if (cached == null) return loadLeague(normalizedId);

    final lastCheck = _weekCheckedAt[normalizedId];
    if (lastCheck == null ||
        _clock().difference(lastCheck) >= weekRefreshInterval) {
      final nflState = await _apiClient.fetchNflState();
      _weekCheckedAt[normalizedId] = _clock();
      final fantasyWeek = nflState.fantasyWeek;
      if (fantasyWeek != cached.week ||
          nflState.seasonType != cached.seasonType) {
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

    final matchups = await _apiClient.fetchMatchups(normalizedId, cached.week);
    final refreshed = SleeperLeagueSnapshot(
      league: cached.league,
      week: cached.week,
      seasonType: cached.seasonType,
      users: cached.users,
      rosters: cached.rosters,
      matchups: matchups,
    );
    _snapshots[normalizedId] = refreshed;
    return refreshed;
  }

  void invalidate(String leagueId) {
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
