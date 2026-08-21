import 'dart:collection';

import 'game_data.dart';
import 'golf_leaderboard.dart';
import 'sports_league.dart';

sealed class TrackedLeagueContent {
  const TrackedLeagueContent(this.league);

  final SportsLeague league;
}

class TrackedTeamSlate extends TrackedLeagueContent {
  TrackedTeamSlate({
    required SportsLeague league,
    required DateTime selectedDate,
    required List<GameData> games,
  }) : selectedDate = DateTime(
         selectedDate.year,
         selectedDate.month,
         selectedDate.day,
       ),
       games = List<GameData>.unmodifiable(games),
       super(league) {
    if (league == SportsLeague.pga || games.isEmpty) {
      throw ArgumentError('A tracked team slate requires team-sport games.');
    }
  }

  final DateTime selectedDate;
  final List<GameData> games;
}

class TrackedGolfLeaderboard extends TrackedLeagueContent {
  TrackedGolfLeaderboard({
    required GolfLeaderboard leaderboard,
    this.selectedDate,
  }) : leaderboard = GolfLeaderboard(
         tournamentId: leaderboard.tournamentId,
         tournamentName: leaderboard.tournamentName,
         golfers: List<GolfLeaderboardRow>.unmodifiable(leaderboard.golfers),
         isInProgress: leaderboard.isInProgress,
         isOver: leaderboard.isOver,
       ),
       super(SportsLeague.pga);

  final GolfLeaderboard leaderboard;
  final DateTime? selectedDate;
}

class TrackedDeviceSession {
  final Map<SportsLeague, TrackedLeagueContent> _entries = {};

  UnmodifiableMapView<SportsLeague, TrackedLeagueContent> snapshot() =>
      UnmodifiableMapView(Map<SportsLeague, TrackedLeagueContent>.of(_entries));

  TrackedLeagueContent? operator [](SportsLeague league) => _entries[league];

  void recordTeamSlate({
    required SportsLeague league,
    required DateTime selectedDate,
    required List<GameData> games,
  }) {
    _entries[league] = TrackedTeamSlate(
      league: league,
      selectedDate: selectedDate,
      games: games,
    );
  }

  void recordGolf(GolfLeaderboard leaderboard, {DateTime? selectedDate}) {
    _entries[SportsLeague.pga] = TrackedGolfLeaderboard(
      leaderboard: leaderboard,
      selectedDate: selectedDate,
    );
  }

  void remove(SportsLeague league) => _entries.remove(league);
}
