import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals, mapEquals;

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
import 'tracked_device_session.dart';
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
    this.prepareFantasyRefreshCategory,
    this.canReplaceTeamSlate,
    this.onAuthoritativeSyncStarted,
    this.readCollegeFootballPreferences,
  }) : clock = clock ?? DateTime.now,
       operationGate = operationGate ?? SportsOperationGate();

  static const discoveryInterval = Duration(minutes: 5);

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
  final Future<PreparedFantasyStartup> Function()?
  prepareFantasyRefreshCategory;
  final bool Function(TrackedTeamSlate, List<GameData>)? canReplaceTeamSlate;
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
  Stopwatch? _diagnosticSyncClock;
  bool _retryIsReconciliation = false;
  DateTime? _lastDiscoveryAt;
  DateTime? _lastDiscoveryDate;
  DateTime? _pendingEmptyGolfDate;
  final List<DeviceContentCategory> _catalogOrder = [];

  bool get needsRetry => _needsRetry;
  String get diagnosticState =>
      'syncG=$_connectionGeneration retry=$_needsRetry '
      'runningG=${_runningGeneration ?? '-'} '
      'runningAgeMs=${_diagnosticSyncClock?.elapsedMilliseconds ?? 0} '
      'reconcile=$_retryIsReconciliation';

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
      operationGate.resetConnection();
      _diagnose('sync connection generation advanced; $diagnosticState');
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
    await _run(_connectionGeneration, reconcile: _retryIsReconciliation);
  }

  /// Desired content comes from preferences, independently of delivered entries.
  /// WAKE/resume/FCM share this gate; no background timer is needed.
  Future<bool> refreshDesiredContentIfDue() async {
    if (!_isCurrent(_connectionGeneration)) return false;
    if (_runningSync != null) {
      if (!_retryIsReconciliation) return false;
      await _runningSync;
      return true;
    }
    final now = clock().toLocal();
    final today = DateTime(now.year, now.month, now.day);
    if (_lastDiscoveryDate == today &&
        _lastDiscoveryAt != null &&
        !now.isBefore(_lastDiscoveryAt!) &&
        now.difference(_lastDiscoveryAt!) < discoveryInterval) {
      return false;
    }
    await _run(_connectionGeneration, reconcile: true);
    return true;
  }

  Future<void> _run(int generation, {bool reconcile = false}) {
    if (_runningGeneration == generation && _runningSync != null) {
      _diagnose('sync.run coalesced; $diagnosticState');
      return _runningSync!;
    }
    _retryIsReconciliation = reconcile;
    final elapsed = Stopwatch()..start();
    _diagnose(
      'sync.run requested originSyncG=$generation reconcile=$reconcile',
    );
    late final Future<void> run;
    run = operationGate
        .runInitialSync(() => _runOwned(generation, reconcile: reconcile))
        .catchError((Object error) {
          if (!_isCurrent(generation)) return;
          _needsRetry = true;
          _setSnapshot(
            InitialSyncSnapshot(
              status: InitialSyncStatus.failure,
              cachedContentMayBeStale: true,
              lastErrorSummary: 'Device sync delivery deferred: $error',
            ),
          );
        })
        .whenComplete(() {
          _diagnose(
            'sync.run ended originSyncG=$generation elapsedMs=${elapsed.elapsedMilliseconds}',
          );
          if (identical(_runningSync, run)) {
            _diagnosticSyncClock = null;
            _runningSync = null;
            _runningGeneration = null;
          }
        });
    _runningGeneration = generation;
    _runningSync = run;
    _diagnosticSyncClock = elapsed;
    return run;
  }

  Future<void> _runOwned(int generation, {required bool reconcile}) async {
    if (!_isCurrent(generation)) return;
    final now = clock().toLocal();
    final today = DateTime(now.year, now.month, now.day);
    _lastDiscoveryAt = now;
    _lastDiscoveryDate = today;
    final delivered = sender.session.snapshot();
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
    final categories = preferences.entries
        .where((entry) {
          final tracked = delivered[entry.category.sportsLeague];
          return entry.enabled ||
              (reconcile && tracked != null && !tracked.followsCurrentDate);
        })
        .map((entry) => entry.category)
        .toList();
    final dates = <DeviceContentCategory, DateTime>{};
    final held = <DeviceContentCategory>{};
    final failures = <String>[];
    final teams = <DeviceContentCategory, List<GameData>>{};
    GolfLeaderboard? golf;
    PreparedFantasyStartup? fantasy;

    // No writes here: failed providers must not erase the received catalog.
    for (final category in categories) {
      if (!_isCurrent(generation)) return;
      final tracked = delivered[category.sportsLeague];
      final pinned =
          reconcile && tracked != null && !tracked.followsCurrentDate;
      final selectedDate = switch (tracked) {
        TrackedTeamSlate() when pinned => tracked.selectedDate,
        TrackedGolfLeaderboard() when pinned => tracked.selectedDate ?? today,
        _ => today,
      };
      dates[category] = selectedDate;
      final failuresBefore = failures.length;
      _diagnose(
        'prepare.enter category=${category.name} originSyncG=$generation',
      );
      try {
        if (category == DeviceContentCategory.fantasy) {
          fantasy =
              await (reconcile
                      ? prepareFantasyRefreshCategory ?? prepareFantasyCategory
                      : prepareFantasyCategory)
                  ?.call();
          if (fantasy != null) {
            failures.addAll(fantasy.failures.map((e) => 'Fantasy: $e'));
          }
        } else if (category == DeviceContentCategory.pga) {
          final fetched = pinned && tracked is TrackedGolfLeaderboard
              ? await repository.fetchGolfLeaderboardByTournamentId(
                  tracked.leaderboard.tournamentId,
                  isCurrent: () => _isCurrent(generation),
                )
              : await repository.fetchGolfLeaderboardForDate(
                  selectedDate,
                  isCurrent: () => _isCurrent(generation),
                );
          if (reconcile &&
              tracked is TrackedGolfLeaderboard &&
              tracked.selectedDate == selectedDate &&
              (fetched == null || fetched.golfers.isEmpty)) {
            if (_pendingEmptyGolfDate != selectedDate) {
              _pendingEmptyGolfDate = selectedDate;
              held.add(category);
            }
          } else {
            _pendingEmptyGolfDate = null;
          }
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
          final fetched = await repository.fetchGamesForDate(
            league,
            selectedDate,
            isCurrent: () => _isCurrent(generation),
          );
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
          if (reconcile &&
              tracked is TrackedTeamSlate &&
              tracked.selectedDate == selectedDate &&
              canReplaceTeamSlate?.call(tracked, games) == false) {
            held.add(category);
          } else {
            teams[category] = games;
          }
        }
      } on Object catch (error) {
        failures.add('${category.displayName}: $error');
        _diagnose(
          'prepare.failed category=${category.name} type=${error.runtimeType}',
        );
      } finally {
        _diagnose(
          'prepare.exit category=${category.name} originSyncG=$generation failuresAdded=${failures.length - failuresBefore}',
        );
      }
    }
    if (!_isCurrent(generation)) return;
    if (!mapEquals(delivered, sender.session.snapshot())) {
      _deferChangedSelection();
      return;
    }
    final desiredOrder = [
      for (final category in categories)
        if (category == DeviceContentCategory.fantasy
            ? fantasy?.hasContent == true
            : category == DeviceContentCategory.pga
            ? golf != null
            : teams[category]?.isNotEmpty == true)
          category,
    ];
    // Include explicit Developer Tools sends when comparing current membership.
    for (final league in delivered.keys) {
      final category = DeviceContentCategory.values.firstWhere(
        (category) => category.sportsLeague == league,
      );
      if (!_catalogOrder.contains(category)) _catalogOrder.add(category);
    }
    final authoritative = failures.isEmpty && held.isEmpty;
    final resetCatalog =
        authoritative &&
        (!reconcile || !listEquals(_catalogOrder, desiredOrder));
    var loadedCount = 0;
    bool fantasyAttempted = false;
    bool fantasyDelivered = false;
    bool committed = false;
    await sender.runTransaction(() async {
      if (!_isCurrent(generation)) return;
      // Re-check after queue admission: a manual send may have completed while
      // this prepared discovery was waiting for transport ownership.
      if (!mapEquals(delivered, sender.session.snapshot())) {
        _deferChangedSelection();
        return;
      }
      if (resetCatalog) {
        try {
          // The existing destructive semantics are unchanged. All replacement
          // data is now fetched and validated before this command is sent.
          await sender.sendControlCommand(syncStartCommand);
          if (!_isCurrent(generation)) return;
          onAuthoritativeSyncStarted?.call();
          _catalogOrder.clear();
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
      } else if (!authoritative) {
        _diagnose(
          'Incomplete discovery; cached catalog retained without SYNC_START',
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
      loadedCount = 0;
      for (final category in categories) {
        if (!_isCurrent(generation)) return;
        if (held.contains(category)) continue;
        final tracked = delivered[category.sportsLeague];
        final followsToday =
            !(reconcile && tracked != null && !tracked.followsCurrentDate);
        try {
          if (category == DeviceContentCategory.fantasy) {
            // Fantasy is one atomic category. Omitting an unavailable league from
            // a replacement slate would erase its cached matchup on old devices.
            if (fantasy != null && fantasy.failures.isEmpty) {
              fantasyAttempted = true;
              final write = fantasy.commitWrites;
              final result = await (write != null
                  ? write(resetCatalog)
                  : (resetCatalog
                        ? fantasy.commitAfterReset ?? fantasy.commit
                        : fantasy.commit)());
              fantasyDelivered = true;
              if (!_isCurrent(generation)) return;
              failures.addAll(result.failures.map((e) => 'Fantasy: $e'));
              if (result.hasContent) {
                loadedCount++;
                sentCount++;
                if (!_catalogOrder.contains(category)) {
                  _catalogOrder.add(category);
                }
              } else {
                _catalogOrder.remove(category);
              }
            }
          } else if (category == DeviceContentCategory.pga) {
            if (golf != null) {
              if (!reconcile ||
                  resetCatalog ||
                  tracked is! TrackedGolfLeaderboard ||
                  tracked.selectedDate != dates[category] ||
                  !listEquals(
                    const GolfPacketSerializer().canonicalContent(
                      tracked.leaderboard,
                    ),
                    const GolfPacketSerializer().canonicalContent(golf),
                  )) {
                await sender.sendGolf(
                  golf,
                  selectedDate: dates[category],
                  followsCurrentDate: followsToday,
                  isCurrent: () => _isCurrent(generation),
                );
                sentCount++;
                if (!_catalogOrder.contains(category)) {
                  _catalogOrder.add(category);
                }
              }
              loadedCount++;
            }
          } else {
            final games = teams[category];
            if (games != null && games.isNotEmpty) {
              if (!reconcile ||
                  resetCatalog ||
                  tracked is! TrackedTeamSlate ||
                  tracked.selectedDate != dates[category] ||
                  !listEquals(
                    const GamePacketSerializer().canonicalSlateContent(
                      tracked.games,
                    ),
                    const GamePacketSerializer().canonicalSlateContent(games),
                  )) {
                await sender.sendTeamSlate(
                  games,
                  selectedDate: dates[category]!,
                  followsCurrentDate: followsToday,
                  isCurrent: () => _isCurrent(generation),
                );
                sentCount++;
                if (!_catalogOrder.contains(category)) {
                  _catalogOrder.add(category);
                }
              }
              loadedCount++;
            }
          }
        } on Object catch (error) {
          failures.add('${category.displayName}: $error');
          _diagnose(
            'send.failed category=${category.name} type=${error.runtimeType}',
          );
        }
      }
      if (!_isCurrent(generation)) return;
      if (resetCatalog || (!reconcile && sentCount > 0)) {
        // Close an already-started attempt even after a write failure, so the
        // next compatible SYNC_START is not suppressed as a duplicate.
        final command = loadedCount == 0 && failures.isEmpty
            ? syncEmptyCommand
            : syncCompleteCommand;
        try {
          await sender.sendControlCommand(command);
        } on Object catch (error) {
          failures.add('$command: $error');
        }
      }
      if (!_isCurrent(generation)) return;
      committed = true;
    }, isCurrent: () => _isCurrent(generation));
    if (!_isCurrent(generation) || !committed) return;
    if (fantasyAttempted && fantasy?.finishObservation != null) {
      final observed = await fantasy!.finishObservation!(fantasyDelivered);
      failures.addAll(observed.failures.map((e) => 'Fantasy: $e'));
    }
    if (!_isCurrent(generation)) return;
    _needsRetry = failures.isNotEmpty;
    final status = failures.isNotEmpty
        ? loadedCount > 0
              ? InitialSyncStatus.partialFailure
              : InitialSyncStatus.failure
        : loadedCount > 0 || held.isNotEmpty
        ? InitialSyncStatus.complete
        : InitialSyncStatus.empty;
    _setSnapshot(
      InitialSyncSnapshot(
        status: status,
        successfullySyncedLeagueCount: loadedCount,
        cachedContentMayBeStale: failures.isNotEmpty || held.isNotEmpty,
        lastErrorSummary: failures.isEmpty ? null : failures.join('; '),
      ),
    );
    try {
      await onInitialSyncComplete?.call();
    } on Object catch (error) {
      _diagnose('Post-sync optional domain failed type=${error.runtimeType}');
    }
    _diagnose(
      'Initial sync complete; categories loaded=$loadedCount; failures=${failures.length}',
    );
  }

  void _deferChangedSelection() {
    // Re-prepare from the newer manual selection, including its explicit date,
    // instead of letting an older startup/catalog snapshot overwrite it.
    _lastDiscoveryDate = null;
    _needsRetry = true;
    _retryIsReconciliation = true;
    _setSnapshot(
      const InitialSyncSnapshot(
        status: InitialSyncStatus.partialFailure,
        cachedContentMayBeStale: true,
        lastErrorSummary: 'Content selection changed; discovery deferred.',
      ),
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
