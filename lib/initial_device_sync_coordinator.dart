import 'dart:async';

import 'ble_device_state.dart';
import 'session_aware_device_sender.dart';
import 'sports_operation_gate.dart';
import 'sports_league.dart';
import 'sports_repository.dart';
import 'favorite_game_prioritizer.dart';
import 'favorite_team.dart';
import 'device_content_preferences.dart';

enum InitialSyncStatus { idle, syncing, complete, empty, partialFailure }

class InitialSyncSnapshot {
  const InitialSyncSnapshot({
    required this.status,
    this.successfullySyncedLeagueCount = 0,
    this.lastErrorSummary,
  });

  final InitialSyncStatus status;
  final int successfullySyncedLeagueCount;
  final String? lastErrorSummary;
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
    this.syncFantasyCategory,
    this.onAuthoritativeSyncStarted,
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
  final Future<bool> Function()? syncFantasyCategory;
  final void Function()? onAuthoritativeSyncStarted;

  InitialSyncSnapshot _snapshot = const InitialSyncSnapshot(
    status: InitialSyncStatus.idle,
  );
  bool _connectionSessionActive = false;
  int _connectionGeneration = 0;

  InitialSyncSnapshot get snapshot => _snapshot;

  void handleConnectionState(BleConnectionState state) {
    if (state == BleConnectionState.disconnected ||
        state == BleConnectionState.error) {
      if (_connectionSessionActive) {
        _diagnose('Initial sync connection session ended');
      }
      _connectionSessionActive = false;
      _connectionGeneration++;
      return;
    }
    if (state != BleConnectionState.connected || _connectionSessionActive) {
      return;
    }
    _connectionSessionActive = true;
    final generation = _connectionGeneration;
    unawaited(_run(generation));
  }

  Future<void> startForConnectionForTest() async {
    if (_connectionSessionActive) return;
    _connectionSessionActive = true;
    await _run(_connectionGeneration);
  }

  Future<void> _run(int generation) async {
    await operationGate.runInitialSync(() => _runOwned(generation));
  }

  Future<void> _runOwned(int generation) async {
    final now = clock();
    final today = DateTime(now.year, now.month, now.day);
    final favorites = readFavorites?.call() ?? const <FavoriteTeam>{};
    final preferences =
        readContentPreferences?.call() ?? DeviceContentPreferences.defaults();
    _setSnapshot(const InitialSyncSnapshot(status: InitialSyncStatus.syncing));
    _diagnose('Initial sync started; date=${_dateText(today)}');

    try {
      await sender.sendControlCommand(syncStartCommand);
      onAuthoritativeSyncStarted?.call();
      _diagnose('SYNC_START sent');
    } on Object catch (error) {
      _diagnose('SYNC_START failed: $error');
      _setSnapshot(
        InitialSyncSnapshot(
          status: InitialSyncStatus.partialFailure,
          lastErrorSummary: 'Unable to start device sync: $error',
        ),
      );
      return;
    }
    if (!_isCurrent(generation)) return;

    var sentCount = 0;
    final failures = <String>[];
    for (final category in preferences.enabledCategories) {
      if (!_isCurrent(generation)) return;
      if (category == DeviceContentCategory.fantasy) {
        try {
          _diagnose('Fantasy sync started');
          if (await syncFantasyCategory?.call() == true) {
            sentCount++;
            _diagnose('Fantasy sent');
          } else {
            _diagnose('Fantasy unavailable; skipped');
          }
        } on Object catch (error) {
          failures.add('Fantasy: $error');
          _diagnose('Fantasy sync failed: $error');
        }
        continue;
      }
      final league = category.sportsLeague!;
      if (league == SportsLeague.pga) {
        try {
          _diagnose('PGA fetch started');
          final golf = await repository.fetchGolfLeaderboardForDate(today);
          final golferCount = golf?.golfers.length ?? 0;
          _diagnose('PGA golfers=$golferCount');
          if (golf != null && golf.golfers.isNotEmpty) {
            if (!_isCurrent(generation)) return;
            await sender.sendGolf(golf, selectedDate: today);
            sentCount++;
            _diagnose('PGA sent');
          } else {
            _diagnose('PGA empty; skipped');
          }
        } on Object catch (error) {
          failures.add('PGA: $error');
          _diagnose('PGA fetch/send failed: $error');
        }
        continue;
      }
      try {
        _diagnose('${league.label} fetch started');
        final fetched = await repository.fetchGamesForDate(league, today);
        final games = const FavoriteGamePrioritizer().prioritize(
          league,
          fetched,
          favorites,
        );
        _diagnose('${league.label} games=${games.length}');
        if (games.isEmpty) {
          _diagnose('${league.label} games=0; skipped');
          continue;
        }
        if (!_isCurrent(generation)) return;
        await sender.sendTeamSlate(games, selectedDate: today);
        sentCount++;
        _diagnose('${league.label} sent');
      } on Object catch (error) {
        failures.add('${league.label}: $error');
        _diagnose('${league.label} fetch/send failed: $error');
        if (!_isCurrent(generation)) return;
      }
    }

    if (!_isCurrent(generation)) return;
    if (sentCount > 0) {
      try {
        await sender.sendControlCommand(syncCompleteCommand);
        _diagnose('SYNC_COMPLETE sent');
      } on Object catch (error) {
        failures.add('SYNC_COMPLETE: $error');
        _diagnose('SYNC_COMPLETE failed: $error');
      }
    } else if (failures.isEmpty) {
      try {
        await sender.sendControlCommand(syncEmptyCommand);
        _diagnose('SYNC_EMPTY sent');
      } on Object catch (error) {
        failures.add('SYNC_EMPTY: $error');
        _diagnose('SYNC_EMPTY failed: $error');
      }
    }

    final status = failures.isNotEmpty
        ? InitialSyncStatus.partialFailure
        : sentCount > 0
        ? InitialSyncStatus.complete
        : InitialSyncStatus.empty;
    _setSnapshot(
      InitialSyncSnapshot(
        status: status,
        successfullySyncedLeagueCount: sentCount,
        lastErrorSummary: failures.isEmpty ? null : failures.join('; '),
      ),
    );
    try {
      await onInitialSyncComplete?.call();
    } on Object catch (error) {
      _diagnose('Post-sync optional domain failed: $error');
    }
    _diagnose(
      'Initial sync complete; leagues sent=$sentCount; '
      'failures=${failures.length}',
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
