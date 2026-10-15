import 'device_transport.dart';
import 'logical_device_transaction.dart';
import 'game_data.dart';
import 'game_packet_serializer.dart';
import 'golf_leaderboard.dart';
import 'golf_packet_serializer.dart';
import 'session_aware_device_sender.dart';
import 'sports_league.dart';
import 'sports_repository.dart';
import 'tracked_device_session.dart';
import 'favorite_game_prioritizer.dart';
import 'favorite_team.dart';
import 'college_football.dart';
import 'power_four_game_filter.dart';

enum SportsRefreshOutcome {
  unchanged,
  written,
  retained,
  failed,
  cancelled,
  skipped,
}

class SportsRefreshResult {
  const SportsRefreshResult({
    this.leagues = const {},
    this.cancelled = false,
    this.skipped = false,
  });
  final Map<SportsLeague, SportsRefreshOutcome> leagues;
  final bool cancelled;
  final bool skipped;
  bool get succeeded =>
      !cancelled &&
      !skipped &&
      leagues.values.every(
        (s) =>
            s == SportsRefreshOutcome.unchanged ||
            s == SportsRefreshOutcome.written,
      );
}

class LiveRefreshCoordinator {
  LiveRefreshCoordinator({
    required this.repository,
    required this.transport,
    required this.session,
    required this.isBleConnected,
    this.onDiagnostic,
    this.readFavorites,
    this.readCollegeFootballPreferences,
  });

  final SportsRepository repository;
  final DeviceTransport transport;
  final TrackedDeviceSession session;
  final bool Function() isBleConnected;
  final void Function(String message)? onDiagnostic;
  final Set<FavoriteTeam> Function()? readFavorites;
  final CollegeFootballPreferences Function()? readCollegeFootballPreferences;
  final GamePacketSerializer _gameSerializer = const GamePacketSerializer();
  final GolfPacketSerializer _golfSerializer = const GolfPacketSerializer();

  _RefreshRun? _activeRun;
  int _wakeRefreshCount = 0;
  int _pgaWakeRefreshCount = 0;
  final Map<SportsLeague, ({DateTime date, Set<String> ids})>
  _pendingTeamShrinkage = {};

  Future<SportsRefreshResult> refreshTrackedSessionOnce() async {
    if (_activeRun != null) {
      _diagnose('refresh skipped because another refresh is in progress');
      return const SportsRefreshResult(skipped: true);
    }
    final run = _activeRun = _RefreshRun();
    final wakeNumber = ++_wakeRefreshCount;
    final outcomes = <SportsLeague, SportsRefreshOutcome>{};
    try {
      if (!_canContinue(run)) {
        return SportsRefreshResult(
          leagues: Map.unmodifiable(outcomes),
          cancelled: true,
        );
      }
      final snapshot = session.snapshot();
      final favorites = readFavorites?.call() ?? const <FavoriteTeam>{};
      final collegePreferences =
          readCollegeFootballPreferences?.call() ??
          CollegeFootballPreferences.defaults();
      final tracked = SportsLeague.values
          .map((league) => snapshot[league])
          .nonNulls
          .toList();
      final labels = tracked.map((content) => content.league.label).join(',');
      _diagnose(
        'WAKE REFRESH #$wakeNumber fetch phase started; leagues=$labels',
      );

      final results = await Future.wait([
        for (final content in tracked)
          _fetch(run, wakeNumber, content, favorites, collegePreferences),
      ]);
      _diagnose('WAKE REFRESH #$wakeNumber fetch phase complete');
      if (!_canContinue(run)) {
        return SportsRefreshResult(
          leagues: Map.unmodifiable(outcomes),
          cancelled: true,
        );
      }

      _diagnose('WAKE REFRESH #$wakeNumber send phase started');
      for (final result in results) {
        if (!_canContinue(run)) break;
        try {
          outcomes[result.tracked.league] = await runDeviceTransaction(
            transport,
            () async {
              // Manual sends may have replaced this baseline while fetching or
              // waiting for ownership. Never overwrite that newer selection.
              if (!identical(session[result.tracked.league], result.tracked)) {
                return SportsRefreshOutcome.cancelled;
              }
              return _compareAndSend(run, wakeNumber, result);
            },
            isCurrent: () => _canContinue(run),
          );
        } on Object catch (error) {
          _diagnose('delivery ownership failed: ${error.runtimeType}');
          outcomes[result.tracked.league] = _canContinue(run)
              ? SportsRefreshOutcome.failed
              : SportsRefreshOutcome.cancelled;
        }
      }
      final result = SportsRefreshResult(
        leagues: Map.unmodifiable(outcomes),
        cancelled: run.cancelled || !isBleConnected(),
      );
      _diagnose(
        'WAKE REFRESH #$wakeNumber complete; success=${result.succeeded}',
      );
      return result;
    } on Object catch (error) {
      _diagnose('refresh failed: ${error.runtimeType}');
      return SportsRefreshResult(
        skipped: true,
        leagues: Map.unmodifiable(outcomes),
        cancelled: !_canContinue(run),
      );
    } finally {
      if (identical(_activeRun, run)) _activeRun = null;
    }
  }

  Future<_LeagueFetchResult> _fetch(
    _RefreshRun run,
    int wakeNumber,
    TrackedLeagueContent tracked,
    Set<FavoriteTeam> favorites,
    CollegeFootballPreferences collegePreferences,
  ) async {
    final label = tracked.league.label;
    _diagnose('WAKE #$wakeNumber $label fetch started');
    try {
      final Object fresh;
      if (tracked is TrackedTeamSlate) {
        final games = await repository.fetchGamesForDate(
          tracked.league,
          tracked.selectedDate,
          isCurrent: () => !run.cancelled && isBleConnected(),
        );
        final filtered = applyCollegeFootballFilter(
          tracked.league,
          games,
          collegePreferences,
        );
        fresh = const FavoriteGamePrioritizer().prioritize(
          tracked.league,
          filtered,
          favorites,
        );
      } else if (tracked is TrackedGolfLeaderboard) {
        fresh = await repository.fetchGolfLeaderboardByTournamentId(
          tracked.leaderboard.tournamentId,
          isCurrent: () => !run.cancelled && isBleConnected(),
        );
      } else {
        throw StateError('Unsupported tracked content for $label');
      }
      _diagnose('WAKE #$wakeNumber $label fetch completed');
      return _LeagueFetchResult(tracked: tracked, fresh: fresh);
    } on Object catch (error) {
      _diagnose('WAKE #$wakeNumber $label fetch failed: $error');
      return _LeagueFetchResult(tracked: tracked, error: error);
    }
  }

  Future<SportsRefreshOutcome> _compareAndSend(
    _RefreshRun run,
    int wakeNumber,
    _LeagueFetchResult result,
  ) async {
    if (result.error != null) {
      _diagnose(
        'WAKE #$wakeNumber ${result.tracked.league.label} no update: '
        'fetch failed; baseline retained',
      );
      return SportsRefreshOutcome.failed;
    }
    final tracked = result.tracked;
    if (tracked is TrackedTeamSlate) {
      return _compareAndSendTeam(
        run,
        wakeNumber,
        tracked,
        result.fresh! as List<GameData>,
      );
    } else if (tracked is TrackedGolfLeaderboard) {
      return _compareAndSendGolf(
        run,
        wakeNumber,
        tracked,
        result.fresh! as GolfLeaderboard,
      );
    }
    return SportsRefreshOutcome.skipped;
  }

  Future<SportsRefreshOutcome> _compareAndSendTeam(
    _RefreshRun run,
    int wakeNumber,
    TrackedTeamSlate tracked,
    List<GameData> fresh,
  ) async {
    final label = tracked.league.label;
    try {
      if (fresh.isEmpty) {
        _diagnose('WAKE #$wakeNumber $label empty; baseline retained');
        repository.diagnosticHistory.deliveryState(
          'sports:${tracked.league.name}',
          'retained',
        );
        return SportsRefreshOutcome.retained;
      }
      if (!canReplaceTeamSlate(tracked, fresh)) {
        repository.diagnosticHistory.deliveryState(
          'sports:${tracked.league.name}',
          'retained',
        );
        return SportsRefreshOutcome.retained;
      }
      if (_bytesEqual(
        _gameSerializer.canonicalSlateContent(tracked.games),
        _gameSerializer.canonicalSlateContent(fresh),
      )) {
        _diagnose('WAKE #$wakeNumber $label unchanged');
        repository.diagnosticHistory.deliveryState(
          'sports:${tracked.league.name}',
          'unchanged',
        );
        return SportsRefreshOutcome.unchanged;
      }
      _diagnose('WAKE #$wakeNumber $label changed');
      if (!_canContinue(run)) return SportsRefreshOutcome.cancelled;
      _diagnose('WAKE #$wakeNumber $label transfer started');
      await _sendTeam(run, fresh, tracked);
      _pendingTeamShrinkage.remove(tracked.league);
      _diagnose(
        'WAKE #$wakeNumber $label transfer succeeded; BLE writes completed; ESP unconfirmed',
      );
      return SportsRefreshOutcome.written;
    } on Object catch (error) {
      _diagnose('WAKE #$wakeNumber $label transfer failed: $error');
      return run.cancelled || !isBleConnected()
          ? SportsRefreshOutcome.cancelled
          : SportsRefreshOutcome.failed;
    }
  }

  Future<void> _sendTeam(
    _RefreshRun run,
    List<GameData> games,
    TrackedTeamSlate tracked,
  ) async {
    final sender = transport;
    if (sender is SessionAwareDeviceSender) {
      await sender.sendTeamSlate(
        games,
        selectedDate: tracked.selectedDate,
        followsCurrentDate: tracked.followsCurrentDate,
        isCurrent: () => !run.cancelled && isBleConnected(),
      );
    } else {
      await repository.diagnosticHistory.trackDelivery(
        'sports:${tracked.league.name}',
        () => sender.sendGameSlate(games),
        isCurrent: () => !run.cancelled,
      );
      session.recordTeamSlate(
        league: tracked.league,
        selectedDate: tracked.selectedDate,
        games: games,
        followsCurrentDate: tracked.followsCurrentDate,
      );
    }
  }

  Future<SportsRefreshOutcome> _compareAndSendGolf(
    _RefreshRun run,
    int wakeNumber,
    TrackedGolfLeaderboard tracked,
    GolfLeaderboard fresh,
  ) async {
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
      if (fresh.golfers.isEmpty) {
        _diagnose('WAKE #$wakeNumber PGA empty; baseline retained');
        repository.diagnosticHistory.deliveryState('sports:pga', 'retained');
        return SportsRefreshOutcome.retained;
      }
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
        _diagnose('WAKE #$wakeNumber PGA unchanged');
        _diagnose('PGA no update: no relevant change');
        repository.diagnosticHistory.deliveryState('sports:pga', 'unchanged');
        return SportsRefreshOutcome.unchanged;
      }
      _diagnoseGolfDifferences(trackedLeaderboard, fresh);
      _diagnose('WAKE #$wakeNumber PGA changed');
      _diagnose('PGA change detected');
      if (!_canContinue(run)) {
        _diagnose('PGA update not sent: BLE disconnected or refresh cancelled');
        return SportsRefreshOutcome.cancelled;
      }
      _diagnose('WAKE #$wakeNumber PGA transfer started');
      _diagnose('PGA transfer started');
      final sender = transport;
      if (sender is SessionAwareDeviceSender) {
        await sender.sendGolf(
          fresh,
          selectedDate: tracked.selectedDate,
          followsCurrentDate: tracked.followsCurrentDate,
          isCurrent: () => !run.cancelled && isBleConnected(),
        );
      } else {
        await repository.diagnosticHistory.trackDelivery(
          'sports:pga',
          () => sender.sendGolfLeaderboard(fresh),
          isCurrent: () => !run.cancelled,
        );
        session.recordGolf(
          fresh,
          selectedDate: tracked.selectedDate,
          followsCurrentDate: tracked.followsCurrentDate,
        );
      }
      _diagnose('WAKE #$wakeNumber PGA transfer succeeded');
      _diagnose('PGA transfer succeeded');
      _diagnose('PGA baseline replaced');
      _diagnose('PGA BLE writes completed; ESP unconfirmed');
      return SportsRefreshOutcome.written;
    } on Object catch (error) {
      _diagnose('PGA no update: refresh/transfer failed: $error');
      return run.cancelled || !isBleConnected()
          ? SportsRefreshOutcome.cancelled
          : SportsRefreshOutcome.failed;
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

  bool _canContinue(_RefreshRun run) {
    if (run.cancelled || !isBleConnected()) {
      _diagnose('refresh cancelled: BLE disconnected or coordinator stopped');
      return false;
    }
    _diagnose('BLE connected=true; refresh permitted');
    return true;
  }

  void cancelCurrentRefresh(String reason) {
    _activeRun?.cancelled = true;
    _activeRun = null;
    _pendingTeamShrinkage.clear();
    _diagnose('refresh cancellation requested; reason=$reason');
  }

  /// Shared by discovery and live polling so same-date shrinkage still needs
  /// matching observations before replacing previously committed games.
  bool canReplaceTeamSlate(TrackedTeamSlate tracked, List<GameData> fresh) {
    final trackedIds = _stableEventIds(tracked.games);
    final freshIds = _stableEventIds(fresh);
    final hasUsableIdentity =
        trackedIds.length == tracked.games.length &&
        freshIds.length == fresh.length;
    final label = tracked.league.label;

    if (!hasUsableIdentity) {
      if (fresh.length < tracked.games.length) {
        _diagnose(
          '$label slate shrinkage suppressed: stable event IDs are missing '
          'or duplicated; baseline retained',
        );
        return false;
      }
      return true;
    }

    final missingIds = trackedIds.difference(freshIds);
    if (missingIds.isEmpty) {
      if (_pendingTeamShrinkage.remove(tracked.league) != null) {
        _diagnose(
          '$label slate shrinkage recovered; previously missing IDs returned',
        );
      }
      return true;
    }

    final pending = _pendingTeamShrinkage[tracked.league];
    final candidate = pending?.date == tracked.selectedDate
        ? pending?.ids
        : null;
    if (candidate != null &&
        candidate.length == missingIds.length &&
        candidate.containsAll(missingIds)) {
      _diagnose(
        '$label slate shrinkage confirmed; '
        'missingEventIds=${_sortedIds(missingIds)}; transfer permitted',
      );
      return true;
    }

    _pendingTeamShrinkage[tracked.league] = (
      date: tracked.selectedDate,
      ids: Set<String>.unmodifiable(missingIds),
    );
    if (candidate == null) {
      _diagnose(
        '$label slate shrinkage suspected; '
        'missingEventIds=${_sortedIds(missingIds)}; confirmation required',
      );
    } else {
      _diagnose(
        '$label slate shrinkage candidate changed; '
        'old=${_sortedIds(candidate)}; new=${_sortedIds(missingIds)}',
      );
    }
    return false;
  }

  Set<String> _stableEventIds(List<GameData> games) => {
    for (final game in games)
      if (game.eventId?.trim() case final id? when id.isNotEmpty) id,
  };

  List<String> _sortedIds(Set<String> ids) => ids.toList()..sort();

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  void _diagnose(String message) => onDiagnostic?.call(message);
}

class _LeagueFetchResult {
  const _LeagueFetchResult({required this.tracked, this.fresh, this.error});

  final TrackedLeagueContent tracked;
  final Object? fresh;
  final Object? error;
}

class _RefreshRun {
  bool cancelled = false;
}
