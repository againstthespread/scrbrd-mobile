import 'sleeper_models.dart';

enum FantasyMatchupSide { user, opponent }

class FantasyPointDelta {
  const FantasyPointDelta({
    required this.playerId,
    required this.side,
    required this.previousPoints,
    required this.currentPoints,
    required this.delta,
  });

  final String playerId;
  final FantasyMatchupSide side;
  final double previousPoints;
  final double currentPoints;
  final double delta;
}

class FantasyPointReconciliation {
  const FantasyPointReconciliation({
    required this.side,
    required this.matchupTotalDelta,
    required this.starterDeltaTotal,
  });

  final FantasyMatchupSide side;
  final double matchupTotalDelta;
  final double starterDeltaTotal;

  double get discrepancy => _normalized(matchupTotalDelta - starterDeltaTotal);

  bool get matches => discrepancy.abs() <= FantasyPointDeltaTracker.tolerance;
}

class FantasyPointDeltaResult {
  const FantasyPointDeltaResult({
    required this.events,
    required this.baselineReset,
    required this.reconciliations,
  });

  final List<FantasyPointDelta> events;
  final bool baselineReset;
  final List<FantasyPointReconciliation> reconciliations;
}

class FantasyPointDeltaTracker {
  static const tolerance = 0.000001;

  _ObservationIdentity? _identity;
  Map<String, double> _userPoints = {};
  Map<String, double> _opponentPoints = {};
  double? _userTotal;
  double? _opponentTotal;

  FantasyPointDeltaResult observe(SleeperFantasyMatchup current) {
    final identity = _ObservationIdentity.fromMatchup(current);
    if (_identity != identity) {
      _identity = identity;
      _userPoints = _reliableStarterPoints(current.team);
      _opponentPoints = _reliableStarterPoints(current.opponent);
      _userTotal = current.team.matchup.points;
      _opponentTotal = current.opponent.matchup.points;
      return const FantasyPointDeltaResult(
        events: [],
        baselineReset: true,
        reconciliations: [],
      );
    }

    final events = <FantasyPointDelta>[
      ..._compareTeam(current.team, FantasyMatchupSide.user, _userPoints),
      ..._compareTeam(
        current.opponent,
        FantasyMatchupSide.opponent,
        _opponentPoints,
      ),
    ];
    final userStarterDelta = _sumForSide(events, FantasyMatchupSide.user);
    final opponentStarterDelta = _sumForSide(
      events,
      FantasyMatchupSide.opponent,
    );
    final reconciliations = <FantasyPointReconciliation>[
      FantasyPointReconciliation(
        side: FantasyMatchupSide.user,
        matchupTotalDelta: _normalized(
          current.team.matchup.points - _userTotal!,
        ),
        starterDeltaTotal: userStarterDelta,
      ),
      FantasyPointReconciliation(
        side: FantasyMatchupSide.opponent,
        matchupTotalDelta: _normalized(
          current.opponent.matchup.points - _opponentTotal!,
        ),
        starterDeltaTotal: opponentStarterDelta,
      ),
    ];

    _userTotal = current.team.matchup.points;
    _opponentTotal = current.opponent.matchup.points;
    return FantasyPointDeltaResult(
      events: List.unmodifiable(events),
      baselineReset: false,
      reconciliations: List.unmodifiable(reconciliations),
    );
  }

  void reset() {
    _identity = null;
    _userPoints = {};
    _opponentPoints = {};
    _userTotal = null;
    _opponentTotal = null;
  }

  List<FantasyPointDelta> _compareTeam(
    SleeperFantasyTeam team,
    FantasyMatchupSide side,
    Map<String, double> trackedPoints,
  ) {
    final nextPoints = <String, double>{};
    final events = <FantasyPointDelta>[];
    for (final starter in team.starters) {
      final previous = trackedPoints[starter.playerId];
      final current = starter.points;
      if (current == null) {
        if (previous != null) nextPoints[starter.playerId] = previous;
        continue;
      }
      nextPoints[starter.playerId] = current;
      if (previous == null) continue;
      final rawDelta = current - previous;
      if (rawDelta.abs() <= tolerance) {
        nextPoints[starter.playerId] = previous;
        continue;
      }
      events.add(
        FantasyPointDelta(
          playerId: starter.playerId,
          side: side,
          previousPoints: previous,
          currentPoints: current,
          delta: _normalized(rawDelta),
        ),
      );
    }
    trackedPoints
      ..clear()
      ..addAll(nextPoints);
    return events;
  }

  static double _sumForSide(
    List<FantasyPointDelta> events,
    FantasyMatchupSide side,
  ) => _normalized(
    events
        .where((event) => event.side == side)
        .fold(0, (sum, event) => sum + event.delta),
  );
}

Map<String, double> _reliableStarterPoints(SleeperFantasyTeam team) {
  final points = <String, double>{};
  for (final starter in team.starters) {
    final value = starter.points;
    if (value != null) points[starter.playerId] = value;
  }
  return points;
}

double _normalized(double value) {
  if (value.abs() <= FantasyPointDeltaTracker.tolerance) return 0;
  const precision = 1000000000;
  return (value * precision).round() / precision;
}

class _ObservationIdentity {
  const _ObservationIdentity({
    required this.leagueId,
    required this.week,
    required this.userRosterId,
    required this.opponentRosterId,
    required this.userMatchupId,
    required this.opponentMatchupId,
  });

  factory _ObservationIdentity.fromMatchup(SleeperFantasyMatchup matchup) {
    final userMatchupId = matchup.team.matchup.matchupId;
    final opponentMatchupId = matchup.opponent.matchup.matchupId;
    return _ObservationIdentity(
      leagueId: matchup.league.leagueId,
      week: matchup.week,
      userRosterId: matchup.team.roster.rosterId,
      opponentRosterId: matchup.opponent.roster.rosterId,
      userMatchupId: userMatchupId,
      opponentMatchupId: opponentMatchupId,
    );
  }

  final String leagueId;
  final int week;
  final int userRosterId;
  final int opponentRosterId;
  final int? userMatchupId;
  final int? opponentMatchupId;

  @override
  bool operator ==(Object other) =>
      other is _ObservationIdentity &&
      leagueId == other.leagueId &&
      week == other.week &&
      userRosterId == other.userRosterId &&
      opponentRosterId == other.opponentRosterId &&
      userMatchupId == other.userMatchupId &&
      opponentMatchupId == other.opponentMatchupId;

  @override
  int get hashCode => Object.hash(
    leagueId,
    week,
    userRosterId,
    opponentRosterId,
    userMatchupId,
    opponentMatchupId,
  );
}
