import 'package:flutter/material.dart';

import 'device_transport.dart';
import 'fantasy_screen.dart';
import 'fantasy_live_observation_coordinator.dart';
import 'game_editor.dart';
import 'live_games_screen.dart';
import 'push_notification_service.dart';
import 'sports_repository.dart';
import 'tracked_device_session.dart';
import 'sleeper_player_repository.dart';
import 'favorites_screen.dart';
import 'favorites_store.dart';
import 'device_content_preferences_store.dart';
import 'device_content_screen.dart';
import 'college_football_preferences_store.dart';
import 'college_football_screen.dart';
import 'refresh_diagnostic_history.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.repository,
    required this.transport,
    required this.trackedSession,
    required this.providerLabel,
    required this.pushDiagnostics,
    required this.onRefreshPushDiagnostics,
    required this.backgroundRefreshDiagnostics,
    required this.fantasyCoordinator,
    required this.fantasyPlayerRepository,
    required this.favoritesStore,
    required this.contentPreferencesStore,
    required this.collegeFootballPreferencesStore,
  });

  final SportsRepository repository;
  final DeviceTransport transport;
  final TrackedDeviceSession trackedSession;
  final String providerLabel;
  final PushNotificationDiagnostics? pushDiagnostics;
  final Future<PushNotificationDiagnostics> Function() onRefreshPushDiagnostics;
  final RefreshDiagnosticHistory backgroundRefreshDiagnostics;
  final FantasyLiveObservationCoordinator fantasyCoordinator;
  final SleeperPlayerRepository fantasyPlayerRepository;
  final FavoritesStore favoritesStore;
  final DeviceContentPreferencesStore contentPreferencesStore;
  final CollegeFootballPreferencesStore collegeFootballPreferencesStore;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AnimatedBuilder(
            animation: fantasyCoordinator,
            builder: (context, _) => Card(
              child: ListTile(
                leading: const Icon(Icons.sports_football_outlined),
                title: const Text('Fantasy Football'),
                subtitle: Text(
                  fantasyCoordinator.status.configured
                      ? 'Configured • Alerts '
                            '${fantasyCoordinator.status.alertsEnabled ? 'On' : 'Off'}'
                      : 'Connect a Sleeper league',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => FantasyScreen(
                      coordinator: fantasyCoordinator,
                      playerRepository: fantasyPlayerRepository,
                    ),
                  ),
                ),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: contentPreferencesStore,
            builder: (context, _) {
              final enabled = contentPreferencesStore
                  .read()
                  .enabledCategories
                  .length;
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.view_carousel_outlined),
                  title: const Text('SCRBRD Content'),
                  subtitle: Text(
                    enabled == 0
                        ? 'No content selected'
                        : '$enabled categories enabled',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          DeviceContentScreen(store: contentPreferencesStore),
                    ),
                  ),
                ),
              );
            },
          ),
          AnimatedBuilder(
            animation: collegeFootballPreferencesStore,
            builder: (context, _) {
              final selected = collegeFootballPreferencesStore
                  .read()
                  .conferences;
              final subtitle = selected.length == 4
                  ? 'All Power 4'
                  : selected.map((value) => value.displayName).join(', ');
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.sports_football),
                  title: const Text('College Football'),
                  subtitle: Text(subtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CollegeFootballScreen(
                        store: collegeFootballPreferencesStore,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
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
                    trackedSession: trackedSession,
                    providerLabel: providerLabel,
                    pushDiagnostics: pushDiagnostics,
                    onRefreshPushDiagnostics: onRefreshPushDiagnostics,
                    backgroundRefreshDiagnostics: backgroundRefreshDiagnostics,
                  ),
                ),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: favoritesStore,
            builder: (context, _) {
              final count = favoritesStore.readFavorites().length;
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.star_outline),
                  title: const Text('Favorites'),
                  subtitle: Text(
                    count == 0
                        ? 'No favorites'
                        : '$count favorite ${count == 1 ? 'team' : 'teams'}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => FavoritesScreen(store: favoritesStore),
                    ),
                  ),
                ),
              );
            },
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
    required this.trackedSession,
    required this.providerLabel,
    required this.pushDiagnostics,
    required this.onRefreshPushDiagnostics,
    required this.backgroundRefreshDiagnostics,
  });

  final SportsRepository repository;
  final DeviceTransport transport;
  final TrackedDeviceSession trackedSession;
  final String providerLabel;
  final PushNotificationDiagnostics? pushDiagnostics;
  final Future<PushNotificationDiagnostics> Function() onRefreshPushDiagnostics;
  final RefreshDiagnosticHistory backgroundRefreshDiagnostics;

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
                      trackedSession: widget.trackedSession,
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
            title: 'Refresh diagnostics',
            trailing: TextButton(
              key: const ValueKey('clear-refresh-diagnostics'),
              onPressed: widget.backgroundRefreshDiagnostics.clear,
              child: const Text('CLEAR'),
            ),
            children: [
              AnimatedBuilder(
                animation: widget.backgroundRefreshDiagnostics,
                builder: (context, _) {
                  final entries = widget.backgroundRefreshDiagnostics.entries;
                  if (entries.isEmpty) {
                    return const SelectableText('No refresh diagnostics yet.');
                  }
                  return SizedBox(
                    height: 180,
                    child: SingleChildScrollView(
                      child: SelectableText(
                        entries.map((entry) => entry.displayText).join('\n'),
                      ),
                    ),
                  );
                },
              ),
            ],
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
