import 'device_transport.dart';
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

  bool _isRefreshing = false;
  bool _cancelled = false;
  int _wakeRefreshCount = 0;
  int _pgaWakeRefreshCount = 0;
  final Map<SportsLeague, Set<String>> _pendingTeamShrinkage = {};

  Future<void> refreshTrackedSessionOnce() async {
    if (_isRefreshing) {
      _diagnose('refresh skipped because another refresh is in progress');
      return;
    }
    _isRefreshing = true;
    _cancelled = false;
    final wakeNumber = ++_wakeRefreshCount;
    try {
      if (!_canContinue()) return;
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
          _fetch(wakeNumber, content, favorites, collegePreferences),
      ]);
      _diagnose('WAKE REFRESH #$wakeNumber fetch phase complete');
      if (!_canContinue()) return;

      _diagnose('WAKE REFRESH #$wakeNumber send phase started');
      for (final result in results) {
        if (!_canContinue()) break;
        await _compareAndSend(wakeNumber, result);
      }
      _diagnose('WAKE REFRESH #$wakeNumber complete');
    } finally {
      _isRefreshing = false;
    }
  }

  Future<_LeagueFetchResult> _fetch(
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

  Future<void> _compareAndSend(
    int wakeNumber,
    _LeagueFetchResult result,
  ) async {
    if (result.error != null) {
      _diagnose(
        'WAKE #$wakeNumber ${result.tracked.league.label} no update: '
        'fetch failed; baseline retained',
      );
      return;
    }
    final tracked = result.tracked;
    if (tracked is TrackedTeamSlate) {
      await _compareAndSendTeam(
        wakeNumber,
        tracked,
        result.fresh! as List<GameData>,
      );
    } else if (tracked is TrackedGolfLeaderboard) {
      await _compareAndSendGolf(
        wakeNumber,
        tracked,
        result.fresh! as GolfLeaderboard,
      );
    }
  }

  Future<void> _compareAndSendTeam(
    int wakeNumber,
    TrackedTeamSlate tracked,
    List<GameData> fresh,
  ) async {
    final label = tracked.league.label;
    try {
      if (fresh.isEmpty) {
        _diagnose('WAKE #$wakeNumber $label empty; baseline retained');
        return;
      }
      if (!_teamMembershipChangeIsSafe(tracked, fresh)) return;
      if (_bytesEqual(
        _gameSerializer.canonicalSlateContent(tracked.games),
        _gameSerializer.canonicalSlateContent(fresh),
      )) {
        _diagnose('WAKE #$wakeNumber $label unchanged');
        return;
      }
      _diagnose('WAKE #$wakeNumber $label changed');
      if (!_canContinue()) return;
      _diagnose('WAKE #$wakeNumber $label transfer started');
      await _sendTeam(fresh, tracked);
      _pendingTeamShrinkage.remove(tracked.league);
      _diagnose('WAKE #$wakeNumber $label transfer succeeded');
    } on Object catch (error) {
      _diagnose('WAKE #$wakeNumber $label transfer failed: $error');
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

  Future<void> _compareAndSendGolf(
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
        return;
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
        return;
      }
      _diagnoseGolfDifferences(trackedLeaderboard, fresh);
      _diagnose('WAKE #$wakeNumber PGA changed');
      _diagnose('PGA change detected');
      if (!_canContinue()) {
        _diagnose('PGA update not sent: BLE disconnected or refresh cancelled');
        return;
      }
      _diagnose('WAKE #$wakeNumber PGA transfer started');
      _diagnose('PGA transfer started');
      final sender = transport;
      if (sender is SessionAwareDeviceSender) {
        await sender.sendGolf(fresh, selectedDate: tracked.selectedDate);
      } else {
        await sender.sendGolfLeaderboard(fresh);
        session.recordGolf(fresh, selectedDate: tracked.selectedDate);
      }
      _diagnose('WAKE #$wakeNumber PGA transfer succeeded');
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

  bool _canContinue() {
    if (_cancelled || !isBleConnected()) {
      _diagnose('refresh cancelled: BLE disconnected or coordinator stopped');
      return false;
    }
    _diagnose('BLE connected=true; refresh permitted');
    return true;
  }

  void cancelCurrentRefresh(String reason) {
    _cancelled = true;
    _pendingTeamShrinkage.clear();
    _diagnose('refresh cancellation requested; reason=$reason');
  }

  bool _teamMembershipChangeIsSafe(
    TrackedTeamSlate tracked,
    List<GameData> fresh,
  ) {
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

    final candidate = _pendingTeamShrinkage[tracked.league];
    if (candidate != null &&
        candidate.length == missingIds.length &&
        candidate.containsAll(missingIds)) {
      _diagnose(
        '$label slate shrinkage confirmed; '
        'missingEventIds=${_sortedIds(missingIds)}; transfer permitted',
      );
      return true;
    }

    _pendingTeamShrinkage[tracked.league] = Set<String>.unmodifiable(
      missingIds,
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
