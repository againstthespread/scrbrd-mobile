import 'device_transport.dart';
import 'game_data.dart';
import 'game_packet_serializer.dart';
import 'golf_packet_serializer.dart';
import 'session_aware_device_sender.dart';
import 'sports_league.dart';
import 'sports_repository.dart';
import 'tracked_device_session.dart';

class LiveRefreshCoordinator {
  LiveRefreshCoordinator({
    required this.repository,
    required this.transport,
    required this.session,
    required this.isAppBackgrounded,
    required this.isBleConnected,
    required this.isLiveActivityActive,
    this.onDiagnostic,
  });

  final SportsRepository repository;
  final DeviceTransport transport;
  final TrackedDeviceSession session;
  final bool Function() isAppBackgrounded;
  final bool Function() isBleConnected;
  final Future<bool> Function() isLiveActivityActive;
  final void Function(String message)? onDiagnostic;
  final GamePacketSerializer _gameSerializer = const GamePacketSerializer();
  final GolfPacketSerializer _golfSerializer = const GolfPacketSerializer();

  bool _isRefreshing = false;
  bool _cancelled = false;

  Future<void> refreshTrackedSessionOnce() async {
    if (_isRefreshing) {
      _diagnose('refresh skipped because another refresh is in progress');
      return;
    }
    _isRefreshing = true;
    _cancelled = false;
    try {
      if (!await _canContinue()) return;
      final snapshot = session.snapshot();
      _diagnose('refresh started; tracked leagues=${snapshot.length}');
      for (final league in SportsLeague.values) {
        if (!await _canContinue()) break;
        final content = snapshot[league];
        if (content == null) continue;
        if (content is TrackedTeamSlate) {
          await _refreshTeam(content);
        } else if (content is TrackedGolfLeaderboard) {
          await _refreshGolf(content);
        }
      }
    } finally {
      _isRefreshing = false;
    }
  }

  Future<void> _refreshTeam(TrackedTeamSlate tracked) async {
    _diagnose('tracked content type=team; league=${tracked.league.label}');
    try {
      final fresh = await repository.fetchGamesForDate(
        tracked.league,
        tracked.selectedDate,
      );
      _diagnose(
        '${tracked.league.label} fetch succeeded; games=${fresh.length}',
      );
      if (fresh.isEmpty) {
        _diagnose(
          '${tracked.league.label} refresh ignored: transient empty slate',
        );
        return;
      }
      if (_bytesEqual(
        _gameSerializer.canonicalSlateContent(tracked.games),
        _gameSerializer.canonicalSlateContent(fresh),
      )) {
        _diagnose('${tracked.league.label} no relevant change');
        return;
      }
      _diagnose(
        '${tracked.league.label} change detected; full slate write attempted',
      );
      if (!await _canContinue()) return;
      await _sendTeam(fresh, tracked);
      _diagnose('${tracked.league.label} BLE write succeeded');
    } on Object catch (error) {
      _diagnose('${tracked.league.label} refresh/write failed: $error');
    }
  }

  Future<void> _sendTeam(List<GameData> games, TrackedTeamSlate tracked) async {
    final sender = transport;
    if (sender is SessionAwareDeviceSender) {
      await sender.sendTeamSlate(games, selectedDate: tracked.selectedDate);
    } else {
      await sender.sendGameSlate(games);
      session.recordTeamSlate(
        league: tracked.league,
        selectedDate: tracked.selectedDate,
        games: games,
      );
    }
  }

  Future<void> _refreshGolf(TrackedGolfLeaderboard tracked) async {
    _diagnose(
      'tracked content type=PGA; tournament ID=${tracked.leaderboard.tournamentId}',
    );
    try {
      final fresh = await repository.fetchGolfLeaderboardByTournamentId(
        tracked.leaderboard.tournamentId,
      );
      _diagnose('PGA fetch succeeded; golfers=${fresh.golfers.length}');
      if (_bytesEqual(
        _golfSerializer.canonicalContent(tracked.leaderboard),
        _golfSerializer.canonicalContent(fresh),
      )) {
        _diagnose('PGA no relevant change');
        return;
      }
      _diagnose('PGA change detected; full leaderboard write attempted');
      if (!await _canContinue()) return;
      final sender = transport;
      if (sender is SessionAwareDeviceSender) {
        await sender.sendGolf(fresh, selectedDate: tracked.selectedDate);
      } else {
        await sender.sendGolfLeaderboard(fresh);
        session.recordGolf(fresh, selectedDate: tracked.selectedDate);
      }
      _diagnose('PGA BLE write succeeded');
    } on Object catch (error) {
      _diagnose('PGA refresh/write failed: $error');
    }
  }

  Future<bool> _canContinue() async {
    if (_cancelled || !isBleConnected()) {
      _diagnose('refresh cancelled: BLE disconnected or coordinator stopped');
      return false;
    }
    if (!isAppBackgrounded()) return true;
    final active = await isLiveActivityActive();
    _diagnose('Live Activity active=$active');
    return active;
  }

  void cancelCurrentRefresh(String reason) {
    _cancelled = true;
    _diagnose('refresh cancellation requested; reason=$reason');
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  void _diagnose(String message) => onDiagnostic?.call(message);
}
