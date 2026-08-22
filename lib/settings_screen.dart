import 'package:flutter/material.dart';

import 'device_transport.dart';
import 'game_editor.dart';
import 'live_games_screen.dart';
import 'push_notification_service.dart';
import 'sports_repository.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.repository,
    required this.transport,
    required this.providerLabel,
    required this.pushDiagnostics,
    required this.onRefreshPushDiagnostics,
    required this.liveActivityStatus,
    required this.onStartLiveActivity,
    required this.onEndLiveActivity,
    required this.backgroundRefreshStatus,
  });

  final SportsRepository repository;
  final DeviceTransport transport;
  final String providerLabel;
  final PushNotificationDiagnostics? pushDiagnostics;
  final Future<PushNotificationDiagnostics> Function() onRefreshPushDiagnostics;
  final String liveActivityStatus;
  final Future<void> Function() onStartLiveActivity;
  final Future<void> Function() onEndLiveActivity;
  final String backgroundRefreshStatus;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.build_outlined),
              title: const Text('Developer Tools'),
              subtitle: const Text('Diagnostics and manual device controls'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DeveloperToolsScreen(
                    repository: repository,
                    transport: transport,
                    providerLabel: providerLabel,
                    pushDiagnostics: pushDiagnostics,
                    onRefreshPushDiagnostics: onRefreshPushDiagnostics,
                    liveActivityStatus: liveActivityStatus,
                    onStartLiveActivity: onStartLiveActivity,
                    onEndLiveActivity: onEndLiveActivity,
                    backgroundRefreshStatus: backgroundRefreshStatus,
                  ),
                ),
              ),
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.favorite_border),
              title: Text('Favorites'),
              subtitle: Text('Coming soon'),
              enabled: false,
            ),
          ),
        ],
      ),
    );
  }
}

class DeveloperToolsScreen extends StatefulWidget {
  const DeveloperToolsScreen({
    super.key,
    required this.repository,
    required this.transport,
    required this.providerLabel,
    required this.pushDiagnostics,
    required this.onRefreshPushDiagnostics,
    required this.liveActivityStatus,
    required this.onStartLiveActivity,
    required this.onEndLiveActivity,
    required this.backgroundRefreshStatus,
  });

  final SportsRepository repository;
  final DeviceTransport transport;
  final String providerLabel;
  final PushNotificationDiagnostics? pushDiagnostics;
  final Future<PushNotificationDiagnostics> Function() onRefreshPushDiagnostics;
  final String liveActivityStatus;
  final Future<void> Function() onStartLiveActivity;
  final Future<void> Function() onEndLiveActivity;
  final String backgroundRefreshStatus;

  @override
  State<DeveloperToolsScreen> createState() => _DeveloperToolsScreenState();
}

class _DeveloperToolsScreenState extends State<DeveloperToolsScreen> {
  late PushNotificationDiagnostics? _pushDiagnostics;

  @override
  void initState() {
    super.initState();
    _pushDiagnostics = widget.pushDiagnostics;
  }

  Future<void> _refreshPushDiagnostics() async {
    final diagnostics = await widget.onRefreshPushDiagnostics();
    if (mounted) setState(() => _pushDiagnostics = diagnostics);
  }

  @override
  Widget build(BuildContext context) {
    final diagnostics = _pushDiagnostics;
    return Scaffold(
      appBar: AppBar(title: const Text('Developer Tools')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionCard(
            title: 'Manual device controls',
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.sports_score),
                title: const Text('Games and slate tools'),
                subtitle: const Text(
                  'Refresh leagues and manually send loaded content',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LiveGamesScreen(
                      repository: widget.repository,
                      transport: widget.transport,
                      developerMode: true,
                    ),
                  ),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.data_object),
                title: const Text('Manual game packet'),
                subtitle: const Text('Open the game editor and packet preview'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Manual Game Packet')),
                      body: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: GameEditor(transport: widget.transport),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          _SectionCard(
            title: 'Live Activity diagnostics',
            children: [
              Text(widget.liveActivityStatus),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: widget.onStartLiveActivity,
                    child: const Text('Start Live Activity'),
                  ),
                  OutlinedButton(
                    onPressed: widget.onEndLiveActivity,
                    child: const Text('End Live Activity'),
                  ),
                ],
              ),
            ],
          ),
          _SectionCard(
            title: 'Refresh diagnostics',
            children: [SelectableText(widget.backgroundRefreshStatus)],
          ),
          _SectionCard(
            title: 'Push notification diagnostics',
            trailing: IconButton(
              onPressed: _refreshPushDiagnostics,
              tooltip: 'Refresh push diagnostics',
              icon: const Icon(Icons.refresh),
            ),
            children: [
              _DiagnosticValue(
                label: 'Permission',
                value: diagnostics?.permissionStatus ?? 'Checking...',
              ),
              _DiagnosticValue(
                label: 'APNs token',
                value: diagnostics?.apnsTokenStatus ?? 'Checking...',
              ),
              _DiagnosticValue(
                label: 'FCM token',
                value: diagnostics?.tokenStatus ?? 'Checking...',
              ),
              if (diagnostics?.errorMessage != null)
                _DiagnosticValue(
                  label: 'Error',
                  value: diagnostics!.errorMessage!,
                ),
            ],
          ),
          _SectionCard(
            title: 'Provider',
            children: [
              _DiagnosticValue(
                label: 'Data provider',
                value: widget.providerLabel,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.children,
    this.trailing,
  });

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _DiagnosticValue extends StatelessWidget {
  const _DiagnosticValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 3),
          SelectableText(value),
        ],
      ),
    );
  }
}
