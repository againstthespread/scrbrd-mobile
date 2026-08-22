import 'fantasy_point_delta_tracker.dart';
import 'fantasy_scoring_correlation.dart';

class FantasyMatchupContext {
  const FantasyMatchupContext({
    required this.leagueId,
    required this.week,
    required this.rosterId,
    required this.opponentRosterId,
    required this.matchupId,
  });

  final String leagueId;
  final int week;
  final int rosterId;
  final int opponentRosterId;
  final int? matchupId;

  @override
  bool operator ==(Object other) =>
      other is FantasyMatchupContext &&
      leagueId == other.leagueId &&
      week == other.week &&
      rosterId == other.rosterId &&
      opponentRosterId == other.opponentRosterId &&
      matchupId == other.matchupId;

  @override
  int get hashCode =>
      Object.hash(leagueId, week, rosterId, opponentRosterId, matchupId);
}

class PendingFantasyAlert {
  const PendingFantasyAlert({
    required this.id,
    required this.context,
    required this.event,
    required this.userName,
    required this.userScore,
    required this.opponentName,
    required this.opponentScore,
  });

  final String id;
  final FantasyMatchupContext context;
  final FantasyScoringEvent event;
  final String userName;
  final double userScore;
  final String opponentName;
  final double opponentScore;
}

class PendingFantasyAlertStore {
  PendingFantasyAlertStore({this.capacity = 8});

  final int capacity;
  FantasyMatchupContext? _context;
  final List<PendingFantasyAlert> _pending = [];
  final Set<String> _knownIds = {};

  int get length => _pending.length;
  FantasyMatchupContext? get context => _context;
  List<PendingFantasyAlert> get pending => List.unmodifiable(_pending);

  void useContext(FantasyMatchupContext context) {
    if (_context == context) return;
    _context = context;
    _pending.clear();
    _knownIds.clear();
  }

  bool add(PendingFantasyAlert alert) {
    useContext(alert.context);
    if (!_knownIds.add(alert.id)) return false;
    _pending.add(alert);
    _pending.sort(_comparePriority);
    if (_pending.length > capacity) {
      _pending.removeLast();
    }
    return _pending.any((item) => item.id == alert.id);
  }

  PendingFantasyAlert? get next => _pending.isEmpty ? null : _pending.first;

  void markDelivered(String id) {
    _pending.removeWhere((item) => item.id == id);
    // Retain the ID for the current context to dedupe revised ESPN evidence.
    _knownIds.add(id);
  }
}

String fantasyTransitionId(
  FantasyMatchupContext context,
  FantasyPointDelta delta,
) =>
    '${context.leagueId}|${context.week}|${context.rosterId}|'
    '${context.opponentRosterId}|${context.matchupId}|${delta.playerId}|'
    '${delta.previousPoints}|${delta.currentPoints}';

int _comparePriority(PendingFantasyAlert left, PendingFantasyAlert right) {
  final side = _sidePriority(
    left.event.delta.side,
  ).compareTo(_sidePriority(right.event.delta.side));
  if (side != 0) return side;
  final magnitude = right.event.delta.delta.abs().compareTo(
    left.event.delta.delta.abs(),
  );
  if (magnitude != 0) return magnitude;
  final confidence = _confidencePriority(
    right.event.confidence,
  ).compareTo(_confidencePriority(left.event.confidence));
  if (confidence != 0) return confidence;
  return left.id.compareTo(right.id);
}

int _sidePriority(FantasyMatchupSide side) =>
    side == FantasyMatchupSide.user ? 0 : 1;

int _confidencePriority(FantasyCorrelationConfidence confidence) =>
    switch (confidence) {
      FantasyCorrelationConfidence.high => 3,
      FantasyCorrelationConfidence.medium => 2,
      FantasyCorrelationConfidence.low => 1,
      FantasyCorrelationConfidence.none => 0,
    };
