import 'package:flutter/foundation.dart';

import 'espn_fantasy_credentials.dart';
import 'espn_fantasy_setup.dart';
import 'fantasy_alert_transport.dart';
import 'fantasy_config_compatibility.dart';
import 'fantasy_league_config.dart';
import 'fantasy_primary_league_store.dart';
import 'sleeper_league_observation_session.dart';
import 'fantasy_device_session.dart';
import 'fantasy_matchup_display_data.dart';
import 'fantasy_matchup_transport.dart';
import 'fantasy_provider_models.dart';
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
typedef EspnMatchupLoader =
    Future<FantasyMatchupSnapshot> Function(
      int season,
      String leagueId,
      String teamId,
    );

int currentFantasySeason() {
  final now = DateTime.now();
  return now.month < 3 ? now.year - 1 : now.year;
}

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
    this.leagues = const {},
    this.error,
    this.deliveryError,
    this.pendingAlerts = 0,
  });

  final bool configured;
  final bool baselineReset;
  final List<FantasyPointAlert> alerts;
  final String summary;
  final SleeperFantasyMatchup? matchup;

  /// Per-league outcomes keyed by provider-qualified configuration identity.
  final Map<String, FantasyObservationResult> leagues;
  final Object? error;
  final Object? deliveryError;
  final int pendingAlerts;
  bool get succeeded =>
      error == null &&
      deliveryError == null &&
      leagues.values.every((r) => r.succeeded);
  int get alertCount => alerts.length;
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

/// Orchestrates isolated Sleeper sessions. Device RAM holds only the primary
/// matchup; scoring alerts from every eligible league use the existing transport.
class FantasyLiveObservationCoordinator extends ChangeNotifier {
  FantasyLiveObservationCoordinator({
    SleeperFantasyConfigStore? configStore,
    FantasyLeagueConfigStore? leagueConfigStore,
    FantasyPrimaryLeagueStore? primaryStore,
    required this.repository,
    required this.playerRepository,
    required this.transport,
    required this.isBleConnected,
    FantasyMatchupTransport? matchupTransport,
    FantasyDeviceSession? deviceSession,
    FantasyPointDeltaTracker? deltaTracker,
    PendingFantasyAlertStore? pendingStore,
    FantasyMatchupLoader? setupLoader,
    FantasyMatchupLoader? matchupLoader,
    FantasyMetadataResolver? metadataResolver,
    EspnMatchupLoader? espnMatchupLoader,
    this.onDiagnostic,
  }) : assert(configStore != null || leagueConfigStore != null),
       leagueConfigStore =
           leagueConfigStore ??
           LegacySleeperConfigCollectionAdapter(configStore!),
       configStore = leagueConfigStore != null
           ? SleeperFantasyConfigCollectionAdapter(leagueConfigStore)
           : configStore!,
       primaryStore =
           primaryStore ??
           (leagueConfigStore == null
               ? MemoryFantasyPrimaryLeagueStore()
               : SharedPreferencesFantasyPrimaryLeagueStore()),
       matchupTransport =
           matchupTransport ??
           (transport is FantasyMatchupTransport
               ? transport as FantasyMatchupTransport
               : null),
       deviceSession = deviceSession ?? FantasyDeviceSession(),
       _initialTracker = deltaTracker,
       _initialPending = pendingStore,
       _setupLoader = setupLoader ?? repository.loadLeague,
       _matchupLoader = matchupLoader ?? repository.refreshMatchups,
       _metadataResolver =
           metadataResolver ?? playerRepository.resolveCachedPlayersSafely,
       _espnMatchupLoader =
           espnMatchupLoader ??
           DeviceEspnFantasySetupGateway(
             SecureEspnFantasyCredentialsStore(),
           ).loadMatchup;

  final SleeperFantasyConfigStore configStore;
  final FantasyLeagueConfigStore leagueConfigStore;
  final FantasyPrimaryLeagueStore primaryStore;
  final SleeperFantasyRepository repository;
  final SleeperPlayerRepository playerRepository;
  final FantasyAlertTransport transport;
  final FantasyMatchupTransport? matchupTransport;
  final FantasyDeviceSession deviceSession;
  final bool Function() isBleConnected;
  final FantasyPointDeltaTracker? _initialTracker;
  final PendingFantasyAlertStore? _initialPending;
  bool _initialStateUsed = false;
  final Map<String, SleeperLeagueObservationSession> _sessions = {};
  final PendingFantasyAlertStore _emptyPending = PendingFantasyAlertStore();
  String? _primaryId;

  /// Temporary single-league queue view. Status reports the combined count.
  PendingFantasyAlertStore get pendingStore =>
      _sessions[_primaryId]?.pendingStore ?? _emptyPending;
  Map<String, int> get pendingAlertsByLeague => Map.unmodifiable({
    for (final entry in _sessions.entries)
      entry.key: entry.value.pendingStore.length,
  });
  final FantasyMatchupLoader _setupLoader;
  final FantasyMatchupLoader _matchupLoader;
  final FantasyMetadataResolver _metadataResolver;
  final EspnMatchupLoader _espnMatchupLoader;
  final void Function(String message)? onDiagnostic;

  FantasyRuntimeStatus _status = const FantasyRuntimeStatus();
  bool _observing = false;
  bool _deviceContentEnabled = true;
  int _generation = 0;

  FantasyRuntimeStatus get status => _status;
  String? get primaryLeagueId => _primaryId;

  /// Setup is read-only until the UI commits a selected team to the collection.
  Future<SleeperLeagueSnapshot> loadLeagueSetup(String leagueId) =>
      _setupLoader(leagueId.trim());

  static bool isEligiblePrimary(FantasyLeagueConfig config) =>
      config.hasSelectedTeam;

  Future<void> setPrimaryLeague(String id) async {
    final configs = await leagueConfigStore.readAll();
    if (!configs.any(
      (config) => config.id == id && isEligiblePrimary(config),
    )) {
      throw ArgumentError('Choose a fantasy league with a selected team');
    }
    await primaryStore.save(id);
    await loadConfigurationStatus();
    if (id.startsWith('espn:')) {
      try {
        await syncPrimaryEspnMatchup();
      } on Object {
        // Selection persists even when account access is temporarily unavailable.
        await _clearPersistentFantasy();
      }
    }
  }

  /// Explicit display sync only. ESPN is excluded from observation and alerts.
  Future<FantasyMatchupSnapshot?> syncPrimaryEspnMatchup() async {
    await _reconcile();
    final id = _primaryId;
    if (id == null || !id.startsWith('espn:')) return null;
    final matches = (await leagueConfigStore.readAll()).where(
      (config) => config.id == id && config.teamId != null,
    );
    if (matches.isEmpty) return null;
    final config = matches.single;
    final matchup = await _espnMatchupLoader(
      currentFantasySeason(),
      config.leagueId,
      config.teamId!,
    );
    if (_primaryId != id) return matchup;
    final transport = matchupTransport;
    if (transport != null && isBleConnected() && _deviceContentEnabled) {
      final context =
          '${config.id}|${matchup.scoringPeriod}|'
          '${matchup.matchupPeriod}|${matchup.team.team.id}|'
          '${matchup.opponent?.team.id ?? 'bye'}';
      final display = FantasyMatchupDisplayData.fromNormalized(matchup);
      if (!deviceSession.matches(display, context)) {
        await transport.sendFantasyMatchup(display);
        if (_primaryId == id) deviceSession.record(display, context);
      }
    }
    return matchup;
  }

  Future<void> clearPrimaryEspnDisplay() async {
    if (_primaryId?.startsWith('espn:') ?? false) {
      await _clearPersistentFantasy();
    }
  }

  void beginConnectionSession({bool fantasyEnabled = true}) {
    _deviceContentEnabled = fantasyEnabled;
    _generation++;
    for (final session in _sessions.values) {
      session.reset();
    }
    // Device RAM may belong to a restarted or different SCRBRD after reconnect.
    deviceSession.reset();
  }

  void endConnectionSession() {
    _generation++;
    for (final session in _sessions.values) {
      session.reset();
    }
  }

  Future<List<FantasyLeagueConfig>> _reconcile() async {
    final allConfigs = await leagueConfigStore.readAll();
    final configs = allConfigs
        .where((config) => config.provider == FantasyProvider.sleeper)
        .toList();
    final ids = configs.map((config) => config.id).toSet();
    _sessions.removeWhere((id, _) => !ids.contains(id));
    for (final config in configs) {
      final session = _sessions.putIfAbsent(config.id, () {
        final useInitial = !_initialStateUsed;
        _initialStateUsed = true;
        return SleeperLeagueObservationSession(
          config,
          deltaTracker: useInitial ? _initialTracker : null,
          pendingStore: useInitial ? _initialPending : null,
        );
      });
      session.updateConfiguration(config);
    }
    final primary = await primaryStore.resolve(
      allConfigs.where(isEligiblePrimary).map((config) => config.id),
    );
    if (_primaryId != primary) {
      _primaryId = primary;
      deviceSession.reset();
    }
    return configs;
  }

  Future<SleeperLeagueSnapshot> configureLeague(String leagueId) async {
    final normalized = leagueId.trim();
    final snapshot = await _setupLoader(normalized);
    final matches = (await leagueConfigStore.readAll()).where(
      (config) =>
          config.provider == FantasyProvider.sleeper &&
          config.leagueId == normalized,
    );
    await configStore.save(
      matches.isEmpty
          ? SleeperFantasyConfig(leagueId: normalized)
          : sleeperConfig(matches.first),
    );
    await loadConfigurationStatus();
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
    }
    await loadConfigurationStatus();
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
    await loadConfigurationStatus();
    await _clearPersistentFantasy();
  }

  Future<SleeperFantasyConfig?> readConfig() => configStore.read();

  Future<void> loadConfigurationStatus() async {
    await _reconcile();
    _updateStatus(_status.lastResult);
  }

  Future<void> setAlertsEnabled(bool enabled) async {
    final config = await configStore.read();
    if (config == null || config.alertsEnabled == enabled) return;
    await configStore.save(config.copyWith(alertsEnabled: enabled));
    await loadConfigurationStatus();
  }

  Future<bool> sendTestAlert() async {
    if (!isBleConnected()) return false;
    final matchup = _sessions[_primaryId]?.latestMatchup;
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
    await _observe(startupOnly: true, sendAlerts: false);
  }

  Future<bool> syncStartupCategory() async {
    if (!_deviceContentEnabled) return false;
    await _reconcile();
    if (_primaryId?.startsWith('espn:') ?? false) {
      try {
        await syncPrimaryEspnMatchup();
      } on Object {
        // Sleeper startup baselines still establish independently below.
      }
    }
    await establishStartupBaseline();
    return deviceSession.baseline != null;
  }

  Future<void> removeConfiguration() async {
    await configStore.clear();
    await loadConfigurationStatus();
    await _clearPersistentFantasy();
  }

  Future<FantasyObservationResult> observe({bool sendAlerts = true}) =>
      _observe(sendAlerts: sendAlerts);

  Future<FantasyObservationResult> _observe({
    bool sendAlerts = true,
    bool startupOnly = false,
  }) async {
    if (!_deviceContentEnabled) {
      for (final session in _sessions.values) {
        session.pendingStore.clear();
      }
      return FantasyObservationResult(
        configured: _status.configured,
        baselineReset: false,
        alerts: const [],
        summary: 'Fantasy content is disabled for this device session.',
      );
    }
    if (_observing) {
      return FantasyObservationResult(
        configured: _status.configured,
        baselineReset: false,
        alerts: const [],
        summary: 'Skipped: fantasy observation already active.',
      );
    }
    _observing = true;
    final generation = _generation;
    try {
      final configs = await _reconcile();
      final results = <String, FantasyObservationResult>{};
      for (final config in configs) {
        if (generation != _generation) break;
        final session = _sessions[config.id];
        // A UI configuration edit may reconcile sessions while a loader awaits.
        if (session == null) continue;
        if (session.config.teamId == null) {
          results[config.id] = const FantasyObservationResult(
            configured: false,
            baselineReset: false,
            alerts: [],
            summary: 'Select a Sleeper roster.',
          );
          continue;
        }
        if (startupOnly && session.baselineEstablished) {
          final matchup = session.latestMatchup;
          final context = session.observationContext;
          final revision = session.revision;
          // Selecting a different primary changes device state, not scoring
          // baselines. Startup sync can publish its already-observed matchup.
          if (config.id == _primaryId && matchup != null && context != null) {
            await _syncPersistentMatchup(
              matchup,
              context,
              () =>
                  generation == _generation &&
                  revision == session.revision &&
                  identical(_sessions[config.id], session) &&
                  config.id == _primaryId,
            );
          }
          results[config.id] = FantasyObservationResult(
            configured: true,
            baselineReset: false,
            alerts: const [],
            matchup: session.latestMatchup,
            summary: 'Baseline already established.',
          );
          continue;
        }
        results[config.id] = await _observeLeague(
          session,
          sendAlerts,
          generation,
        );
      }
      if (_primaryId == null ||
          (_primaryId!.startsWith('sleeper:') &&
              _sessions[_primaryId]?.config.teamId == null)) {
        await _clearPersistentFantasy();
      }
      final alerts = [for (final result in results.values) ...result.alerts];
      final failures = results.values
          .where((result) => !result.succeeded)
          .length;
      final summary = results.length == 1
          ? results.values.single.summary
          : 'Observed ${results.length} Sleeper leagues; '
                '${alerts.length} alerts; $failures failures.';
      _updateStatus(summary);
      return FantasyObservationResult(
        configured: results.values.any((result) => result.configured),
        baselineReset: results.values.any((result) => result.baselineReset),
        alerts: List.unmodifiable(alerts),
        summary: summary,
        matchup: results[_primaryId]?.matchup,
        leagues: Map.unmodifiable(results),
        pendingAlerts: _status.pendingAlerts,
      );
    } on Object catch (error) {
      final summary = 'Fantasy configuration observation failed: $error';
      _diagnose(summary);
      _updateStatus(summary);
      return FantasyObservationResult(
        configured: _status.configured,
        baselineReset: false,
        alerts: const [],
        summary: summary,
        error: error,
      );
    } finally {
      _observing = false;
    }
  }

  Future<FantasyObservationResult> _observeLeague(
    SleeperLeagueObservationSession session,
    bool sendAlerts,
    int generation,
  ) async {
    final config = session.config;
    final pendingStore = session.pendingStore;
    final deltaTracker = session.deltaTracker;
    final revision = session.revision;
    bool isCurrent() =>
        generation == _generation &&
        identical(_sessions[config.id], session) &&
        revision == session.revision;
    try {
      final snapshot = await _matchupLoader(config.leagueId);
      final matchup = snapshot.matchupForRoster(int.parse(config.teamId!));
      if (!isCurrent()) return _connectionChangedResult();
      session.latestMatchup = matchup;
      final context =
          '${config.leagueId}|${snapshot.week}|'
          '${matchup.team.roster.rosterId}|'
          '${matchup.opponent.roster.rosterId}|'
          '${matchup.team.matchup.matchupId}';
      if (config.id == _primaryId) {
        await _syncPersistentMatchup(
          matchup,
          context,
          () => isCurrent() && config.id == _primaryId,
        );
      }
      if (!isCurrent()) return _connectionChangedResult();
      if (session.observationContext != context) {
        pendingStore.clear();
        session.observationContext = context;
      }
      final deltaResult = deltaTracker.observe(matchup);
      session.baselineEstablished = true;
      if (!config.alertsEnabled) {
        pendingStore.clear();
        return FantasyObservationResult(
          configured: true,
          baselineReset: deltaResult.baselineReset,
          alerts: const [],
          summary: 'Alerts are off.',
          matchup: matchup,
        );
      }
      Map<String, SleeperFantasyPlayer> metadata = const {};
      try {
        metadata = await _metadataResolver(
          deltaResult.events.map((event) => event.playerId),
        );
      } on Object catch (error) {
        // Optional display metadata must not lose scoring after advancing a baseline.
        _diagnose('Fantasy metadata unavailable for ${config.id}: $error');
      }
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
      if (!isCurrent()) return _connectionChangedResult();
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
      final deliveryError = sendAlerts
          ? await _drainPendingAlerts(session, isCurrent)
          : null;
      return FantasyObservationResult(
        configured: true,
        baselineReset: deltaResult.baselineReset,
        alerts: List.unmodifiable(alerts),
        summary: deliveryError != null
            ? 'Observed ${alerts.length} point changes; delivery failed; '
                  '${pendingStore.length} alerts retained.'
            : deltaResult.baselineReset
            ? 'Baseline established; no historical alerts.'
            : alerts.isEmpty
            ? 'No fantasy point changes.'
            : 'Observed ${alerts.length} fantasy point change(s).',
        matchup: matchup,
        deliveryError: deliveryError,
        pendingAlerts: pendingStore.length,
      );
    } on Object catch (error) {
      _diagnose('Fantasy observation failed for ${config.id}: $error');
      return FantasyObservationResult(
        configured: true,
        baselineReset: false,
        alerts: const [],
        summary: 'Fantasy observation failed for ${config.id}: $error',
        error: error,
        matchup: session.latestMatchup,
      );
    }
  }

  FantasyObservationResult _connectionChangedResult() =>
      const FantasyObservationResult(
        configured: true,
        baselineReset: false,
        alerts: [],
        summary: 'Connection or configuration changed; baseline deferred.',
      );

  Future<Object?> _drainPendingAlerts(
    SleeperLeagueObservationSession session,
    bool Function() isCurrent,
  ) async {
    final pendingStore = session.pendingStore;
    // observe() owns the drain, so concurrent observations cannot resend its head.
    while (isBleConnected() && isCurrent()) {
      final pending = pendingStore.next;
      if (pending == null) return null;
      try {
        await transport.sendFantasyAlert(pending.alert);
        pendingStore.markDelivered(pending.id);
        _diagnose('Fantasy alert delivered: ${pending.id}');
      } on Object catch (error) {
        _diagnose(
          'Fantasy alert ${session.config.id} retained after BLE failure: $error',
        );
        return error;
      }
    }
    return null;
  }

  Future<void> _syncPersistentMatchup(
    SleeperFantasyMatchup matchup,
    String context,
    bool Function() isCurrent,
  ) async {
    final persistentTransport = matchupTransport;
    if (persistentTransport == null || !isBleConnected()) return;
    final display = FantasyMatchupDisplayData.fromSleeper(matchup);
    if (deviceSession.matches(display, context)) {
      _diagnose('Fantasy matchup unchanged; persistent send skipped.');
      return;
    }
    try {
      await persistentTransport.sendFantasyMatchup(display);
      if (isCurrent()) deviceSession.record(display, context);
      _diagnose('Fantasy matchup sent; persistent baseline advanced.');
    } on Object catch (error) {
      _diagnose(
        'FANTASY: persistent matchup send failed; baseline retained: $error',
      );
    }
  }

  Future<void> _clearPersistentFantasy() async {
    final persistentTransport = matchupTransport;
    if (persistentTransport == null || !isBleConnected()) return;
    try {
      await persistentTransport.clearFantasyMatchup();
      deviceSession.reset();
      _diagnose('Persistent Fantasy content cleared.');
    } on Object catch (error) {
      _diagnose('Fantasy clear deferred after BLE failure: $error');
    }
  }

  void _updateStatus(String summary) {
    final eligible = _sessions.values.where(
      (session) => session.config.teamId != null,
    );
    _status = FantasyRuntimeStatus(
      configured: eligible.isNotEmpty,
      baselineReady:
          eligible.isNotEmpty && eligible.every((s) => s.baselineEstablished),
      pendingAlerts: _sessions.values.fold(
        0,
        (total, s) => total + s.pendingStore.length,
      ),
      lastResult: summary,
      // Summary only, never a global alert gate. Each session owns its setting.
      alertsEnabled:
          eligible.isEmpty || eligible.any((s) => s.config.alertsEnabled),
    );
    notifyListeners();
  }

  void _diagnose(String message) => onDiagnostic?.call(message);
}
