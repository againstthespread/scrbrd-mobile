import 'device_transport.dart';
import 'game_data.dart';
import 'golf_leaderboard.dart';
import 'sports_league.dart';
import 'tracked_device_session.dart';

class SessionAwareDeviceSender implements DeviceTransport {
  const SessionAwareDeviceSender({
    required this.transport,
    required this.session,
  });

  final DeviceTransport transport;
  final TrackedDeviceSession session;

  @override
  Future<void> sendControlCommand(String command) =>
      transport.sendControlCommand(command);

  @override
  Future<void> sendGameData(GameData gameData) async {
    await transport.sendGameData(gameData);
    final league = _leagueFor(gameData.league);
    final start = gameData.scheduledStartTime;
    if (league == null ||
        league == SportsLeague.pga ||
        start == null ||
        gameData.eventId?.trim().isEmpty != false) {
      if (league != null) session.remove(league);
      return;
    }
    session.recordTeamSlate(
      league: league,
      selectedDate: start,
      games: [gameData],
    );
  }

  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    final start = games.isEmpty ? null : games.first.scheduledStartTime;
    if (start == null) {
      await transport.sendGameSlate(games);
      final league = games.isEmpty ? null : _leagueFor(games.first.league);
      if (league != null) session.remove(league);
      return;
    }
    await sendTeamSlate(games, selectedDate: start);
  }

  Future<void> sendTeamSlate(
    List<GameData> games, {
    required DateTime selectedDate,
  }) async {
    await transport.sendGameSlate(games);
    final league = _leagueFor(games.first.league);
    if (league == null || league == SportsLeague.pga) return;
    session.recordTeamSlate(
      league: league,
      selectedDate: selectedDate,
      games: games,
    );
  }

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {
    await sendGolf(leaderboard);
  }

  Future<void> sendGolf(
    GolfLeaderboard leaderboard, {
    DateTime? selectedDate,
  }) async {
    await transport.sendGolfLeaderboard(leaderboard);
    session.recordGolf(leaderboard, selectedDate: selectedDate);
  }

  SportsLeague? _leagueFor(String label) {
    final normalized = label.trim().toUpperCase();
    for (final league in SportsLeague.values) {
      if (league.label == normalized) return league;
    }
    return null;
  }
}
