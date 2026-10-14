import 'dart:async';

import 'ble_device_state.dart';
import 'game_data.dart';
import 'golf_leaderboard.dart';
import 'game_packet_serializer.dart';
import 'golf_packet_serializer.dart';
import 'fantasy_startup_outcome.dart';
import 'fantasy_matchup_transport.dart';
import 'session_aware_device_sender.dart';
import 'sports_operation_gate.dart';
import 'sports_repository.dart';
import 'favorite_game_prioritizer.dart';
import 'favorite_team.dart';
import 'device_content_preferences.dart';
import 'college_football.dart';
import 'power_four_game_filter.dart';

enum InitialSyncStatus {
  idle,
  syncing,
  complete,
  empty,
  partialFailure,
  failure,
}

class InitialSyncSnapshot {
  const InitialSyncSnapshot({
    required this.status,
    this.successfullySyncedLeagueCount = 0,
    this.lastErrorSummary,
    this.cachedContentMayBeStale = false,
  });

  final InitialSyncStatus status;
  final int successfullySyncedLeagueCount;
  final String? lastErrorSummary;
  final bool cachedContentMayBeStale;
}

class InitialDeviceSyncCoordinator {
  InitialDeviceSyncCoordinator({
    required this.repository,
    required this.sender,
    required this.isBleConnected,
    DateTime Function()? clock,
    SportsOperationGate? operationGate,
    this.onStatusChanged,
    this.onDiagnostic,
    this.onInitialSyncComplete,
    this.readFavorites,
    this.readContentPreferences,
    this.prepareFantasyCategory,
    this.onAuthoritativeSyncStarted,
    this.readCollegeFootballPreferences,
  }) : clock = clock ?? DateTime.now,
       operationGate = operationGate ?? SportsOperationGate();

  static const syncStartCommand = 'SYNC_START';
  static const syncCompleteCommand = 'SYNC_COMPLETE';
  static const syncEmptyCommand = 'SYNC_EMPTY';

  final SportsRepository repository;
  final SessionAwareDeviceSender sender;
  final bool Function() isBleConnected;
  final DateTime Function() clock;
  final SportsOperationGate operationGate;
  final void Function(InitialSyncSnapshot snapshot)? onStatusChanged;
  final void Function(String message)? onDiagnostic;
  final Future<void> Function()? onInitialSyncComplete;
  final Set<FavoriteTeam> Function()? readFavorites;
  final DeviceContentPreferences Function()? readContentPreferences;
  final Future<PreparedFantasyStartup> Function()? prepareFantasyCategory;
  final void Function()? onAuthoritativeSyncStarted;
  final CollegeFootballPreferences Function()? readCollegeFootballPreferences;

  InitialSyncSnapshot _snapshot = const InitialSyncSnapshot(
    status: InitialSyncStatus.idle,
  );
  bool _connectionSessionActive = false;
  int _connectionGeneration = 0;
  bool _needsRetry = false;
  Future<void>? _runningSync;
  int? _runningGeneration;

  bool get needsRetry => _needsRetry;

  InitialSyncSnapshot get snapshot => _snapshot;

  void handleConnectionState(BleConnectionState state) {
    if (state == BleConnectionState.disconnected ||
        state == BleConnectionState.error) {
      if (_connectionSessionActive) {
        _diagnose('Initial sync connection session ended');
      }
      _connectionSessionActive = false;
      _needsRetry = false;
      _connectionGeneration++;
      return;
    }
    if (state != BleConnectionState.connected || _connectionSessionActive) {
      return;
    }
    _connectionSessionActive = true;
    _needsRetry = false;
    final generation = _connectionGeneration;
    unawaited(_run(generation));
  }

  Future<void> startForConnectionForTest() async {
    if (_connectionSessionActive) return;
    _connectionSessionActive = true;
    await _run(_connectionGeneration);
  }

  Future<void> retryPendingSync() async {
    if (!_needsRetry || !_isCurrent(_connectionGeneration)) return;
    await _run(_connectionGeneration);
  }

  Future<void> _run(int generation) {
    if (_runningGeneration == generation && _runningSync != null) {
      return _runningSync!;
    }
    late final Future<void> run;
    run = operationGate
        .runInitialSync(() => _runOwned(generation))
        .whenComplete(() {
          if (identical(_runningSync, run)) {
            _runningSync = null;
            _runningGeneration = null;
          }
        });
    _runningGeneration = generation;
    _runningSync = run;
    return run;
  }

  Future<void> _runOwned(int generation) async {
    if (!_isCurrent(generation)) return;
    final now = clock();
    final today = DateTime(now.year, now.month, now.day);
    final favorites = readFavorites?.call() ?? const <FavoriteTeam>{};
    final preferences =
        readContentPreferences?.call() ?? DeviceContentPreferences.defaults();
    final collegePreferences =
        readCollegeFootballPreferences?.call() ??
        CollegeFootballPreferences.defaults();
    _setSnapshot(
      const InitialSyncSnapshot(
        status: InitialSyncStatus.syncing,
        cachedContentMayBeStale: true,
      ),
    );
    _diagnose('Initial sync preparing; date=${_dateText(today)}');
    final failures = <String>[];
    final teams = <DeviceContentCategory, List<GameData>>{};
    GolfLeaderboard? golf;
    PreparedFantasyStartup? fantasy;

    // No writes here: failed providers must not erase the received catalog.
    for (final category in preferences.enabledCategories) {
      if (!_isCurrent(generation)) return;
      try {
        if (category == DeviceContentCategory.fantasy) {
          fantasy = await prepareFantasyCategory?.call();
          if (fantasy != null) {
            failures.addAll(fantasy.failures.map((e) => 'Fantasy: $e'));
          }
        } else if (category == DeviceContentCategory.pga) {
          final fetched = await repository.fetchGolfLeaderboardForDate(today);
          if (fetched != null && fetched.golfers.isNotEmpty) {
            final snapshot = GolfLeaderboard(
              tournamentId: fetched.tournamentId,
              tournamentName: fetched.tournamentName,
              golfers: List.unmodifiable(fetched.golfers),
              isInProgress: fetched.isInProgress,
              isOver: fetched.isOver,
            );
            const GolfPacketSerializer().buildTransfer(
              snapshot,
              transferId: 'startup-validation',
            );
            golf = snapshot;
          }
        } else {
          final league = category.sportsLeague!;
          final fetched = await repository.fetchGamesForDate(league, today);
          final filtered = applyCollegeFootballFilter(
            league,
            fetched,
            collegePreferences,
          );
          final games = List<GameData>.unmodifiable(
            const FavoriteGamePrioritizer().prioritize(
              league,
              filtered,
              favorites,
            ),
          );
          if (games.isNotEmpty) {
            const GamePacketSerializer().buildChunkedSlateTransfer(
              games,
              slateId: 'startup-validation',
            );
          }
          teams[category] = games;
        }
      } on Object catch (error) {
        failures.add('${category.displayName}: $error');
        _diagnose('${category.displayName} preparation failed: $error');
      }
    }
    if (!_isCurrent(generation)) return;
    final authoritative = failures.isEmpty;
    if (authoritative) {
      try {
        // The existing destructive semantics are unchanged. All replacement
        // data is now fetched and validated before this command is sent.
        await sender.sendControlCommand(syncStartCommand);
        if (!_isCurrent(generation)) return;
        onAuthoritativeSyncStarted?.call();
        _diagnose('SYNC_START sent after preparation');
      } on Object catch (error) {
        if (!_isCurrent(generation)) return;
        _needsRetry = true;
        _setSnapshot(
          InitialSyncSnapshot(
            status: InitialSyncStatus.failure,
            cachedContentMayBeStale: true,
            lastErrorSummary: 'Unable to start device sync: $error',
          ),
        );
        return;
      }
    } else {
      _diagnose(
        'Provider unavailable; cached catalog retained without SYNC_START',
      );
    }

    if (!authoritative &&
        !preferences.isEnabled(DeviceContentCategory.fantasy) &&
        sender.transport is FantasyMatchupTransport) {
      try {
        await sender.clearFantasyMatchup();
      } on Object catch (error) {
        failures.add('Fantasy removal: $error');
      }
    }
    var sentCount = 0;
    for (final category in preferences.enabledCategories) {
      if (!_isCurrent(generation)) return;
      try {
        if (category == DeviceContentCategory.fantasy) {
          // Fantasy is one atomic category. Omitting an unavailable league from
          // a replacement slate would erase its cached matchup on old devices.
          if (fantasy != null && fantasy.failures.isEmpty) {
            final result = await fantasy.commit();
            if (!_isCurrent(generation)) return;
            failures.addAll(result.failures.map((e) => 'Fantasy: $e'));
            if (result.hasContent) sentCount++;
          }
        } else if (category == DeviceContentCategory.pga) {
          if (golf != null) {
            await sender.sendGolf(golf, selectedDate: today);
            sentCount++;
          }
        } else {
          final games = teams[category];
          if (games != null && games.isNotEmpty) {
            await sender.sendTeamSlate(games, selectedDate: today);
            sentCount++;
          }
        }
      } on Object catch (error) {
        failures.add('${category.displayName}: $error');
        _diagnose('${category.displayName} send failed: $error');
      }
    }
    if (!_isCurrent(generation)) return;
    if (sentCount > 0 || authoritative) {
      // Close an already-started attempt even after a write failure, so the
      // next compatible SYNC_START is not suppressed as a duplicate.
      final command = sentCount == 0 && failures.isEmpty
          ? syncEmptyCommand
          : syncCompleteCommand;
      try {
        await sender.sendControlCommand(command);
      } on Object catch (error) {
        failures.add('$command: $error');
      }
    }
    if (!_isCurrent(generation)) return;
    _needsRetry = failures.isNotEmpty;
    final status = failures.isNotEmpty
        ? sentCount > 0
              ? InitialSyncStatus.partialFailure
              : InitialSyncStatus.failure
        : sentCount > 0
        ? InitialSyncStatus.complete
        : InitialSyncStatus.empty;
    _setSnapshot(
      InitialSyncSnapshot(
        status: status,
        successfullySyncedLeagueCount: sentCount,
        cachedContentMayBeStale: failures.isNotEmpty,
        lastErrorSummary: failures.isEmpty ? null : failures.join('; '),
      ),
    );
    try {
      await onInitialSyncComplete?.call();
    } on Object catch (error) {
      _diagnose('Post-sync optional domain failed: $error');
    }
    _diagnose(
      'Initial sync complete; leagues sent=$sentCount; failures=${failures.length}',
    );
  }

  bool _isCurrent(int generation) =>
      generation == _connectionGeneration &&
      _connectionSessionActive &&
      isBleConnected();

  void _setSnapshot(InitialSyncSnapshot value) {
    _snapshot = value;
    onStatusChanged?.call(value);
    if (value.status != InitialSyncStatus.idle &&
        value.status != InitialSyncStatus.syncing) {
      _diagnose('Initial sync terminal status=${value.status.name}');
    }
  }

  String _dateText(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  void _diagnose(String message) => onDiagnostic?.call(message);
}
