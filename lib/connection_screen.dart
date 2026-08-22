import 'dart:async';

import 'package:flutter/material.dart';

import 'background_score_refresh_dispatcher.dart';
import 'ble_device_state.dart';
import 'bluetooth_device_transport.dart';
import 'initial_device_sync_coordinator.dart';
import 'live_activity_diagnostics.dart';
import 'live_games_screen.dart';
import 'live_refresh_coordinator.dart';
import 'push_notification_service.dart';
import 'settings_screen.dart';
import 'sports_data_provider.dart';
import 'sports_league.dart';
import 'sports_repository.dart';
import 'session_aware_device_sender.dart';
import 'tracked_device_session.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({
    super.key,
    required this.repository,
    this.pushNotificationService = const PushNotificationService(),
  });

  final SportsRepository repository;
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
  StreamSubscription<BleDeviceSnapshot>? _snapshotSubscription;
  StreamSubscription<List<int>>? _wakeNotificationSubscription;
  StreamSubscription<BackgroundScoreRefreshRequest>? _scoreRefreshSubscription;
  late BleDeviceSnapshot _deviceSnapshot;
  PushNotificationDiagnostics? _pushDiagnostics;
  final _liveActivityDiagnostics = LiveActivityDiagnostics();

  // Existing background-refresh diagnostics remain available in Developer Tools.
  var _isAppBackgrounded = false;
  var _lifecycleState = AppLifecycleState.resumed;
  String _backgroundUpdaterStatus = 'Waiting for a BLE WAKE notification.';
  String _liveActivityDiagnosticStatus = 'Live Activity not started.';
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
    WidgetsBinding.instance.addObserver(this);
    _transport = BluetoothDeviceTransport();
    _trackedSession = TrackedDeviceSession()
      ..addListener(_handleTrackedSessionChanged);
    _deviceSender = SessionAwareDeviceSender(
      transport: _transport,
      session: _trackedSession,
    );
    _liveRefreshCoordinator = LiveRefreshCoordinator(
      repository: widget.repository,
      transport: _deviceSender,
      session: _trackedSession,
      isAppBackgrounded: () => _isAppBackgrounded,
      isBleConnected: () =>
          _transport.currentSnapshot.state == BleConnectionState.connected,
      isLiveActivityActive: _liveActivityDiagnostics.isActive,
      onDiagnostic: _recordBackgroundUpdaterDiagnostic,
    );
    _initialSyncCoordinator = InitialDeviceSyncCoordinator(
      repository: widget.repository,
      sender: _deviceSender,
      isBleConnected: () =>
          _transport.currentSnapshot.state == BleConnectionState.connected,
      onStatusChanged: _recordInitialSyncStatus,
      onDiagnostic: (message) => debugPrint('INITIAL DEVICE SYNC: $message'),
    );
    _deviceSnapshot = _transport.currentSnapshot;
    _wakeNotificationSubscription = _transport.wakeNotifications.listen(
      _handleBleWakeNotification,
    );
    _scoreRefreshSubscription = BackgroundScoreRefreshDispatcher.instance.events
        .listen((request) => unawaited(_handleBackgroundScoreRefresh(request)));
    _snapshotSubscription = _transport.snapshots.listen((snapshot) {
      _initialSyncCoordinator.handleConnectionState(snapshot.state);
      if (snapshot.state == BleConnectionState.disconnected ||
          snapshot.state == BleConnectionState.error) {
        _liveRefreshCoordinator.cancelCurrentRefresh('BLE disconnected');
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
    await _liveRefreshCoordinator.refreshTrackedSessionOnce();
    request.complete();
  }

  @override
  void dispose() {
    _isDisposing = true;
    WidgetsBinding.instance.removeObserver(this);
    _liveRefreshCoordinator.cancelCurrentRefresh('connection screen disposed');
    _scoreRefreshSubscription?.cancel();
    _wakeNotificationSubscription?.cancel();
    _snapshotSubscription?.cancel();
    _transport.dispose();
    _trackedSession.removeListener(_handleTrackedSessionChanged);
    _trackedSession.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    debugPrint('TEMP BACKGROUND SCORE UPDATER: lifecycle=${state.name}');
    if (state == AppLifecycleState.paused) {
      _isAppBackgrounded = true;
    } else if (state == AppLifecycleState.resumed) {
      _isAppBackgrounded = false;
      _liveRefreshCoordinator.cancelCurrentRefresh(
        'app returned to foreground',
      );
    }
  }

  void _handleBleWakeNotification(List<int> payload) {
    debugPrint(
      'TEMP BLE WAKE EXPERIMENT: wake notification received; '
      'lifecycle=${_lifecycleState.name}; payload=$payload',
    );
    unawaited(_liveRefreshCoordinator.refreshTrackedSessionOnce());
  }

  Future<void> _startLiveActivityDiagnostic() async {
    final status = await _liveActivityDiagnostics.start();
    _setLiveActivityDiagnosticStatus(status);
  }

  Future<void> _endLiveActivityDiagnostic() async {
    _liveRefreshCoordinator.cancelCurrentRefresh(
      'Live Activity ended manually',
    );
    final status = await _liveActivityDiagnostics.end();
    _setLiveActivityDiagnosticStatus(status);
  }

  void _setLiveActivityDiagnosticStatus(String status) {
    if (mounted) setState(() => _liveActivityDiagnosticStatus = status);
  }

  void _recordBackgroundUpdaterDiagnostic(String message) {
    debugPrint('TEMP BACKGROUND SCORE UPDATER: $message');
    if (mounted && !_isDisposing) {
      setState(() => _backgroundUpdaterStatus = message);
    }
  }

  void _recordInitialSyncStatus(InitialSyncSnapshot snapshot) {
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
          repository: widget.repository,
          transport: _deviceSender,
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          repository: widget.repository,
          transport: _deviceSender,
          providerLabel: selectSportsDataProvider().label,
          pushDiagnostics: _pushDiagnostics,
          onRefreshPushDiagnostics: _loadPushDiagnostics,
          liveActivityStatus: _liveActivityDiagnosticStatus,
          onStartLiveActivity: _startLiveActivityDiagnostic,
          onEndLiveActivity: _endLiveActivityDiagnostic,
          backgroundRefreshStatus: _backgroundUpdaterStatus,
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
    required this.onOpenSettings,
  });

  final BleDeviceSnapshot snapshot;
  final InitialSyncSnapshot initialSyncSnapshot;
  final Map<SportsLeague, TrackedLeagueContent> trackedContent;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;
  final ValueChanged<BleDeviceCandidate> onCandidateSelected;
  final VoidCallback onViewGames;
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
    if (snapshot.state == BleConnectionState.scanning ||
        snapshot.state == BleConnectionState.connecting) {
      return ('Connecting...', 'Looking for your SCRBRD');
    }
    if (snapshot.state == BleConnectionState.error) {
      return ('Disconnected', 'Could not connect to SCRBRD.');
    }
    if (snapshot.state == BleConnectionState.disconnected) {
      return ('Disconnected', null);
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
