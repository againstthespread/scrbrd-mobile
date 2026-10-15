import 'dart:async';

import 'package:flutter/material.dart';

import 'background_score_refresh_dispatcher.dart';
import 'ble_device_state.dart';
import 'bluetooth_device_transport.dart';
import 'initial_device_sync_coordinator.dart';
import 'fantasy_live_observation_coordinator.dart';
import 'refresh_diagnostic_history.dart';
import 'fantasy_league_config.dart';
import 'fantasy_screen.dart';
import 'live_games_screen.dart';
import 'live_refresh_coordinator.dart';
import 'push_notification_service.dart';
import 'settings_screen.dart';
import 'sports_data_provider.dart';
import 'sports_league.dart';
import 'sports_operation_gate.dart';
import 'sports_repository.dart';
import 'session_aware_device_sender.dart';
import 'sleeper_api_client.dart';
import 'sleeper_fantasy_repository.dart';
import 'sleeper_player_repository.dart';
import 'sleeper_projection.dart';
import 'tracked_device_session.dart';
import 'favorites_store.dart';
import 'device_content_preferences.dart';
import 'device_content_preferences_store.dart';
import 'college_football.dart';
import 'college_football_preferences_store.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({
    super.key,
    required this.repository,
    this.transport,
    this.clock,
    this.favoritesStore,
    this.contentPreferencesStore,
    this.collegeFootballPreferencesStore,
    this.pushNotificationService = const PushNotificationService(),
  });

  final SportsRepository repository;
  final BluetoothDeviceTransport? transport;
  final DateTime Function()? clock;
  final FavoritesStore? favoritesStore;
  final DeviceContentPreferencesStore? contentPreferencesStore;
  final CollegeFootballPreferencesStore? collegeFootballPreferencesStore;
  final PushNotificationService pushNotificationService;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen>
    with WidgetsBindingObserver {
  late final BluetoothDeviceTransport _transport;
  late final SessionAwareDeviceSender _deviceSender;
  late final TrackedDeviceSession _trackedSession;
  late final LiveRefreshCoordinator _liveRefreshCoordinator;
  late final InitialDeviceSyncCoordinator _initialSyncCoordinator;
  late final SportsOperationGate _sportsOperationGate;
  late final SleeperApiClient _sleeperApiClient;
  late final SleeperFantasyRepository _fantasyRepository;
  late final SleeperPlayerRepository _sleeperPlayerRepository;
  late final SleeperSettlingProjectionService _sleeperProjectionService;
  late final FantasyLiveObservationCoordinator _fantasyCoordinator;
  late final FavoritesStore _favoritesStore;
  late final DeviceContentPreferencesStore _contentPreferencesStore;
  late DeviceContentPreferences _activeContentPreferences;
  late final CollegeFootballPreferencesStore _collegeFootballPreferencesStore;
  late CollegeFootballPreferences _activeCollegeFootballPreferences;
  StreamSubscription<BleDeviceSnapshot>? _snapshotSubscription;
  StreamSubscription<List<int>>? _wakeNotificationSubscription;
  StreamSubscription<BackgroundScoreRefreshRequest>? _scoreRefreshSubscription;
  late BleDeviceSnapshot _deviceSnapshot;
  PushNotificationDiagnostics? _pushDiagnostics;

  // Existing background-refresh diagnostics remain available in Developer Tools.
  var _lifecycleState = AppLifecycleState.resumed;
  late final RefreshDiagnosticHistory _backgroundRefreshDiagnostics;
  int _diagnosticRefreshId = 0;
  late final SportsRepository _repository;
  bool _isDisposing = false;
  InitialSyncSnapshot _initialSyncSnapshot = const InitialSyncSnapshot(
    status: InitialSyncStatus.idle,
  );

  bool get _isBusy =>
      _deviceSnapshot.state == BleConnectionState.scanning ||
      _deviceSnapshot.state == BleConnectionState.connecting ||
      _deviceSnapshot.state == BleConnectionState.sending;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository;
    WidgetsBinding.instance.addObserver(this);
    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    _favoritesStore = widget.favoritesStore ?? MemoryFavoritesStore();
    _contentPreferencesStore =
        widget.contentPreferencesStore ?? MemoryDeviceContentPreferencesStore();
    _activeContentPreferences = _contentPreferencesStore.read();
    _collegeFootballPreferencesStore =
        widget.collegeFootballPreferencesStore ??
        MemoryCollegeFootballPreferencesStore();
    _activeCollegeFootballPreferences = _collegeFootballPreferencesStore.read();
    _transport = widget.transport ?? BluetoothDeviceTransport();
    _transport.setWakeForeground(_lifecycleState == AppLifecycleState.resumed);
    _backgroundRefreshDiagnostics = _transport.diagnosticHistory;
    _trace(
      'lifecycle',
      'screen.init id=${identityHashCode(this)} state=${_lifecycleState.name}',
    );
    _trackedSession = TrackedDeviceSession()
      ..addListener(_handleTrackedSessionChanged);
    _deviceSender = SessionAwareDeviceSender(
      transport: _transport,
      session: _trackedSession,
      diagnosticHistory: _backgroundRefreshDiagnostics,
    );
    _sportsOperationGate = SportsOperationGate(
      onDiagnostic: (message) => _trace('gate', message),
    );
    _sleeperApiClient = SleeperApiClient();
    _fantasyRepository = SleeperFantasyRepository(_sleeperApiClient);
    _sleeperPlayerRepository = SleeperPlayerRepository(
      apiClient: _sleeperApiClient,
    );
    _sleeperProjectionService = SleeperSettlingProjectionService(
      projectionSource: SleeperApiProjectionSource(_sleeperApiClient),
      metadataResolver:
          _sleeperPlayerRepository.resolvePlayersWithRefreshSafely,
      gameStatusSource: SportsRepositorySleeperNflGameStatusSource(_repository),
      onDiagnostic: _recordBackgroundUpdaterDiagnostic,
    );
    _fantasyCoordinator = FantasyLiveObservationCoordinator(
      leagueConfigStore: SharedPreferencesFantasyLeagueConfigStore(),
      repository: _fantasyRepository,
      playerRepository: _sleeperPlayerRepository,
      transport: _deviceSender,
      isBleConnected: () =>
          _transport.currentSnapshot.state.isPhysicallyConnected,
      sleeperProjectionEnricher: _sleeperProjectionService,
      onDiagnostic: _recordBackgroundUpdaterDiagnostic,
      diagnosticHistory: _backgroundRefreshDiagnostics,
    );
    _fantasyCoordinator.addListener(_handleFantasyStatusChanged);
    unawaited(_fantasyCoordinator.loadConfigurationStatus());
    _liveRefreshCoordinator = LiveRefreshCoordinator(
      repository: _repository,
      transport: _deviceSender,
      session: _trackedSession,
      isBleConnected: () =>
          _transport.currentSnapshot.state.isPhysicallyConnected,
      onDiagnostic: _recordBackgroundUpdaterDiagnostic,
      readFavorites: _favoritesStore.readFavorites,
      readCollegeFootballPreferences: () => _activeCollegeFootballPreferences,
    );
    _initialSyncCoordinator = InitialDeviceSyncCoordinator(
      clock: widget.clock,
      repository: _repository,
      sender: _deviceSender,
      isBleConnected: () =>
          _transport.currentSnapshot.state.isPhysicallyConnected,
      operationGate: _sportsOperationGate,
      onStatusChanged: _recordInitialSyncStatus,
      onDiagnostic: (message) {
        debugPrint('INITIAL DEVICE SYNC: $message');
        _trace('sync', message);
      },
      readFavorites: _favoritesStore.readFavorites,
      readContentPreferences: () => _activeContentPreferences,
      readCollegeFootballPreferences: () => _activeCollegeFootballPreferences,
      prepareFantasyCategory: _fantasyCoordinator.prepareStartupCategory,
      prepareFantasyRefreshCategory: () =>
          _fantasyCoordinator.prepareStartupCategory(establishBaseline: false),
      canReplaceTeamSlate: _liveRefreshCoordinator.canReplaceTeamSlate,
      onAuthoritativeSyncStarted: _trackedSession.clear,
    );
    _deviceSnapshot = _transport.currentSnapshot;
    _wakeNotificationSubscription = _transport.wakeNotifications.listen(
      _handleBleWakeNotification,
    );
    _scoreRefreshSubscription = BackgroundScoreRefreshDispatcher.instance.events
        .listen((request) => unawaited(_handleBackgroundScoreRefresh(request)));
    _snapshotSubscription = _transport.snapshots.listen((snapshot) {
      _trace(
        'connection',
        'snapshot ${snapshot.state.name}; hasError=${snapshot.errorMessage != null}',
      );
      final wasConnected = _deviceSnapshot.state.isPhysicallyConnected;
      final isConnected = snapshot.state.isPhysicallyConnected;
      if (!wasConnected && isConnected) {
        debugPrint('physical BLE connection established');
        _activeContentPreferences = _contentPreferencesStore.read();
        _activeCollegeFootballPreferences = _collegeFootballPreferencesStore
            .read();
        _fantasyCoordinator.beginConnectionSession(
          fantasyEnabled: _activeContentPreferences.isEnabled(
            DeviceContentCategory.fantasy,
          ),
        );
        _fantasyCoordinator.holdDeviceUpdatesForStartup();
      } else if (wasConnected && !isConnected) {
        debugPrint('physical BLE connection ended');
        _fantasyCoordinator.endConnectionSession();
      }
      _initialSyncCoordinator.handleConnectionState(snapshot.state);
      if (snapshot.state == BleConnectionState.disconnected ||
          snapshot.state == BleConnectionState.error) {
        _liveRefreshCoordinator.cancelCurrentRefresh('BLE disconnected');
        _sportsOperationGate.clearDeferredWake();
      }
      if (mounted) setState(() => _deviceSnapshot = snapshot);
    });
    _loadPushDiagnostics();
  }

  void _handleTrackedSessionChanged() {
    if (mounted && !_isDisposing) setState(() {});
  }

  Future<void> _handleBackgroundScoreRefresh(
    BackgroundScoreRefreshRequest request,
  ) async {
    final connected = _transport.currentSnapshot.state.isPhysicallyConnected;
    _recordBackgroundUpdaterDiagnostic(
      'FCM BACKGROUND SCORE REFRESH: received; '
      'lifecycle=${_lifecycleState.name}; BLE connected=$connected',
    );
    var domainsSucceeded = true;
    await runBackgroundScoreRefresh(
      refresh: () => _requestAutomaticRefresh(
        'FCM BACKGROUND SCORE REFRESH',
        refresh: () => runIsolatedWakeDomains(
          refreshSports: () async {
            _recordBackgroundUpdaterDiagnostic(
              'FCM BACKGROUND SCORE REFRESH: sports refresh started',
            );
            final result = await _liveRefreshCoordinator
                .refreshTrackedSessionOnce();
            _recordBackgroundUpdaterDiagnostic(
              'FCM BACKGROUND SCORE REFRESH: sports operation ended; success=${result.succeeded}',
            );
            domainsSucceeded = domainsSucceeded && result.succeeded;
          },
          observeFantasy: () async {
            _recordBackgroundUpdaterDiagnostic(
              'FCM BACKGROUND SCORE REFRESH: fantasy observation started',
            );
            final result = await _fantasyCoordinator.observe();
            _recordBackgroundUpdaterDiagnostic(
              'FCM BACKGROUND SCORE REFRESH: fantasy observation completed; '
              'success=${result.succeeded}; alerts=${result.alertCount}; pending=${result.pendingAlerts}',
            );
            domainsSucceeded = domainsSucceeded && result.succeeded;
          },
          domainsSucceeded: () => domainsSucceeded,
          onDiagnostic: _recordBackgroundUpdaterDiagnostic,
          triggerLabel: 'FCM BACKGROUND SCORE REFRESH',
        ),
      ),
      complete: request.complete,
    );
  }

  @override
  void dispose() {
    _trace('lifecycle', 'screen.dispose id=${identityHashCode(this)}');
    _isDisposing = true;
    WidgetsBinding.instance.removeObserver(this);
    _liveRefreshCoordinator.cancelCurrentRefresh('connection screen disposed');
    _initialSyncCoordinator.handleConnectionState(
      BleConnectionState.disconnected,
    );
    _sportsOperationGate.clearDeferredWake();
    _scoreRefreshSubscription?.cancel();
    _wakeNotificationSubscription?.cancel();
    _snapshotSubscription?.cancel();
    _transport.dispose();
    _fantasyCoordinator.removeListener(_handleFantasyStatusChanged);
    _fantasyCoordinator.dispose();
    _sleeperApiClient.close();
    _trackedSession.removeListener(_handleTrackedSessionChanged);
    _trackedSession.dispose();
    super.dispose();
  }

  void _handleFantasyStatusChanged() {
    if (mounted && !_isDisposing) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previous = _lifecycleState;
    _lifecycleState = state;
    _trace(
      'lifecycle',
      '${previous.name}->${state.name}; screen=${identityHashCode(this)} connected=${_transport.currentSnapshot.state.isPhysicallyConnected}',
    );
    _transport.setWakeForeground(state == AppLifecycleState.resumed);
    debugPrint('BACKGROUND SCORE REFRESH: lifecycle=${state.name}');
    if (state == AppLifecycleState.resumed &&
        previous != state &&
        !_isDisposing &&
        _transport.currentSnapshot.state.isPhysicallyConnected) {
      unawaited(_transport.resumeWakeNotifications());
      unawaited(_requestAutomaticRefresh('APP RESUME'));
    }
  }

  void _handleBleWakeNotification(List<int> payload) {
    _trace('refresh', 'wake.forwarded bytes=${payload.length}');
    final connected = _transport.currentSnapshot.state.isPhysicallyConnected;
    debugPrint(
      'BLE WAKE: WAKE received; lifecycle=${_lifecycleState.name}; '
      'BLE connected=$connected; refresh permitted=$connected; '
      'bytes=${payload.length}',
    );
    unawaited(_requestAutomaticRefresh('BLE WAKE'));
  }

  Future<void> _requestAutomaticRefresh(
    String trigger, {
    Future<bool> Function()? refresh,
  }) async {
    final id = ++_diagnosticRefreshId;
    final originG = _transport.connectionGeneration;
    final elapsed = Stopwatch()..start();
    var outcome = 'failed';
    _trace(
      'refresh',
      'request.begin id=$id trigger=$trigger; ${_initialSyncCoordinator.diagnosticState}',
      generation: originG,
    );
    try {
      if (_isDisposing ||
          !_transport.currentSnapshot.state.isPhysicallyConnected) {
        outcome = 'skipped-disposed-or-disconnected';
        return;
      }
      if (_initialSyncCoordinator.needsRetry) {
        _trace(
          'refresh',
          'retry.enter id=$id; ${_initialSyncCoordinator.diagnosticState}',
          generation: originG,
        );
        try {
          await _initialSyncCoordinator.retryPendingSync();
          outcome = 'retry-returned';
        } finally {
          _trace(
            'refresh',
            'retry.exit id=$id outcome=$outcome; ${_initialSyncCoordinator.diagnosticState}',
            generation: originG,
          );
        }
        return;
      }
      _trace(
        'refresh',
        'discovery.enter id=$id; ${_initialSyncCoordinator.diagnosticState}',
        generation: originG,
      );
      var discovered = false;
      var discoveryReturned = false;
      try {
        discovered = await _initialSyncCoordinator.refreshDesiredContentIfDue();
        discoveryReturned = true;
      } finally {
        _trace(
          'refresh',
          'discovery.exit id=$id returned=$discoveryReturned handled=$discovered',
          generation: originG,
        );
      }
      if (discovered) {
        outcome = 'discovery-returned';
        return;
      }
      _trace(
        'refresh',
        'gate.request id=$id; ${_sportsOperationGate.diagnosticState}',
        generation: originG,
      );
      await _sportsOperationGate.requestLiveRefresh(() async {
        var execution = 'failed';
        _trace('refresh', 'execution.begin id=$id', generation: originG);
        try {
          // A deferred WAKE must not overwrite retained Fantasy after startup failure.
          if (_isDisposing ||
              originG != _transport.connectionGeneration ||
              _initialSyncCoordinator.needsRetry ||
              !_transport.currentSnapshot.state.isPhysicallyConnected) {
            execution = 'skipped-disposed-retry-or-disconnected';
            return;
          }
          bool succeeded;
          if (refresh != null) {
            succeeded = await refresh();
          } else {
            var domainsSucceeded = true;
            succeeded = await runIsolatedWakeDomains(
              domainsSucceeded: () => domainsSucceeded,
              refreshSports: () async {
                _trace('refresh', 'sports.enter id=$id', generation: originG);
                try {
                  final result = await _liveRefreshCoordinator
                      .refreshTrackedSessionOnce();
                  domainsSucceeded = domainsSucceeded && result.succeeded;
                } finally {
                  _trace('refresh', 'sports.exit id=$id', generation: originG);
                }
              },
              observeFantasy: () async {
                _trace('refresh', 'fantasy.enter id=$id', generation: originG);
                try {
                  final result = await _fantasyCoordinator.observe();
                  domainsSucceeded = domainsSucceeded && result.succeeded;
                } finally {
                  _trace('refresh', 'fantasy.exit id=$id', generation: originG);
                }
              },
              onDiagnostic: _recordBackgroundUpdaterDiagnostic,
              triggerLabel: trigger,
            );
          }
          execution = succeeded
              ? 'completed'
              : 'completed-with-failures-or-retained-data';
        } finally {
          _trace(
            'refresh',
            'execution.end id=$id outcome=$execution',
            generation: originG,
          );
        }
      });
      // A gate request can return while deferred; execution.end records actual work.
      outcome = 'gate-returned';
    } on Object catch (error) {
      _trace(
        'refresh',
        'request.failed id=$id type=${error.runtimeType}',
        generation: originG,
      );
      rethrow;
    } finally {
      _trace(
        'refresh',
        'request.end id=$id outcome=$outcome elapsedMs=${elapsed.elapsedMilliseconds}',
        generation: originG,
      );
    }
  }

  void _trace(String source, String message, {int? generation}) {
    _backgroundRefreshDiagnostics.add(
      message,
      source: source,
      transportId: _transport.diagnosticId,
      generation: generation ?? _transport.connectionGeneration,
    );
  }

  static final _refreshPhasePattern = RegExp(
    r'^WAKE REFRESH #\d+ (fetch phase started|fetch phase complete|send phase started|complete)',
  );
  static final _sportsPhasePattern = RegExp(
    r'^WAKE #\d+ (NFL|NCAAF|NBA|MLB|PGA) (fetch started|fetch completed|fetch failed|no update: fetch failed; baseline retained|empty; baseline retained|unchanged|changed|transfer started|transfer succeeded|transfer failed)',
  );

  void _recordBackgroundUpdaterDiagnostic(String message) {
    // Only allow fixed phase metadata into the timeline. Domain callbacks may
    // contain provider URLs, account identifiers or player payloads; do not
    // forward those free-form messages to either the export or the console.
    final phase =
        _refreshPhasePattern.firstMatch(message) ??
        _sportsPhasePattern.firstMatch(message);
    if (phase != null) _trace('sports', phase.group(0)!);
    if (message.startsWith('refresh skipped because')) {
      _trace('sports', 'skipped-already-active');
    } else if (message.startsWith('refresh cancellation requested')) {
      _trace('sports', 'cancellation.requested');
    } else if (message.startsWith('refresh cancelled:')) {
      _trace('sports', 'cancelled-disconnected-or-stopped');
    } else if (message.startsWith('PGA no update: refresh/transfer failed:')) {
      _trace('sports', 'PGA transfer.failed; baseline retained');
    }
    if (message.contains(': sports failed; fantasy continues:')) {
      _trace('domain', 'sports.failed; fantasy continues');
    } else if (message.contains(': fantasy failed; sports unaffected:')) {
      _trace('domain', 'fantasy.failed; sports unaffected');
    }
  }

  void _recordInitialSyncStatus(InitialSyncSnapshot snapshot) {
    _trace(
      'sync',
      'status=${snapshot.status.name} categories=${snapshot.successfullySyncedLeagueCount} unverified=${snapshot.cachedContentMayBeStale}',
    );
    if (mounted && !_isDisposing) {
      setState(() => _initialSyncSnapshot = snapshot);
    }
  }

  Future<void> _connect() => _transport.scanForDevice();

  Future<void> _disconnect() => _transport.disconnect();

  Future<void> _connectToCandidate(BleDeviceCandidate candidate) =>
      _transport.connectToDevice(candidate);

  void _openLiveGames() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LiveGamesScreen(
          repository: _repository,
          transport: _deviceSender,
          trackedSession: _trackedSession,
          favoritesStore: _favoritesStore,
          collegeFootballPreferencesStore: _collegeFootballPreferencesStore,
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          repository: _repository,
          transport: _deviceSender,
          trackedSession: _trackedSession,
          providerLabel: selectSportsDataProvider().label,
          pushDiagnostics: _pushDiagnostics,
          onRefreshPushDiagnostics: _loadPushDiagnostics,
          backgroundRefreshDiagnostics: _backgroundRefreshDiagnostics,
          fantasyCoordinator: _fantasyCoordinator,
          fantasyPlayerRepository: _sleeperPlayerRepository,
          favoritesStore: _favoritesStore,
          contentPreferencesStore: _contentPreferencesStore,
          collegeFootballPreferencesStore: _collegeFootballPreferencesStore,
        ),
      ),
    );
  }

  void _openFantasy() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FantasyScreen(
          coordinator: _fantasyCoordinator,
          playerRepository: _sleeperPlayerRepository,
        ),
      ),
    );
  }

  Future<PushNotificationDiagnostics> _loadPushDiagnostics() async {
    final diagnostics = await widget.pushNotificationService.readDiagnostics();
    if (mounted) setState(() => _pushDiagnostics = diagnostics);
    return diagnostics;
  }

  @override
  Widget build(BuildContext context) {
    return ScrbrdHomeView(
      snapshot: _deviceSnapshot,
      initialSyncSnapshot: _initialSyncSnapshot,
      trackedContent: _trackedSession.snapshot(),
      onConnect: _isBusy ? null : _connect,
      onDisconnect: _isBusy ? null : _disconnect,
      onCandidateSelected: _connectToCandidate,
      onViewGames: _openLiveGames,
      onOpenFantasy: _openFantasy,
      fantasyConfigured: _fantasyCoordinator.status.configured,
      fantasyAlertsEnabled: _fantasyCoordinator.status.alertsEnabled,
      onOpenSettings: _openSettings,
    );
  }
}

class ScrbrdHomeView extends StatelessWidget {
  const ScrbrdHomeView({
    super.key,
    required this.snapshot,
    required this.initialSyncSnapshot,
    required this.trackedContent,
    required this.onConnect,
    required this.onDisconnect,
    required this.onCandidateSelected,
    required this.onViewGames,
    required this.onOpenFantasy,
    this.fantasyConfigured = false,
    this.fantasyAlertsEnabled = true,
    required this.onOpenSettings,
  });

  final BleDeviceSnapshot snapshot;
  final InitialSyncSnapshot initialSyncSnapshot;
  final Map<SportsLeague, TrackedLeagueContent> trackedContent;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;
  final ValueChanged<BleDeviceCandidate> onCandidateSelected;
  final VoidCallback onViewGames;
  final VoidCallback onOpenFantasy;
  final bool fantasyConfigured;
  final bool fantasyAlertsEnabled;
  final VoidCallback onOpenSettings;

  bool get _connected =>
      snapshot.state == BleConnectionState.connected ||
      snapshot.state == BleConnectionState.sending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('SCRBRD'),
        actions: [
          IconButton(
            onPressed: onOpenSettings,
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Text(
              'Today, at a glance.',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _connected
                  ? 'Your scoreboard is ready for today’s action.'
                  : "Connect to your device to load today's sports.",
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            _ConnectionStatusCard(
              snapshot: snapshot,
              syncSnapshot: initialSyncSnapshot,
            ),
            if (!_connected) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onConnect,
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Connect to SCRBRD'),
              ),
            ] else ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onDisconnect,
                  child: const Text('Disconnect'),
                ),
              ),
            ],
            if (snapshot.candidates.isNotEmpty && !_connected) ...[
              const SizedBox(height: 18),
              Text('Nearby SCRBRD devices', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              ...snapshot.candidates.map(
                (candidate) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.bluetooth),
                    title: Text(candidate.name),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: snapshot.state == BleConnectionState.connecting
                        ? null
                        : () => onCandidateSelected(candidate),
                  ),
                ),
              ),
            ],
            if (snapshot.state == BleConnectionState.error) ...[
              const SizedBox(height: 12),
              Text(
                'Could not connect to SCRBRD. Try again.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            _FantasyHomeCard(
              configured: fantasyConfigured,
              alertsEnabled: fantasyAlertsEnabled,
              onOpen: onOpenFantasy,
            ),
            if (trackedContent.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(
                "Today's Sports",
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              _TrackedSportsCard(content: trackedContent),
            ] else if (_connected &&
                initialSyncSnapshot.status == InitialSyncStatus.empty) ...[
              const SizedBox(height: 24),
              const Center(child: Text('No sports loaded today.')),
            ],
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: onViewGames,
              icon: const Icon(Icons.calendar_today_outlined),
              label: const Text("View Today's Games"),
            ),
          ],
        ),
      ),
    );
  }
}

class _FantasyHomeCard extends StatelessWidget {
  const _FantasyHomeCard({
    required this.configured,
    required this.alertsEnabled,
    required this.onOpen,
  });

  final bool configured;
  final bool alertsEnabled;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  child: Icon(
                    Icons.sports_football,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Fantasy Football',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              configured
                  ? 'Configured • Alerts ${alertsEnabled ? 'On' : 'Off'}'
                  : 'Connect your Sleeper league and get live fantasy scoring '
                        'alerts on SCRBRD.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              key: const Key('home-fantasy-action'),
              onPressed: onOpen,
              child: Text(configured ? 'VIEW MATCHUP' : 'SET UP FANTASY'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionStatusCard extends StatelessWidget {
  const _ConnectionStatusCard({
    required this.snapshot,
    required this.syncSnapshot,
  });

  final BleDeviceSnapshot snapshot;
  final InitialSyncSnapshot syncSnapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected =
        snapshot.state == BleConnectionState.connected ||
        snapshot.state == BleConnectionState.sending;
    final (title, detail) = _statusText();
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: connected
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerLow,
              child: Icon(
                connected ? Icons.bluetooth_connected : Icons.bluetooth,
                color: connected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (snapshot.state == BleConnectionState.scanning ||
                snapshot.state == BleConnectionState.connecting ||
                syncSnapshot.status == InitialSyncStatus.syncing)
              const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
          ],
        ),
      ),
    );
  }

  (String, String?) _statusText() {
    if (snapshot.state == BleConnectionState.scanning) {
      return ('Looking for SCRBRD...', null);
    }
    if (snapshot.state == BleConnectionState.connecting) {
      return ('Connecting...', 'Looking for your SCRBRD');
    }
    if (snapshot.state == BleConnectionState.error) {
      return ('Disconnected', 'Could not connect to SCRBRD.');
    }
    if (snapshot.state == BleConnectionState.disconnected) {
      return ('Disconnected', null);
    }
    if (snapshot.errorMessage != null) {
      return ('Connected', snapshot.errorMessage);
    }
    if (syncSnapshot.cachedContentMayBeStale &&
        syncSnapshot.status != InitialSyncStatus.syncing) {
      return ('Connected', 'Updates incomplete; cached data unverified');
    }
    return switch (syncSnapshot.status) {
      InitialSyncStatus.syncing => (
        "Syncing today's sports...",
        '${syncSnapshot.successfullySyncedLeagueCount} leagues loaded',
      ),
      InitialSyncStatus.complete => (
        'Connected',
        '${syncSnapshot.successfullySyncedLeagueCount} leagues synced',
      ),
      InitialSyncStatus.partialFailure => (
        'Connected',
        "Some sports couldn't be loaded",
      ),
      InitialSyncStatus.failure => ('Connected', "Sports couldn't be loaded"),
      InitialSyncStatus.empty => ('Connected', 'No sports loaded today'),
      InitialSyncStatus.idle => ('Connected', null),
    };
  }
}

class _TrackedSportsCard extends StatelessWidget {
  const _TrackedSportsCard({required this.content});

  final Map<SportsLeague, TrackedLeagueContent> content;

  @override
  Widget build(BuildContext context) {
    final entries = SportsLeague.values
        .where(content.containsKey)
        .map((league) => content[league]!)
        .toList();
    return Card(
      child: Column(
        children: [
          for (var index = 0; index < entries.length; index++) ...[
            _TrackedSportRow(content: entries[index]),
            if (index != entries.length - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

class _TrackedSportRow extends StatelessWidget {
  const _TrackedSportRow({required this.content});

  final TrackedLeagueContent content;

  @override
  Widget build(BuildContext context) {
    final detail = switch (content) {
      TrackedTeamSlate slate =>
        '${slate.games.length} ${slate.games.length == 1 ? 'game' : 'games'}',
      TrackedGolfLeaderboard golf => golf.leaderboard.tournamentName,
    };
    return ListTile(
      leading: CircleAvatar(child: Text(content.league.label.substring(0, 1))),
      title: Text(
        content.league.label,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      trailing: SizedBox(
        width: 190,
        child: Text(
          detail,
          textAlign: TextAlign.end,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
