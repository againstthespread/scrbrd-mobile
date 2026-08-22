import 'package:flutter/foundation.dart';

import 'fantasy_alert_transport.dart';
import 'fantasy_point_alert.dart';
import 'fantasy_point_delta_tracker.dart';
import 'pending_fantasy_alert_store.dart';
import 'sleeper_fantasy_config.dart';
import 'sleeper_fantasy_repository.dart';
import 'sleeper_models.dart';
import 'sleeper_player_repository.dart';

typedef FantasyMatchupLoader =
    Future<SleeperLeagueSnapshot> Function(String leagueId);
typedef FantasyMetadataResolver =
    Future<Map<String, SleeperFantasyPlayer>> Function(
      Iterable<String> playerIds,
    );

Future<void> runIsolatedWakeDomains({
  required Future<void> Function() refreshSports,
  required Future<void> Function() observeFantasy,
  void Function(String message)? onDiagnostic,
}) async {
  try {
    await refreshSports();
  } on Object catch (error) {
    onDiagnostic?.call('SPORTS WAKE failed; fantasy continues: $error');
  }
  try {
    await observeFantasy();
  } on Object catch (error) {
    onDiagnostic?.call('FANTASY WAKE failed; sports unaffected: $error');
  }
}

class FantasyObservationResult {
  const FantasyObservationResult({
    required this.configured,
    required this.baselineReset,
    required this.alerts,
    required this.summary,
    this.matchup,
  });

  final bool configured;
  final bool baselineReset;
  final List<FantasyPointAlert> alerts;
  final String summary;
  final SleeperFantasyMatchup? matchup;
}

class FantasyRuntimeStatus {
  const FantasyRuntimeStatus({
    this.configured = false,
    this.baselineReady = false,
    this.pendingAlerts = 0,
    this.lastResult = 'Not observed yet.',
    this.alertsEnabled = true,
  });

  final bool configured;
  final bool baselineReady;
  final int pendingAlerts;
  final String lastResult;
  final bool alertsEnabled;
}

/// Sleeper-only fantasy runtime. One instance owns all automatic/manual state.
class FantasyLiveObservationCoordinator extends ChangeNotifier {
  FantasyLiveObservationCoordinator({
    required this.configStore,
    required this.repository,
    required this.playerRepository,
    required this.transport,
    required this.isBleConnected,
    FantasyPointDeltaTracker? deltaTracker,
    PendingFantasyAlertStore? pendingStore,
    FantasyMatchupLoader? setupLoader,
    FantasyMatchupLoader? matchupLoader,
    FantasyMetadataResolver? metadataResolver,
    this.onDiagnostic,
  }) : deltaTracker = deltaTracker ?? FantasyPointDeltaTracker(),
       pendingStore = pendingStore ?? PendingFantasyAlertStore(),
       _setupLoader = setupLoader ?? repository.loadLeague,
       _matchupLoader = matchupLoader ?? repository.refreshMatchups,
       _metadataResolver =
           metadataResolver ?? playerRepository.resolveCachedPlayersSafely;

  final SleeperFantasyConfigStore configStore;
  final SleeperFantasyRepository repository;
  final SleeperPlayerRepository playerRepository;
  final FantasyAlertTransport transport;
  final bool Function() isBleConnected;
  final FantasyPointDeltaTracker deltaTracker;
  final PendingFantasyAlertStore pendingStore;
  final FantasyMatchupLoader _setupLoader;
  final FantasyMatchupLoader _matchupLoader;
  final FantasyMetadataResolver _metadataResolver;
  final void Function(String message)? onDiagnostic;

  FantasyRuntimeStatus _status = const FantasyRuntimeStatus();
  bool _observing = false;
  bool _sessionBaselineEstablished = false;
  String? _observationContext;
  SleeperFantasyMatchup? _latestMatchup;
  bool _alertsEnabled = true;

  FantasyRuntimeStatus get status => _status;

  void beginConnectionSession() => _sessionBaselineEstablished = false;

  void endConnectionSession() => _sessionBaselineEstablished = false;

  Future<SleeperLeagueSnapshot> configureLeague(String leagueId) async {
    final normalized = leagueId.trim();
    final existing = await configStore.read();
    final changed = existing?.leagueId != normalized;
    final snapshot = await _setupLoader(normalized);
    await configStore.save(
      SleeperFantasyConfig(
        leagueId: normalized,
        rosterId: changed ? null : existing?.rosterId,
        alertsEnabled: existing?.alertsEnabled ?? true,
      ),
    );
    if (changed) _resetProductionState('league changed');
    _alertsEnabled = existing?.alertsEnabled ?? true;
    _status = FantasyRuntimeStatus(
      configured: !changed && existing?.rosterId != null,
      alertsEnabled: _alertsEnabled,
    );
    notifyListeners();
    return snapshot;
  }

  Future<void> selectRoster(int rosterId) async {
    final config = await configStore.read();
    if (config == null) return;
    if (config.rosterId != rosterId) {
      await configStore.save(
        SleeperFantasyConfig(
          leagueId: config.leagueId,
          rosterId: rosterId,
          alertsEnabled: config.alertsEnabled,
        ),
      );
      _resetProductionState('roster changed');
    }
    _alertsEnabled = config.alertsEnabled;
    _status = FantasyRuntimeStatus(
      configured: true,
      alertsEnabled: _alertsEnabled,
    );
    notifyListeners();
  }

  Future<void> clearRosterSelection() async {
    final config = await configStore.read();
    if (config == null || config.rosterId == null) return;
    await configStore.save(
      SleeperFantasyConfig(
        leagueId: config.leagueId,
        alertsEnabled: config.alertsEnabled,
      ),
    );
    _resetProductionState('roster unavailable');
    _alertsEnabled = config.alertsEnabled;
    _status = FantasyRuntimeStatus(alertsEnabled: _alertsEnabled);
    notifyListeners();
  }

  Future<SleeperFantasyConfig?> readConfig() => configStore.read();

  Future<void> loadConfigurationStatus() async {
    final config = await configStore.read();
    _alertsEnabled = config?.alertsEnabled ?? true;
    _status = FantasyRuntimeStatus(
      configured: config?.rosterId != null,
      baselineReady: _status.baselineReady,
      pendingAlerts: pendingStore.length,
      lastResult: _status.lastResult,
      alertsEnabled: _alertsEnabled,
    );
    notifyListeners();
  }

  Future<void> setAlertsEnabled(bool enabled) async {
    final config = await configStore.read();
    if (config == null || config.alertsEnabled == enabled) return;
    await configStore.save(config.copyWith(alertsEnabled: enabled));
    _alertsEnabled = enabled;
    pendingStore.clear();
    if (enabled) {
      deltaTracker.reset();
      _observationContext = null;
      _sessionBaselineEstablished = false;
    }
    _status = FantasyRuntimeStatus(
      configured: config.rosterId != null,
      baselineReady: enabled ? false : _status.baselineReady,
      pendingAlerts: 0,
      lastResult: enabled
          ? 'Ready to establish a safe baseline.'
          : 'Alerts off.',
      alertsEnabled: enabled,
    );
    notifyListeners();
  }

  Future<bool> sendTestAlert() async {
    if (!isBleConnected()) return false;
    final matchup = _latestMatchup;
    await transport.sendFantasyAlert(
      FantasyPointAlert(
        delta: const FantasyPointDelta(
          playerId: 'sample-player',
          side: FantasyMatchupSide.user,
          previousPoints: 0,
          currentPoints: 12,
          delta: 12,
        ),
        player: const SleeperFantasyPlayer(
          sleeperPlayerId: 'sample-player',
          fullName: "Ja'Marr Chase",
          firstName: "Ja'Marr",
          lastName: 'Chase',
          position: 'WR',
          nflTeam: 'CIN',
          espnPlayerId: null,
        ),
        userName: matchup?.team.name ?? 'YOUR TEAM',
        userScore: matchup?.team.matchup.points ?? 104.7,
        opponentName: matchup?.opponent.name ?? 'OPPONENT',
        opponentScore: matchup?.opponent.matchup.points ?? 97.2,
      ),
    );
    return true;
  }

  Future<void> establishStartupBaseline() async {
    if (_sessionBaselineEstablished) return;
    final result = await observe(sendOneAlert: false);
    if (result.configured && result.matchup != null) {
      _sessionBaselineEstablished = true;
    }
  }

  Future<FantasyObservationResult> observe({bool sendOneAlert = true}) async {
    if (_observing) {
      return FantasyObservationResult(
        configured: _status.configured,
        baselineReset: false,
        alerts: const [],
        summary: 'Skipped: fantasy observation already active.',
      );
    }
    _observing = true;
    try {
      final config = await configStore.read();
      if (config == null || config.rosterId == null) {
        return _finish(
          const FantasyObservationResult(
            configured: false,
            baselineReset: false,
            alerts: [],
            summary: 'Sleeper league and roster are not configured.',
          ),
        );
      }

      final snapshot = await _matchupLoader(config.leagueId);
      final matchup = snapshot.matchupForRoster(config.rosterId!);
      _latestMatchup = matchup;
      _alertsEnabled = config.alertsEnabled;
      final context =
          '${config.leagueId}|${snapshot.week}|'
          '${matchup.team.roster.rosterId}|'
          '${matchup.opponent.roster.rosterId}|'
          '${matchup.team.matchup.matchupId}';
      if (_observationContext != context) {
        pendingStore.clear();
        _observationContext = context;
      }
      final deltaResult = deltaTracker.observe(matchup);
      if (!config.alertsEnabled) {
        pendingStore.clear();
        return _finish(
          FantasyObservationResult(
            configured: true,
            baselineReset: deltaResult.baselineReset,
            alerts: const [],
            summary: 'Alerts are off.',
            matchup: matchup,
          ),
        );
      }
      final metadata = await _metadataResolver(
        deltaResult.events.map((event) => event.playerId),
      );
      final alerts = [
        for (final delta in deltaResult.events)
          FantasyPointAlert(
            delta: delta,
            player: metadata[delta.playerId],
            userName: matchup.team.name,
            userScore: matchup.team.matchup.points,
            opponentName: matchup.opponent.name,
            opponentScore: matchup.opponent.matchup.points,
          ),
      ];
      for (final alert in alerts) {
        pendingStore.add(
          PendingFantasyAlert(
            id: fantasyTransitionId(
              leagueId: config.leagueId,
              week: snapshot.week,
              matchup: matchup,
              delta: alert.delta,
            ),
            alert: alert,
          ),
        );
      }
      if (sendOneAlert) await _sendNext();
      return _finish(
        FantasyObservationResult(
          configured: true,
          baselineReset: deltaResult.baselineReset,
          alerts: List.unmodifiable(alerts),
          summary: deltaResult.baselineReset
              ? 'Baseline established; no historical alerts.'
              : alerts.isEmpty
              ? 'No fantasy point changes.'
              : 'Observed ${alerts.length} fantasy point change(s).',
          matchup: matchup,
        ),
      );
    } on Object catch (error) {
      _diagnose('Fantasy observation failed: $error');
      return _finish(
        FantasyObservationResult(
          configured: true,
          baselineReset: false,
          alerts: const [],
          summary: 'Fantasy observation failed: $error',
        ),
      );
    } finally {
      _observing = false;
    }
  }

  Future<void> _sendNext() async {
    final pending = pendingStore.next;
    if (pending == null || !isBleConnected()) return;
    try {
      await transport.sendFantasyAlert(pending.alert);
      pendingStore.markDelivered(pending.id);
      _diagnose('Fantasy alert delivered: ${pending.id}');
    } on Object catch (error) {
      _diagnose('Fantasy alert retained after BLE failure: $error');
    }
  }

  void _resetProductionState(String reason) {
    deltaTracker.reset();
    pendingStore.clear();
    _observationContext = null;
    _sessionBaselineEstablished = false;
    _diagnose('Fantasy baseline reset: $reason');
  }

  FantasyObservationResult _finish(FantasyObservationResult result) {
    _status = FantasyRuntimeStatus(
      configured: result.configured,
      baselineReady: result.matchup != null,
      pendingAlerts: pendingStore.length,
      lastResult: result.summary,
      alertsEnabled: _alertsEnabled,
    );
    notifyListeners();
    return result;
  }

  void _diagnose(String message) => onDiagnostic?.call(message);
}
