import 'device_transport.dart';
import 'game_data.dart';
import 'golf_leaderboard.dart';
import 'golf_packet_serializer.dart';
import 'selected_game_auto_updater.dart';
import 'sports_league.dart';
import 'sports_repository.dart';

// TEMPORARY LIVE ACTIVITY/BACKGROUND BLE PROTOTYPE: Remove or refactor later.
class BackgroundScoreUpdater {
  BackgroundScoreUpdater({
    required this.repository,
    required this.transport,
    required this.isAppBackgrounded,
    required this.isBleConnected,
    required this.isLiveActivityActive,
    required this.trackedGame,
    this.trackedGolf,
    this.onDiagnostic,
  });

  final SportsRepository repository;
  final DeviceTransport transport;
  final bool Function() isAppBackgrounded;
  final bool Function() isBleConnected;
  final Future<bool> Function() isLiveActivityActive;
  final GameData? Function() trackedGame;
  final GolfLeaderboard? Function()? trackedGolf;
  final void Function(String message)? onDiagnostic;

  SelectedGameAutoUpdater? _selectedGameUpdater;
  bool _isRefreshing = false;

  Future<void> refreshTrackedGameOnce() async {
    if (_isRefreshing) {
      _diagnose('refresh ignored: another score_refresh is already running');
      return;
    }

    _isRefreshing = true;
    final game = trackedGame();
    final golf = trackedGolf?.call();
    final league = game == null ? null : _leagueFromGame(game);
    final selectedDate = game?.scheduledStartTime;
    try {
      if (!isAppBackgrounded()) {
        _diagnose('refresh skipped: app is not backgrounded');
        return;
      }
      final bleConnected = isBleConnected();
      _diagnose('BLE connected=$bleConnected');
      if (!bleConnected) {
        return;
      }
      if (golf != null) {
        await _refreshTrackedGolf(golf);
        return;
      }
      if (game == null || league == null || selectedDate == null) {
        _diagnose('tracked game ID=none; refresh skipped');
        return;
      }
      _diagnose('tracked game ID=${SelectedGameKey.fromGameData(game).id}');
      final liveActivityActive = await isLiveActivityActive();
      _diagnose('Live Activity active=$liveActivityActive');
      if (!liveActivityActive) {
        return;
      }
      if (!isAppBackgrounded() || !isBleConnected()) {
        _diagnose('refresh cancelled: conditions changed during setup');
        return;
      }

      _diagnose('refresh started');
      final updater = SelectedGameAutoUpdater(
        repository: repository,
        transport: transport,
        league: league,
        selectedDate: DateTime(
          selectedDate.year,
          selectedDate.month,
          selectedDate.day,
        ),
        selectedGame: game,
        lastSentGame: game,
        onError: (error) => _diagnose('one-shot refresh failed: $error'),
        onDiagnostic: _diagnose,
      );
      _selectedGameUpdater = updater;
      await updater.refreshNow();
      if (identical(_selectedGameUpdater, updater)) {
        _selectedGameUpdater = null;
      }
      updater.dispose();
    } on Object catch (error, stackTrace) {
      _diagnose('one-shot refresh failed: $error');
      _diagnose('one-shot refresh failure stack: $stackTrace');
    } finally {
      _isRefreshing = false;
    }
  }

  Future<void> _refreshTrackedGolf(GolfLeaderboard previous) async {
    final liveActivityActive = await isLiveActivityActive();
    _diagnose('Live Activity active=$liveActivityActive');
    if (!liveActivityActive || !isAppBackgrounded() || !isBleConnected()) {
      return;
    }
    _diagnose('PGA refresh started: TournamentID=${previous.tournamentId}');
    try {
      final fresh = await repository.fetchGolfLeaderboardByTournamentId(
        previous.tournamentId,
      );
      const serializer = GolfPacketSerializer();
      if (_listEquals(
        serializer.canonicalContent(previous),
        serializer.canonicalContent(fresh),
      )) {
        _diagnose('PGA no relevant change');
        return;
      }
      _diagnose('PGA change detected; BLE write attempted');
      await transport.sendGolfLeaderboard(fresh);
      _diagnose('PGA BLE write succeeded');
    } on Object catch (error) {
      _diagnose('PGA BLE write/refresh failed: $error');
    }
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  void cancelCurrentRefresh(String reason) {
    final updater = _selectedGameUpdater;
    updater?.pause();
    _selectedGameUpdater = null;
    if (updater != null) {
      _diagnose('one-shot refresh cancelled; reason=$reason');
    }
  }

  SportsLeague? _leagueFromGame(GameData game) {
    final leagueName = game.league.trim().toUpperCase();
    for (final league in SportsLeague.values) {
      if (league.label == leagueName) {
        return league;
      }
    }
    return null;
  }

  void _diagnose(String message) {
    onDiagnostic?.call(message);
  }
}
