import 'sleeper_api_client.dart';
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
  });

  final SleeperLeague league;
  final int week;
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
  const SleeperFantasyRepository(this._apiClient);

  final SleeperApiClient _apiClient;

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
    final matchups = await _apiClient.fetchMatchups(
      normalizedId,
      nflState.week,
    );
    return SleeperLeagueSnapshot(
      league: league,
      week: nflState.week,
      users: users,
      rosters: rosters,
      matchups: matchups,
    );
  }
}

T _singleBy<T>(List<T> items, bool Function(T) predicate, String error) {
  for (final item in items) {
    if (predicate(item)) return item;
  }
  throw SleeperFantasyException(error);
}
