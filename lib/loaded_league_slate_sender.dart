import 'device_transport.dart';
import 'game_data.dart';
import 'golf_leaderboard.dart';
import 'sports_league.dart';

class LeagueSlateSendException implements Exception {
  const LeagueSlateSendException(this.league, this.cause);

  final SportsLeague league;
  final Object cause;

  @override
  String toString() => '${league.label} slate failed: $cause';
}

/// TEMPORARY MULTI-LEAGUE DIAGNOSTIC: sends independently loaded league
/// slates in stable SportsLeague order through the existing transport.
class LoadedLeagueSlateSender {
  const LoadedLeagueSlateSender({required this.transport});

  final DeviceTransport transport;

  Future<int> send(
    Map<SportsLeague, List<GameData>> loadedGames, {
    GolfLeaderboard? loadedGolf,
  }) async {
    var sentLeagueCount = 0;
    for (final league in SportsLeague.values) {
      final games = loadedGames[league];
      try {
        if (league == SportsLeague.pga) {
          if (loadedGolf == null || loadedGolf.golfers.isEmpty) continue;
          await transport.sendGolfLeaderboard(loadedGolf);
        } else {
          if (games == null || games.isEmpty) continue;
          await transport.sendGameSlate(games);
        }
        sentLeagueCount++;
      } on Object catch (error) {
        throw LeagueSlateSendException(league, error);
      }
    }
    return sentLeagueCount;
  }
}
