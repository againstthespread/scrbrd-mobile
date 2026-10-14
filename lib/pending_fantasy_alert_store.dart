import 'fantasy_point_alert.dart';
import 'fantasy_league_config.dart';
import 'fantasy_point_delta_tracker.dart';
import 'fantasy_provider_models.dart';
import 'sleeper_models.dart';

class PendingFantasyAlert {
  const PendingFantasyAlert({
    required this.id,
    required this.alert,
    this.observation = 0,
  });

  final String id;
  final FantasyPointAlert alert;

  /// Runtime observation order, shared by leagues fetched in the same refresh.
  final int observation;
}

class PendingFantasyAlertStore {
  // Pending transitions must survive a burst or a disconnected observation.
  final List<PendingFantasyAlert> _pending = [];
  final Set<(int, String)> _seen = {};

  int get length => _pending.length;
  PendingFantasyAlert? get next => _pending.isEmpty ? null : _pending.first;
  List<PendingFantasyAlert> get items => List.unmodifiable(_pending);

  bool add(PendingFantasyAlert alert) {
    // A correction can return a player to an earlier score. The same numeric
    // transition in a later observation is a new event, not a duplicate retry.
    if (!_seen.add((alert.observation, alert.id))) return false;
    _pending.add(alert);
    _pending.sort(_compare);
    return true;
  }

  void markDelivered(String id, {int observation = 0}) => _pending.removeWhere(
    (item) => item.id == id && item.observation == observation,
  );

  void clear() {
    _pending.clear();
    _seen.clear();
  }
}

String fantasyTransitionId({
  FantasyProvider provider = FantasyProvider.sleeper,
  required String leagueId,
  required int week,
  required SleeperFantasyMatchup matchup,
  required FantasyPointDelta delta,
}) =>
    '${provider.name}:$leagueId|$week|${matchup.team.roster.rosterId}|'
    '${matchup.opponent.roster.rosterId}|${matchup.team.matchup.matchupId}|'
    '${delta.side.name}|${delta.playerId}|'
    '${delta.previousPoints}|${delta.currentPoints}';

String fantasyNormalizedTransitionId({
  required FantasyProvider provider,
  required FantasyMatchupSnapshot matchup,
  required FantasyPointDelta delta,
}) =>
    '${provider.name}:${matchup.league.leagueId}|${matchup.scoringPeriod}|'
    '${matchup.matchupPeriod}|${matchup.team.team.id}|'
    '${matchup.opponent?.team.id ?? 'bye'}|${delta.side.name}|'
    '${delta.playerId}|${delta.previousPoints}|${delta.currentPoints}';

int _compare(PendingFantasyAlert left, PendingFantasyAlert right) {
  final observation = left.observation.compareTo(right.observation);
  if (observation != 0) return observation;
  // Preserve established user/magnitude priority within one observation only.
  final leftUser = left.alert.delta.side == FantasyMatchupSide.user;
  final rightUser = right.alert.delta.side == FantasyMatchupSide.user;
  if (leftUser != rightUser) return leftUser ? -1 : 1;
  final magnitude = right.alert.delta.delta.abs().compareTo(
    left.alert.delta.delta.abs(),
  );
  if (magnitude != 0) return magnitude;
  return left.id.compareTo(right.id);
}
