import 'refresh_diagnostic_history.dart';
import 'device_transport.dart';
import 'logical_device_transaction.dart';
import 'fantasy_point_alert.dart';
import 'fantasy_alert_transport.dart';
import 'fantasy_matchup_display_data.dart';
import 'fantasy_matchup_transport.dart';
import 'game_data.dart';
import 'golf_leaderboard.dart';
import 'sports_league.dart';
import 'tracked_device_session.dart';

class SessionAwareDeviceSender
    implements
        DeviceTransport,
        FantasyAlertTransport,
        FantasyMatchupTransport,
        FantasySlateTransport,
        LogicalDeviceTransport {
  const SessionAwareDeviceSender({
    required this.transport,
    required this.session,
    this.diagnosticHistory,
  });

  final RefreshDiagnosticHistory? diagnosticHistory;
  RefreshDiagnosticHistory get history =>
      diagnosticHistory ?? RefreshDiagnosticHistory.session;
  final DeviceTransport transport;
  final TrackedDeviceSession session;

  @override
  Future<T> runTransaction<T>(
    Future<T> Function() operation, {
    bool Function()? isCurrent,
  }) => runDeviceTransaction(transport, operation, isCurrent: isCurrent);

  @override
  Future<void> sendControlCommand(String command) =>
      transport.sendControlCommand(command);

  @override
  Future<void> sendGameData(GameData gameData) {
    return runTransaction(() async {
      await history.trackDelivery(
        'sports:${gameData.league.toLowerCase()}',
        () => transport.sendGameData(gameData),
        scope: 'manual packet',
      );
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
    });
  }

  @override
  Future<void> sendGameSlate(List<GameData> games) {
    games = List.unmodifiable(games);
    return runTransaction(() async {
      final start = games.isEmpty ? null : games.first.scheduledStartTime;
      if (start == null) {
        await history.trackDelivery(
          'sports:${games.isEmpty ? 'unknown' : games.first.league.toLowerCase()}',
          () => transport.sendGameSlate(games),
          scope: 'manual slate',
        );
        final league = games.isEmpty ? null : _leagueFor(games.first.league);
        if (league != null) session.remove(league);
        return;
      }
      await sendTeamSlate(games, selectedDate: start);
    });
  }

  Future<void> sendTeamSlate(
    List<GameData> games, {
    required DateTime selectedDate,
    bool followsCurrentDate = false,
    bool Function()? isCurrent,
  }) {
    games = List.unmodifiable(games);
    return runTransaction(() async {
      await history.trackDelivery(
        'sports:${games.first.league.toLowerCase()}',
        () => transport.sendGameSlate(games),
        scope: selectedDate.toIso8601String().substring(0, 10),
        isCurrent: isCurrent,
      );
      if (isCurrent?.call() == false) {
        throw StateError('BLE slate cancelled; session changed.');
      }
      final league = _leagueFor(games.first.league);
      if (league == null || league == SportsLeague.pga) return;
      session.recordTeamSlate(
        league: league,
        selectedDate: selectedDate,
        games: games,
        followsCurrentDate: followsCurrentDate,
      );
    }, isCurrent: isCurrent);
  }

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {
    await sendGolf(leaderboard);
  }

  @override
  Future<void> sendFantasyAlert(FantasyPointAlert alert) {
    final fantasyTransport = transport;
    if (fantasyTransport is! FantasyAlertTransport) {
      throw UnsupportedError('Fantasy-alert transport is unavailable.');
    }
    return (fantasyTransport as FantasyAlertTransport).sendFantasyAlert(alert);
  }

  @override
  Future<void> sendFantasyMatchup(FantasyMatchupDisplayData matchup) {
    final fantasyTransport = transport;
    if (fantasyTransport is! FantasyMatchupTransport) {
      throw UnsupportedError('Fantasy-matchup transport is unavailable.');
    }
    return (fantasyTransport as FantasyMatchupTransport).sendFantasyMatchup(
      matchup,
    );
  }

  @override
  Future<void> sendFantasySlate(List<FantasyMatchupSlateEntry> entries) {
    final fantasyTransport = transport;
    if (fantasyTransport is! FantasySlateTransport) {
      throw UnsupportedError('Fantasy-slate transport is unavailable.');
    }
    return (fantasyTransport as FantasySlateTransport).sendFantasySlate(
      entries,
    );
  }

  @override
  Future<void> clearFantasyMatchup() {
    final fantasyTransport = transport;
    if (fantasyTransport is! FantasyMatchupTransport) {
      throw UnsupportedError('Fantasy-matchup transport is unavailable.');
    }
    return (fantasyTransport as FantasyMatchupTransport).clearFantasyMatchup();
  }

  Future<void> sendGolf(
    GolfLeaderboard leaderboard, {
    DateTime? selectedDate,
    bool followsCurrentDate = false,
    bool Function()? isCurrent,
  }) {
    return runTransaction(() async {
      await history.trackDelivery(
        'sports:pga',
        () => transport.sendGolfLeaderboard(leaderboard),
        scope: 'tournament:${leaderboard.tournamentId}',
        isCurrent: isCurrent,
      );
      if (isCurrent?.call() == false) {
        throw StateError('BLE golf cancelled; session changed.');
      }
      session.recordGolf(
        leaderboard,
        selectedDate: selectedDate,
        followsCurrentDate: followsCurrentDate,
      );
    }, isCurrent: isCurrent);
  }

  SportsLeague? _leagueFor(String label) {
    final normalized = label.trim().toUpperCase();
    for (final league in SportsLeague.values) {
      if (league.label == normalized) return league;
    }
    return null;
  }
}
