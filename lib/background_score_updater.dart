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

  Future<void> refreshTrackedContentOnce() async {
    if (_isRefreshing) {
      _diagnose('refresh skipped because another refresh is in progress');
      return;
    }

    _isRefreshing = true;
    try {
      final bleConnected = isBleConnected();
      _diagnose('BLE connected=$bleConnected');
      if (!bleConnected) return;
      if (!await _canContinueRefresh()) return;

      final golf = trackedGolf?.call();
      if (golf != null) {
        _diagnose('tracked content type=PGA');
        _diagnose('tracked tournament ID=${golf.tournamentId}');
        await _refreshTrackedGolf(golf);
        return;
      }

      final game = trackedGame();
      if (game != null) {
        _diagnose('tracked content type=team');
        _diagnose('tracked event ID=${SelectedGameKey.fromGameData(game).id}');
        await _refreshTrackedTeam(game);
        return;
      }
      _diagnose('refresh skipped: no tracked content');
    } on Object catch (error, stackTrace) {
      _diagnose('wake refresh failed; waiting for next BLE wake: $error');
      _diagnose('wake refresh failure stack: $stackTrace');
    } finally {
      _isRefreshing = false;
    }
  }

  Future<void> _refreshTrackedTeam(GameData game) async {
    final league = _leagueFromGame(game);
    final selectedDate = game.scheduledStartTime;
    if (league == null || selectedDate == null) {
      _diagnose('team refresh skipped: tracked game metadata is incomplete');
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
      canSend: _canContinueRefresh,
      onError: (error) => _diagnose('team refresh failed: $error'),
      onDiagnostic: _diagnose,
    );
    _selectedGameUpdater = updater;
    await updater.refreshNow();
    if (identical(_selectedGameUpdater, updater)) {
      _selectedGameUpdater = null;
    }
    updater.dispose();
  }

  Future<void> _refreshTrackedGolf(GolfLeaderboard previous) async {
    try {
      _diagnose('refresh started');
      final fresh = await repository.fetchGolfLeaderboardByTournamentId(
        previous.tournamentId,
      );
      _diagnose('fetch succeeded');
      _diagnose('tracked content found=true');
      const serializer = GolfPacketSerializer();
      if (_listEquals(
        serializer.canonicalContent(previous),
        serializer.canonicalContent(fresh),
      )) {
        _diagnose('PGA no relevant change');
        return;
      }
      _diagnose('PGA change detected; BLE write attempted');
      if (!await _canContinueRefresh()) return;
      await transport.sendGolfLeaderboard(fresh);
      _diagnose('PGA BLE write succeeded');
    } on Object catch (error) {
      _diagnose('PGA BLE write failed: $error');
    }
  }

  Future<bool> _canContinueRefresh() async {
    if (!isBleConnected()) {
      _diagnose('refresh cancelled: BLE disconnected');
      return false;
    }
    if (!isAppBackgrounded()) return true;
    final liveActivityActive = await isLiveActivityActive();
    _diagnose('Live Activity active=$liveActivityActive');
    if (!liveActivityActive) {
      _diagnose('refresh cancelled: background Live Activity is inactive');
    }
    return liveActivityActive;
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
