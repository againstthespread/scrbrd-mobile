import 'device_transport.dart';
import 'game_data.dart';
import 'game_packet_serializer.dart';
import 'golf_leaderboard.dart';
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
  int _pgaWakeRefreshCount = 0;

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
    _pgaWakeRefreshCount++;
    final trackedLeaderboard = tracked.leaderboard;
    _diagnose('WAKE REFRESH #$_pgaWakeRefreshCount PGA');
    _diagnose(
      'PGA tracked baseline: tournament ID=${trackedLeaderboard.tournamentId}; '
      'tournament name=${trackedLeaderboard.tournamentName}; '
      'golfer count=${trackedLeaderboard.golfers.length}',
    );
    _diagnose('PGA tracked tournament=${trackedLeaderboard.tournamentId}');
    try {
      final fresh = await repository.fetchGolfLeaderboardByTournamentId(
        trackedLeaderboard.tournamentId,
      );
      _diagnose('PGA fetch succeeded; golfers=${fresh.golfers.length}');
      final trackedCanonical = _golfSerializer.canonicalContent(
        trackedLeaderboard,
      );
      final freshCanonical = _golfSerializer.canonicalContent(fresh);
      final equal = _bytesEqual(trackedCanonical, freshCanonical);
      _diagnose(
        'PGA canonical comparison: tracked canonical bytes='
        '${trackedCanonical.length}; fresh canonical bytes='
        '${freshCanonical.length}; equal=$equal',
      );
      if (equal) {
        _diagnose('PGA no update: no relevant change');
        return;
      }
      _diagnoseGolfDifferences(trackedLeaderboard, fresh);
      _diagnose('PGA change detected');
      if (!await _canContinue()) {
        _diagnose(
          'PGA update not sent: BLE/background requirements unavailable',
        );
        return;
      }
      _diagnose('PGA transfer started');
      final sender = transport;
      if (sender is SessionAwareDeviceSender) {
        await sender.sendGolf(fresh, selectedDate: tracked.selectedDate);
      } else {
        await sender.sendGolfLeaderboard(fresh);
        session.recordGolf(fresh, selectedDate: tracked.selectedDate);
      }
      _diagnose('PGA transfer succeeded');
      _diagnose('PGA baseline replaced');
    } on Object catch (error) {
      _diagnose('PGA no update: refresh/transfer failed: $error');
    }
  }

  void _diagnoseGolfDifferences(
    GolfLeaderboard tracked,
    GolfLeaderboard fresh,
  ) {
    if (tracked.tournamentId != fresh.tournamentId) {
      _diagnose(
        'PGA difference: tournamentId tracked=${tracked.tournamentId} '
        'fresh=${fresh.tournamentId}',
      );
    }
    if (tracked.tournamentName != fresh.tournamentName) {
      _diagnose(
        'PGA difference: tournamentName tracked=${tracked.tournamentName} '
        'fresh=${fresh.tournamentName}',
      );
    }
    if (tracked.golfers.length != fresh.golfers.length) {
      _diagnose(
        'PGA difference: golfer count tracked=${tracked.golfers.length} '
        'fresh=${fresh.golfers.length}',
      );
    }

    final trackedById = {
      for (final golfer in tracked.golfers) golfer.playerId: golfer,
    };
    final freshById = {
      for (final golfer in fresh.golfers) golfer.playerId: golfer,
    };
    var logged = 0;
    for (final playerId in {...trackedById.keys, ...freshById.keys}) {
      final oldRow = trackedById[playerId];
      final newRow = freshById[playerId];
      if (oldRow == null || newRow == null) {
        _diagnose(
          'PGA difference: playerId=$playerId; '
          'tracked=${oldRow == null ? 'missing' : 'present'}; '
          'fresh=${newRow == null ? 'missing' : 'present'}',
        );
        if (++logged == 3) return;
        continue;
      }
      final trackedIndex = tracked.golfers.indexOf(oldRow);
      final freshIndex = fresh.golfers.indexOf(newRow);
      if (oldRow.name == newRow.name &&
          oldRow.rank == newRow.rank &&
          oldRow.score == newRow.score &&
          oldRow.detail == newRow.detail &&
          trackedIndex == freshIndex) {
        continue;
      }
      _diagnose(
        'PGA difference: playerId=$playerId; name=${newRow.name}; '
        'tracked rank=${oldRow.rank} score=${oldRow.score} '
        'detail=${oldRow.detail ?? '<none>'} position=$trackedIndex; '
        'fresh rank=${newRow.rank} score=${newRow.score} '
        'detail=${newRow.detail ?? '<none>'} position=$freshIndex',
      );
      if (++logged == 3) return;
    }
    if (logged == 0) {
      _diagnose('PGA difference: canonical metadata changed');
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
