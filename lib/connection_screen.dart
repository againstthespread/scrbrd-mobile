import 'dart:async';

import 'package:flutter/material.dart';

import 'ble_device_state.dart';
import 'bluetooth_device_transport.dart';
import 'game_editor.dart';
import 'live_games_screen.dart';
import 'push_notification_service.dart';
import 'sports_repository.dart';

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

class _ConnectionScreenState extends State<ConnectionScreen> {
  static const _deviceName = 'Peter Sports Hub';
  static const _deviceTransport = 'Bluetooth Low Energy';

  late final BluetoothDeviceTransport _transport;
  StreamSubscription<BleDeviceSnapshot>? _snapshotSubscription;
  late BleDeviceSnapshot _deviceSnapshot;
  PushNotificationDiagnostics? _pushDiagnostics;

  bool get _isBusy =>
      _deviceSnapshot.state == BleConnectionState.scanning ||
      _deviceSnapshot.state == BleConnectionState.connecting ||
      _deviceSnapshot.state == BleConnectionState.sending;

  bool get _isConnected =>
      _deviceSnapshot.state == BleConnectionState.connected;

  @override
  void initState() {
    super.initState();
    _transport = BluetoothDeviceTransport();
    _deviceSnapshot = _transport.currentSnapshot;
    _snapshotSubscription = _transport.snapshots.listen((snapshot) {
      if (!mounted) {
        return;
      }

      setState(() {
        _deviceSnapshot = snapshot;
      });
    });
    _loadPushDiagnostics();
  }

  @override
  void dispose() {
    _snapshotSubscription?.cancel();
    _transport.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    await _transport.scanForDevice();
  }

  Future<void> _disconnect() async {
    await _transport.disconnect();
  }

  void _handlePrimaryAction() {
    if (_isConnected) {
      _disconnect();
      return;
    }

    if (!_isBusy) {
      _connect();
    }
  }

  void _openLiveGames() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => LiveGamesScreen(
          repository: widget.repository,
          transport: _transport,
        ),
      ),
    );
  }

  Future<void> _connectToCandidate(BleDeviceCandidate candidate) async {
    await _transport.connectToDevice(candidate);
  }

  Future<void> _loadPushDiagnostics() async {
    final diagnostics = await widget.pushNotificationService.readDiagnostics();
    if (!mounted) {
      return;
    }

    setState(() {
      _pushDiagnostics = diagnostics;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.scoreboard_outlined,
                    size: 56,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Sports Hub',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Connect to the handheld scoreboard to send compact game updates from your phone.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  _ConnectionStatusCard(
                    snapshot: _deviceSnapshot,
                    deviceName: _deviceSnapshot.deviceName ?? _deviceName,
                    deviceTransport: _deviceTransport,
                  ),
                  const SizedBox(height: 16),
                  _PushNotificationDiagnosticsPanel(
                    diagnostics: _pushDiagnostics,
                    onRefresh: _loadPushDiagnostics,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _isBusy ? null : _handlePrimaryAction,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: Text(_isConnected ? 'Disconnect' : 'Connect'),
                  ),
                  if (_deviceSnapshot.state == BleConnectionState.scanning ||
                      _deviceSnapshot.state == BleConnectionState.connecting ||
                      _deviceSnapshot.state == BleConnectionState.sending) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(
                      _progressText(_deviceSnapshot.state),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (_deviceSnapshot.errorMessage != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _deviceSnapshot.errorMessage!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.error,
                      ),
                    ),
                  ],
                  if (_deviceSnapshot.candidates.isNotEmpty &&
                      !_isConnected) ...[
                    const SizedBox(height: 24),
                    Text(
                      'Discovered Devices',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ..._deviceSnapshot.candidates.map(
                      (candidate) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: OutlinedButton.icon(
                          onPressed:
                              _deviceSnapshot.state ==
                                  BleConnectionState.connecting
                              ? null
                              : () => _connectToCandidate(candidate),
                          icon: const Icon(Icons.bluetooth_connected),
                          label: Text(candidate.name),
                        ),
                      ),
                    ),
                  ],
                  if (_isConnected) ...[
                    const SizedBox(height: 24),
                    OutlinedButton.icon(
                      onPressed: _openLiveGames,
                      icon: const Icon(Icons.sports_football),
                      label: const Text('Games'),
                    ),
                    const SizedBox(height: 16),
                    GameEditor(transport: _transport),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _progressText(BleConnectionState state) {
    return switch (state) {
      BleConnectionState.scanning => 'Scanning for $_deviceName...',
      BleConnectionState.connecting => 'Connecting to $_deviceName...',
      BleConnectionState.sending => 'Sending packet to $_deviceName...',
      _ => '',
    };
  }
}

class _ConnectionStatusCard extends StatelessWidget {
  const _ConnectionStatusCard({
    required this.snapshot,
    required this.deviceName,
    required this.deviceTransport,
  });

  final BleDeviceSnapshot snapshot;
  final String deviceName;
  final String deviceTransport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isConnected =
        snapshot.state == BleConnectionState.connected ||
        snapshot.state == BleConnectionState.sending;
    final isBusy =
        snapshot.state == BleConnectionState.scanning ||
        snapshot.state == BleConnectionState.connecting;

    final statusText = switch (snapshot.state) {
      BleConnectionState.connected ||
      BleConnectionState.sending => 'Connected to $deviceName',
      BleConnectionState.scanning => 'Scanning',
      BleConnectionState.connecting => 'Connecting',
      BleConnectionState.error => 'Connection error',
      BleConnectionState.disconnected => 'Not connected',
    };

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isConnected
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
                  color: isConnected ? Colors.green : colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isBusy ? '$statusText...' : statusText,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _DeviceDetailRow(label: 'Device', value: deviceName),
            const SizedBox(height: 8),
            _DeviceDetailRow(label: 'Transport', value: deviceTransport),
          ],
        ),
      ),
    );
  }
}

class _PushNotificationDiagnosticsPanel extends StatelessWidget {
  const _PushNotificationDiagnosticsPanel({
    required this.diagnostics,
    required this.onRefresh,
  });

  final PushNotificationDiagnostics? diagnostics;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final diagnostics = this.diagnostics;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Temporary FCM Diagnostics',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh FCM diagnostics',
                ),
              ],
            ),
            const SizedBox(height: 8),
            _DeviceDetailRow(
              label: 'Permission',
              value: diagnostics?.permissionStatus ?? 'Checking...',
            ),
            const SizedBox(height: 8),
            Text(
              'FCM token',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              diagnostics?.tokenStatus ?? 'Checking...',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            if (diagnostics?.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                diagnostics!.errorMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DeviceDetailRow extends StatelessWidget {
  const _DeviceDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
