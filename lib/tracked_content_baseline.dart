import 'game_data.dart';
import 'golf_leaderboard.dart';

class TrackedContentBaseline {
  GameData? _game;
  GolfLeaderboard? _golf;

  GameData? get game => _game;
  GolfLeaderboard? get golf => _golf;

  void recordTeamGame(GameData game) {
    _game = game;
    _golf = null;
  }

  void recordTeamSlate(List<GameData> games) {
    if (games.isEmpty) {
      throw ArgumentError.value(games, 'games', 'Slate must not be empty.');
    }
    recordTeamGame(games.first);
  }

  void recordGolf(GolfLeaderboard golf) {
    _golf = golf;
    _game = null;
  }
}
