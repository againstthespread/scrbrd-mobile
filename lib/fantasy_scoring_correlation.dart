import 'fantasy_nfl_play.dart';
import 'fantasy_point_delta_tracker.dart';
import 'sleeper_models.dart';

enum FantasyCorrelationConfidence { high, medium, low, none }

enum FantasyIdentityEvidence { espnAthleteId, fullName, initialSurname, none }

class FantasyScoringEvent {
  const FantasyScoringEvent({
    required this.delta,
    required this.player,
    required this.matchedPlay,
    required this.confidence,
    required this.explanation,
    required this.predictedPoints,
    required this.diagnostic,
  });

  final FantasyPointDelta delta;
  final SleeperFantasyPlayer? player;
  final FantasyNflPlay? matchedPlay;
  final FantasyCorrelationConfidence confidence;
  final String? explanation;
  final double? predictedPoints;
  final String diagnostic;
}

/// Pure, deterministic Phase 3C correlator. Sleeper deltas remain authoritative.
class FantasyScoringCorrelator {
  const FantasyScoringCorrelator();

  List<FantasyScoringEvent> correlate({
    required List<FantasyPointDelta> deltas,
    required Map<String, SleeperFantasyPlayer> players,
    required List<FantasyNflPlay> plays,
    required Map<String, double> scoringSettings,
  }) {
    return deltas
        .map(
          (delta) => _correlateOne(
            delta,
            players[delta.playerId],
            plays,
            scoringSettings,
          ),
        )
        .toList(growable: false);
  }

  FantasyScoringEvent _correlateOne(
    FantasyPointDelta delta,
    SleeperFantasyPlayer? player,
    List<FantasyNflPlay> plays,
    Map<String, double> scoring,
  ) {
    if (player == null) return _unmatched(delta, null, 'metadata missing');
    final candidates = <_Candidate>[];
    for (final play in plays) {
      final identity = _identity(player, play);
      if (identity == FantasyIdentityEvidence.none) continue;
      final participant = _matchingParticipant(player, play);
      final candidateTeam = participant?.team ?? play.possessionTeam;
      final teamMatch = _sameTeam(player.nflTeam, candidateTeam);
      final wrongTeam =
          player.nflTeam != null &&
          candidateTeam != null &&
          !teamMatch &&
          participant == null;
      if (wrongTeam && identity != FantasyIdentityEvidence.espnAthleteId) {
        continue;
      }
      final predicted = _predict(player, play, scoring);
      var score = switch (identity) {
        FantasyIdentityEvidence.espnAthleteId => 100,
        FantasyIdentityEvidence.fullName => 72,
        FantasyIdentityEvidence.initialSurname => 60,
        FantasyIdentityEvidence.none => 0,
      };
      if (teamMatch) score += 10;
      if (_rolePlausible(player, play, participant?.role)) score += 4;
      if (predicted != null && _close(predicted, delta.delta)) score += 14;
      candidates.add(
        _Candidate(
          play: play,
          identity: identity,
          teamMatch: teamMatch,
          predictedPoints: predicted,
          score: score,
        ),
      );
    }
    if (candidates.isEmpty) return _unmatched(delta, player, 'no candidate');
    candidates.sort((a, b) => b.score.compareTo(a.score));
    final best = candidates.first;
    if (candidates.length > 1 && candidates[1].score >= best.score - 5) {
      return _unmatched(
        delta,
        player,
        'ambiguous candidates=${candidates.length}',
      );
    }
    final predictionMatches =
        best.predictedPoints != null &&
        _close(best.predictedPoints!, delta.delta);
    final confidence =
        best.identity == FantasyIdentityEvidence.espnAthleteId ||
            (best.score >= 80 && predictionMatches)
        ? FantasyCorrelationConfidence.high
        : best.score >= 68
        ? FantasyCorrelationConfidence.medium
        : FantasyCorrelationConfidence.low;
    final diagnostic =
        'player=${player.fullName} delta=${delta.delta} '
        'candidatePlay=${best.play.playId} identity=${best.identity.name} '
        'teamMatch=${best.teamMatch} predictedPoints=${best.predictedPoints} '
        'confidence=${confidence.name}';
    return FantasyScoringEvent(
      delta: delta,
      player: player,
      matchedPlay: best.play,
      confidence: confidence,
      explanation: _explanation(player, best.play),
      predictedPoints: best.predictedPoints,
      diagnostic: diagnostic,
    );
  }

  FantasyScoringEvent _unmatched(
    FantasyPointDelta delta,
    SleeperFantasyPlayer? player,
    String reason,
  ) => FantasyScoringEvent(
    delta: delta,
    player: player,
    matchedPlay: null,
    confidence: FantasyCorrelationConfidence.none,
    explanation: null,
    predictedPoints: null,
    diagnostic:
        'player=${player?.fullName ?? delta.playerId} delta=${delta.delta} '
        'result=$reason confidence=none',
  );
}

FantasyIdentityEvidence _identity(
  SleeperFantasyPlayer player,
  FantasyNflPlay play,
) {
  final espnId = player.espnPlayerId;
  if (espnId != null &&
      play.participants.any((item) => item.espnAthleteId == espnId)) {
    return FantasyIdentityEvidence.espnAthleteId;
  }
  final description = _words(play.description);
  final full = _words(player.fullName);
  if (full.length >= 2 && _containsSequence(description, full)) {
    return FantasyIdentityEvidence.fullName;
  }
  final surname = _surnameWords(player);
  final initial = _firstInitial(player);
  if (initial == null || surname.isEmpty) return FantasyIdentityEvidence.none;
  for (var index = 0; index + surname.length < description.length; index++) {
    if (description[index] != initial) continue;
    if (_sequenceAt(description, index + 1, surname)) {
      return FantasyIdentityEvidence.initialSurname;
    }
  }
  return FantasyIdentityEvidence.none;
}

FantasyNflPlayParticipant? _matchingParticipant(
  SleeperFantasyPlayer player,
  FantasyNflPlay play,
) {
  for (final participant in play.participants) {
    if (player.espnPlayerId != null &&
        participant.espnAthleteId == player.espnPlayerId) {
      return participant;
    }
    final name = participant.displayName;
    if (name != null &&
        _words(name).join(' ') == _words(player.fullName).join(' ')) {
      return participant;
    }
  }
  return null;
}

double? _predict(
  SleeperFantasyPlayer player,
  FantasyNflPlay play,
  Map<String, double> scoring,
) {
  final text = play.description.toLowerCase();
  final yards = play.yards ?? _yardage(text);
  final touchdown = text.contains('touchdown') || text.contains(' td');
  final position = player.position?.toUpperCase();
  final isInterception =
      play.type == FantasyNflPlayType.interception ||
      text.contains('intercepted');
  if (position == 'QB' &&
      isInterception &&
      deltaKey(scoring, 'pass_int') != null) {
    return scoring['pass_int'];
  }
  if (position == 'QB' && (text.contains(' pass') || text.startsWith('pass'))) {
    double points = (yards ?? 0) * (scoring['pass_yd'] ?? 0);
    if (touchdown) points += scoring['pass_td'] ?? 0;
    return _hasAny(scoring, ['pass_yd', 'pass_td']) ? _rounded(points) : null;
  }
  final receiving =
      text.contains(' pass complete to ') ||
      text.contains(' reception') ||
      play.type == FantasyNflPlayType.reception;
  if (receiving && position != 'QB') {
    double points = scoring['rec'] ?? 0;
    points += (yards ?? 0) * (scoring['rec_yd'] ?? 0);
    if (touchdown) points += scoring['rec_td'] ?? 0;
    return _hasAny(scoring, ['rec', 'rec_yd', 'rec_td'])
        ? _rounded(points)
        : null;
  }
  final rushing =
      play.type == FantasyNflPlayType.rush || text.contains(' rush');
  if (rushing) {
    double points = (yards ?? 0) * (scoring['rush_yd'] ?? 0);
    if (touchdown) points += scoring['rush_td'] ?? 0;
    return _hasAny(scoring, ['rush_yd', 'rush_td']) ? _rounded(points) : null;
  }
  if (position == 'K' && play.type == FantasyNflPlayType.extraPoint) {
    return scoring['xpm'];
  }
  return null;
}

double? deltaKey(Map<String, double> scoring, String key) => scoring[key];

String _explanation(SleeperFantasyPlayer player, FantasyNflPlay play) {
  final yards = play.yards ?? _yardage(play.description.toLowerCase());
  final prefix = yards == null ? '' : '$yards YD ';
  final text = play.description.toLowerCase();
  if (text.contains('touchdown')) {
    if (player.position?.toUpperCase() == 'QB' && text.contains('pass')) {
      return '${prefix}PASS TD';
    }
    if (text.contains('pass complete') ||
        play.type == FantasyNflPlayType.reception) {
      return '${prefix}REC TD';
    }
    if (text.contains('rush')) return '${prefix}RUSH TD';
    return '${prefix}TD';
  }
  if (play.type == FantasyNflPlayType.interception) return 'INTERCEPTION';
  if (play.type == FantasyNflPlayType.fieldGoal) return '${prefix}FIELD GOAL';
  return play.description;
}

List<String> _words(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r"[^a-z0-9]+"), ' ')
    .trim()
    .split(RegExp(r'\s+'))
    .where((word) => word.isNotEmpty)
    .toList(growable: false);

List<String> _surnameWords(SleeperFantasyPlayer player) {
  final words = _words(player.lastName);
  if (words.isEmpty) return const [];
  const suffixes = {'jr', 'sr', 'ii', 'iii', 'iv'};
  return words.where((word) => !suffixes.contains(word)).toList();
}

String? _firstInitial(SleeperFantasyPlayer player) {
  final words = _words(player.firstName);
  return words.isEmpty ? null : words.first.substring(0, 1);
}

bool _containsSequence(List<String> source, List<String> target) {
  for (var i = 0; i + target.length <= source.length; i++) {
    if (_sequenceAt(source, i, target)) return true;
  }
  return false;
}

bool _sequenceAt(List<String> source, int index, List<String> target) {
  if (index + target.length > source.length) return false;
  for (var i = 0; i < target.length; i++) {
    if (source[index + i] != target[i]) return false;
  }
  return true;
}

bool _sameTeam(String? left, String? right) =>
    left != null && right != null && left.toUpperCase() == right.toUpperCase();

bool _rolePlausible(
  SleeperFantasyPlayer player,
  FantasyNflPlay play,
  String? role,
) {
  final position = player.position?.toUpperCase();
  final normalizedRole = role?.toLowerCase();
  if (position == 'QB') {
    return normalizedRole == 'passer' ||
        play.description.toLowerCase().contains('pass');
  }
  if (position == 'K') {
    return play.type == FantasyNflPlayType.fieldGoal ||
        play.type == FantasyNflPlayType.extraPoint;
  }
  if (position == 'RB' || position == 'WR' || position == 'TE') {
    return normalizedRole == 'rusher' ||
        normalizedRole == 'receiver' ||
        play.type == FantasyNflPlayType.rush ||
        play.type == FantasyNflPlayType.reception;
  }
  return false;
}

int? _yardage(String text) {
  final match = RegExp(r'(\d+)[ -]yard').firstMatch(text);
  return match == null ? null : int.tryParse(match.group(1)!);
}

bool _hasAny(Map<String, double> scoring, List<String> keys) =>
    keys.any(scoring.containsKey);
bool _close(double left, double right) => (left - right).abs() <= 0.011;
double _rounded(double value) => (value * 1000).round() / 1000;

class _Candidate {
  const _Candidate({
    required this.play,
    required this.identity,
    required this.teamMatch,
    required this.predictedPoints,
    required this.score,
  });
  final FantasyNflPlay play;
  final FantasyIdentityEvidence identity;
  final bool teamMatch;
  final double? predictedPoints;
  final int score;
}
