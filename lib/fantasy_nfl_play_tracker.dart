import 'fantasy_nfl_play.dart';

class FantasyNflPlayTracker {
  final Map<String, Set<String>> _observedIdsByGame = {};

  bool hasObservedGame(String gameId) => _observedIdsByGame.containsKey(gameId);

  List<FantasyNflPlay> observe(
    String gameId,
    List<FantasyNflPlay> currentPlays,
  ) {
    final observed = _observedIdsByGame[gameId];
    if (observed == null) {
      _observedIdsByGame[gameId] = {
        for (final play in currentPlays) play.playId,
      };
      return const [];
    }
    final newPlays = <FantasyNflPlay>[];
    for (final play in currentPlays) {
      if (observed.add(play.playId)) newPlays.add(play);
    }
    return List.unmodifiable(newPlays);
  }
}
