import 'package:flutter/material.dart';

import 'espn_fantasy_client.dart';
import 'espn_fantasy_credentials.dart';
import 'espn_fantasy_setup.dart';
import 'espn_fantasy_setup_screen.dart';
import 'fantasy_league_config.dart';
import 'fantasy_live_observation_coordinator.dart';
import 'fantasy_provider_models.dart';
import 'sleeper_fantasy_repository.dart';
import 'sleeper_discovery_screen.dart';
import 'sleeper_models.dart';
import 'sleeper_player_repository.dart';

class FantasyScreen extends StatefulWidget {
  const FantasyScreen({
    super.key,
    required this.coordinator,
    required this.playerRepository,
    this.espnCredentialsStore,
    this.espnGateway,
    this.espnSeason,
  });

  final FantasyLiveObservationCoordinator coordinator;
  final SleeperPlayerRepository playerRepository;
  final EspnFantasyCredentialsStore? espnCredentialsStore;
  final EspnFantasySetupGateway? espnGateway;
  final int? espnSeason;

  @override
  State<FantasyScreen> createState() => _FantasyScreenState();
}

class _FantasyScreenState extends State<FantasyScreen> {
  List<FantasyLeagueConfig> _configs = [];
  final _busy = <String>{};
  final _errors = <String, String>{};
  bool _loading = true;
  String? _error;
  String? _notice;
  bool _sendingTest = false;
  bool _espnConnected = false;

  FantasyLeagueConfigStore get _store => widget.coordinator.leagueConfigStore;
  EspnFantasyCredentialsStore get _credentials =>
      widget.espnCredentialsStore ?? SecureEspnFantasyCredentialsStore();
  EspnFantasySetupGateway get _espn =>
      widget.espnGateway ?? DeviceEspnFantasySetupGateway(_credentials);
  int get _season => widget.espnSeason ?? currentFantasySeason();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final configs = await _store.readAll();
      bool connected = false;
      if (configs.any((config) => config.provider == FantasyProvider.espn)) {
        try {
          connected = await _credentials.hasCredentials();
        } on Object {
          // A Keychain failure should not hide saved league configurations.
        }
      }
      await widget.coordinator.loadConfigurationStatus();
      if (!mounted) return;
      setState(() {
        _configs = configs;
        _espnConnected = connected;
        _loading = false;
        _error = null;
        _errors.removeWhere(
          (id, _) => !configs.any((config) => config.id == id),
        );
      });
      // Upgraded configurations have IDs but may not yet have friendly names.
      for (final config in configs) {
        if (config.provider != FantasyProvider.sleeper) continue;
        if (config.displayName == null ||
            (config.teamId != null && config.teamDisplayName == null)) {
          _loadNames(config);
        }
      }
    } on Object {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load your saved leagues. Try again.';
        });
      }
    }
  }

  Future<void> _loadNames(FantasyLeagueConfig config) async {
    if (_busy.contains(config.id)) return;
    setState(() => _busy.add(config.id));
    try {
      final snapshot = await widget.coordinator.loadLeagueSetup(
        config.leagueId,
      );
      if (!mounted) return;
      final current = (await _store.readAll()).where((c) => c.id == config.id);
      if (current.isEmpty || current.first.teamId != config.teamId) return;
      final saved = current.first;
      final teams = snapshot.rosters.where(
        (r) => r.rosterId.toString() == saved.teamId,
      );
      final updated = _withNames(
        saved,
        snapshot.league.name,
        teams.isEmpty
            ? saved.teamDisplayName
            : snapshot.rosterLabel(teams.first),
      );
      await _store.upsert(updated);
      if (!mounted) return;
      setState(() {
        _configs = [for (final c in _configs) c.id == updated.id ? updated : c];
        if (saved.teamId != null && teams.isEmpty) {
          _errors[config.id] = _friendlyError(
            const Object(),
            rosterMissing: true,
          );
        }
      });
    } on Object catch (error) {
      if (mounted) setState(() => _errors[config.id] = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy.remove(config.id));
    }
  }

  Future<void> _edit([FantasyLeagueConfig? config]) async {
    var provider = config?.provider;
    if (provider == null) {
      provider = await showModalBottomSheet<FantasyProvider>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const ValueKey('provider-sleeper'),
                title: const Text('Sleeper'),
                onTap: () => Navigator.pop(context, FantasyProvider.sleeper),
              ),
              ListTile(
                key: const ValueKey('provider-espn'),
                title: const Text('ESPN'),
                onTap: () => Navigator.pop(context, FantasyProvider.espn),
              ),
            ],
          ),
        ),
      );
      if (provider == null || !mounted) return;
    }
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => provider == FantasyProvider.sleeper
            ? config == null
                  ? SleeperDiscoveryScreen(
                      coordinator: widget.coordinator,
                      manualFallback: () => Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                          builder: (_) => _SleeperLeagueEditor(
                            coordinator: widget.coordinator,
                          ),
                        ),
                      ),
                    )
                  : _SleeperLeagueEditor(
                      coordinator: widget.coordinator,
                      config: config,
                    )
            : EspnFantasySetupScreen(
                coordinator: widget.coordinator,
                credentialsStore: _credentials,
                gateway: _espn,
                season: _season,
                config: config,
              ),
      ),
    );
    if (mounted && changed == true) await _reload();
  }

  Future<void> _manageEspn() async {
    final espnConfigs = _configs.where(
      (c) => c.provider == FantasyProvider.espn,
    );
    if (espnConfigs.isEmpty) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EspnCredentialsScreen(
          credentialsStore: _credentials,
          gateway: _espn,
          season: _season,
          validationLeagueId: espnConfigs.first.leagueId,
        ),
      ),
    );
    if (mounted && changed == true) {
      await _reload();
      if (widget.coordinator.primaryLeagueId?.startsWith('espn:') ?? false) {
        try {
          if (_espnConnected) {
            await widget.coordinator.syncPrimaryEspnMatchup();
          } else {
            await widget.coordinator.clearPrimaryEspnDisplay();
          }
        } on Object {
          // Connection state remains visible; no config is removed on failure.
        }
      }
    }
  }

  Future<void> _act(
    FantasyLeagueConfig config,
    Future<void> Function() action,
  ) async {
    if (_busy.contains(config.id)) return;
    setState(() {
      _busy.add(config.id);
      _errors.remove(config.id);
    });
    try {
      await action();
      await _reload();
    } on Object {
      if (mounted) {
        setState(
          () => _errors[config.id] = 'Could not update this league. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(config.id));
    }
  }

  Future<void> _remove(FantasyLeagueConfig config) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove league?'),
        content: Text(
          'Remove ${config.displayName ?? config.leagueId} from SCRBRD? Other leagues will stay connected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _act(config, () => _store.remove(config.provider, config.leagueId));
    }
  }

  Future<void> _sendTestAlert() async {
    setState(() {
      _sendingTest = true;
      _notice = null;
    });
    try {
      final sent = await widget.coordinator.sendTestAlert();
      if (mounted) {
        setState(
          () => _notice = sent
              ? 'Test alert sent to SCRBRD.'
              : 'Connect to SCRBRD before sending a test alert.',
        );
      }
    } on Object {
      if (mounted) {
        setState(
          () => _notice =
              'The test alert could not be sent. Check your SCRBRD connection.',
        );
      }
    } finally {
      if (mounted) setState(() => _sendingTest = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Fantasy Football')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'My Leagues',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        const Text(
          'Primary appears first on SCRBRD. Browse other matchups within Fantasy. Alerts are monitored for every league with alerts on.',
        ),
        const SizedBox(height: 16),
        if (_loading)
          const LinearProgressIndicator()
        else if (_configs.isEmpty && _error == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('No fantasy leagues connected.'),
          ),
        for (final config in _configs) _leagueCard(config),
        if (_error != null) ...[
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          TextButton(onPressed: _reload, child: const Text('Retry')),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _loading ? null : () => _edit(),
          icon: const Icon(Icons.add),
          label: const Text('Add Fantasy League'),
        ),
        if (_configs.any((c) => c.provider == FantasyProvider.espn))
          TextButton(
            onPressed: _manageEspn,
            child: const Text('ESPN Connection'),
          ),
        if (_configs.isNotEmpty) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _sendingTest ? null : _sendTestAlert,
            child: Text(
              _sendingTest ? 'SENDING TEST ALERT...' : 'SEND TEST ALERT',
            ),
          ),
          if (_notice != null) Text(_notice!, textAlign: TextAlign.center),
        ],
      ],
    ),
  );

  Widget _leagueCard(FantasyLeagueConfig config) {
    final busy = _busy.contains(config.id);
    final primary = widget.coordinator.primaryLeagueId == config.id;
    return Card(
      key: ValueKey('league-${config.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              config.displayName ??
                  (config.provider == FantasyProvider.espn
                      ? 'ESPN league ${config.leagueId}'
                      : 'Sleeper league ${config.leagueId}'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              config.teamDisplayName ??
                  (config.teamId == null
                      ? 'Choose your team'
                      : config.provider == FantasyProvider.espn
                      ? 'Team ${config.teamId}'
                      : 'Roster ${config.teamId}'),
            ),
            Text(config.provider == FantasyProvider.espn ? 'ESPN' : 'Sleeper'),
            if (config.provider == FantasyProvider.espn && !_espnConnected)
              const Text('ESPN needs reconnection'),
            if (primary)
              const Align(
                alignment: Alignment.centerLeft,
                child: Chip(
                  avatar: Icon(Icons.star, size: 18),
                  label: Text('Primary'),
                ),
              ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              key: ValueKey('alerts-${config.id}'),
              title: Text(config.alertsEnabled ? 'Alerts On' : 'Alerts Off'),
              value: config.alertsEnabled,
              onChanged: busy
                  ? null
                  : (enabled) => _act(
                      config,
                      () => _store.upsert(
                        FantasyLeagueConfig(
                          provider: config.provider,
                          leagueId: config.leagueId,
                          teamId: config.teamId,
                          displayName: config.displayName,
                          teamDisplayName: config.teamDisplayName,
                          alertsEnabled: enabled,
                        ),
                      ),
                    ),
            ),
            Wrap(
              spacing: 8,
              children: [
                if (!primary)
                  TextButton(
                    key: ValueKey('primary-${config.id}'),
                    onPressed:
                        busy ||
                            !FantasyLiveObservationCoordinator.isEligiblePrimary(
                              config,
                            )
                        ? null
                        : () => _act(
                            config,
                            () =>
                                widget.coordinator.setPrimaryLeague(config.id),
                          ),
                    child: const Text('Make Primary'),
                  ),
                TextButton(
                  key: ValueKey('team-${config.id}'),
                  onPressed: busy ? null : () => _edit(config),
                  child: const Text('Change Team'),
                ),
                TextButton(
                  key: ValueKey('view-${config.id}'),
                  onPressed: busy || config.teamId == null
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => _LeagueMatchupScreen(
                              config: config,
                              coordinator: widget.coordinator,
                              playerRepository: widget.playerRepository,
                              espnGateway: _espn,
                              espnSeason: _season,
                            ),
                          ),
                        ),
                  child: const Text('View Matchup'),
                ),
                TextButton(
                  key: ValueKey('remove-${config.id}'),
                  onPressed: busy ? null : () => _remove(config),
                  child: const Text('Remove'),
                ),
              ],
            ),
            if (config.provider == FantasyProvider.espn)
              const Text('ESPN alerts are not active yet.'),
            if (busy) const LinearProgressIndicator(),
            if (_errors[config.id] case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}

FantasyLeagueConfig _withNames(
  FantasyLeagueConfig config,
  String leagueName,
  String? teamName,
) => FantasyLeagueConfig(
  provider: config.provider,
  leagueId: config.leagueId,
  teamId: config.teamId,
  displayName: leagueName,
  teamDisplayName: teamName,
  alertsEnabled: config.alertsEnabled,
);

class _SleeperLeagueEditor extends StatefulWidget {
  const _SleeperLeagueEditor({required this.coordinator, this.config});
  final FantasyLiveObservationCoordinator coordinator;
  final FantasyLeagueConfig? config;

  @override
  State<_SleeperLeagueEditor> createState() => _SleeperLeagueEditorState();
}

class _SleeperLeagueEditorState extends State<_SleeperLeagueEditor> {
  final _id = TextEditingController();
  SleeperLeagueSnapshot? _snapshot;
  int? _rosterId;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.config case final config?) {
      _id.text = config.leagueId;
      _load();
    }
  }

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_id.text.trim().isEmpty) {
      setState(() => _error = 'Enter a Sleeper league ID.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final snapshot = await widget.coordinator.loadLeagueSetup(_id.text);
      final current = (await widget.coordinator.leagueConfigStore.readAll())
          .where(
            (c) =>
                c.provider == FantasyProvider.sleeper &&
                c.leagueId == snapshot.league.leagueId,
          );
      final savedTeam = current.isEmpty ? null : current.first.teamId;
      final rosterId = int.tryParse(savedTeam ?? '');
      final found = snapshot.rosters.any((r) => r.rosterId == rosterId);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _rosterId = found ? rosterId : null;
        if (savedTeam != null && !found) {
          _error = _friendlyError(const Object(), rosterMissing: true);
        }
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final snapshot = _snapshot;
    final rosterId = _rosterId;
    if (snapshot == null || rosterId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final store = widget.coordinator.leagueConfigStore;
      final matches = (await store.readAll()).where(
        (c) =>
            c.provider == FantasyProvider.sleeper &&
            c.leagueId == snapshot.league.leagueId,
      );
      final roster = snapshot.rosters.firstWhere((r) => r.rosterId == rosterId);
      await store.upsert(
        FantasyLeagueConfig(
          provider: FantasyProvider.sleeper,
          leagueId: snapshot.league.leagueId,
          teamId: rosterId.toString(),
          displayName: snapshot.league.name,
          teamDisplayName: snapshot.rosterLabel(roster),
          alertsEnabled: matches.isEmpty ? true : matches.first.alertsEnabled,
        ),
      );
      await widget.coordinator.loadConfigurationStatus();
      if (mounted) Navigator.of(context).pop(true);
    } on Object {
      if (mounted) {
        setState(() => _error = 'Could not save this league. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.config == null ? 'Add Sleeper League' : 'Change Team'),
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_snapshot == null) ...[
          TextField(
            controller: _id,
            enabled: !_busy && widget.config == null,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Sleeper League ID',
              helperText: 'Find your league ID in the Sleeper league URL.',
            ),
            onSubmitted: _busy ? null : (_) => _load(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _load,
            child: const Text('Load League'),
          ),
        ] else ...[
          Text(
            _snapshot!.league.name,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text('Choose your team'),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _rosterId,
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Your team',
            ),
            items: [
              for (final roster in _snapshot!.rosters)
                DropdownMenuItem(
                  value: roster.rosterId,
                  child: Text(_snapshot!.rosterLabel(roster)),
                ),
            ],
            onChanged: _busy
                ? null
                : (id) => setState(() {
                    _rosterId = id;
                    _error = null;
                  }),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy || _rosterId == null ? null : _save,
            child: Text(widget.config == null ? 'Add League' : 'Save Team'),
          ),
          if (widget.config == null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _snapshot = null;
                      _rosterId = null;
                      _error = null;
                    }),
              child: const Text('Use a different league'),
            ),
        ],
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: LinearProgressIndicator(),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
  );
}

class _LeagueMatchupScreen extends StatefulWidget {
  const _LeagueMatchupScreen({
    required this.config,
    required this.coordinator,
    required this.playerRepository,
    required this.espnGateway,
    required this.espnSeason,
  });
  final FantasyLeagueConfig config;
  final FantasyLiveObservationCoordinator coordinator;
  final SleeperPlayerRepository playerRepository;
  final EspnFantasySetupGateway espnGateway;
  final int espnSeason;

  @override
  State<_LeagueMatchupScreen> createState() => _LeagueMatchupScreenState();
}

class _LeagueMatchupScreenState extends State<_LeagueMatchupScreen> {
  SleeperFantasyMatchup? _matchup;
  FantasyMatchupSnapshot? _espnMatchup;
  Map<String, SleeperFantasyPlayer> _players = {};
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.config.provider == FantasyProvider.espn) {
        final matchup = widget.coordinator.primaryLeagueId == widget.config.id
            ? await widget.coordinator.syncPrimaryEspnMatchup()
            : await widget.espnGateway.loadMatchup(
                widget.espnSeason,
                widget.config.leagueId,
                widget.config.teamId!,
              );
        if (matchup == null) {
          throw const EspnFantasyException(
            EspnFantasyFailure.matchupUnavailable,
          );
        }
        if (mounted) setState(() => _espnMatchup = matchup);
        return;
      }
      SleeperFantasyMatchup matchup;
      if (refresh) {
        final result =
            (await widget.coordinator.observe()).leagues[widget.config.id];
        if (result == null || result.error != null || result.matchup == null) {
          throw result?.error ??
              const SleeperFantasyException('Current matchup is unavailable.');
        }
        matchup = result.matchup!;
      } else {
        final snapshot = await widget.coordinator.loadLeagueSetup(
          widget.config.leagueId,
        );
        matchup = snapshot.matchupForRoster(int.parse(widget.config.teamId!));
      }
      final players = await widget.playerRepository.resolvePlayersSafely([
        ...matchup.team.matchup.starters,
        ...matchup.opponent.matchup.starters,
      ]);
      if (mounted) {
        setState(() {
          _matchup = matchup;
          _players = players;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = widget.config.provider == FantasyProvider.espn
              ? espnSetupError(error)
              : _friendlyError(
                  error,
                  rosterMissing: error.toString().contains('Roster'),
                ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Fantasy Matchup')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_matchup case final matchup?) ...[
          _FantasyStatusCard(
            leagueName: matchup.league.name,
            matchup: matchup,
            week: matchup.week,
            alertsEnabled: widget.config.alertsEnabled,
            onAlertsChanged: null,
          ),
          _MatchupCard(matchup: matchup, playerMetadata: _players),
          const _FantasyExplanationCard(),
        ],
        if (_espnMatchup case final matchup?) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    matchup.league.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    'ESPN • Scoring period ${matchup.scoringPeriod} • Matchup period ${matchup.matchupPeriod}',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${matchup.team.team.name}: ${_espnPoints(matchup.team.totalPoints)}',
                  ),
                  Text(
                    '${matchup.opponent?.team.name ?? 'BYE'}: ${_espnPoints(matchup.opponent?.totalPoints ?? 0)}',
                  ),
                  const SizedBox(height: 12),
                  const Text('YOUR STARTERS'),
                  for (final player in matchup.team.starters)
                    Text('${player.name}: ${_espnPoints(player.points)}'),
                  if (matchup.opponent != null) ...[
                    const SizedBox(height: 12),
                    const Text('OPPONENT STARTERS'),
                    for (final player in matchup.opponent!.starters)
                      Text('${player.name}: ${_espnPoints(player.points)}'),
                  ],
                  const SizedBox(height: 12),
                  const Text('ESPN scoring alerts are not active yet.'),
                ],
              ),
            ),
          ),
        ],
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : () => _load(refresh: true),
          icon: const Icon(Icons.refresh),
          label: const Text('REFRESH MATCHUP'),
        ),
      ],
    ),
  );
}

class _MatchupCard extends StatelessWidget {
  const _MatchupCard({required this.matchup, required this.playerMetadata});

  final SleeperFantasyMatchup matchup;
  final Map<String, SleeperFantasyPlayer> playerMetadata;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StarterList(
              title: 'YOUR STARTERS',
              team: matchup.team,
              playerMetadata: playerMetadata,
            ),
            const SizedBox(height: 20),
            _StarterList(
              title: 'OPPONENT STARTERS',
              team: matchup.opponent,
              playerMetadata: playerMetadata,
            ),
          ],
        ),
      ),
    );
  }
}

class _FantasyStatusCard extends StatelessWidget {
  const _FantasyStatusCard({
    required this.leagueName,
    required this.matchup,
    required this.week,
    required this.alertsEnabled,
    required this.onAlertsChanged,
  });

  final String leagueName;
  final SleeperFantasyMatchup matchup;
  final int week;
  final bool alertsEnabled;
  final ValueChanged<bool>? onAlertsChanged;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Fantasy Alerts'),
            subtitle: Text(alertsEnabled ? 'ACTIVE' : 'OFF'),
            value: alertsEnabled,
            onChanged: onAlertsChanged,
          ),
          const Divider(),
          Text(
            'Sleeper league:',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          Text(leagueName),
          const SizedBox(height: 10),
          Text('Your team:', style: Theme.of(context).textTheme.labelLarge),
          Text(matchup.team.name),
          const SizedBox(height: 14),
          Text(
            'Current matchup',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _TeamScore(team: matchup.team)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Text('vs'),
              ),
              Expanded(
                child: _TeamScore(team: matchup.opponent, alignEnd: true),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('NFL Week $week'),
        ],
      ),
    ),
  );
}

class _FantasyExplanationCard extends StatelessWidget {
  const _FantasyExplanationCard();

  @override
  Widget build(BuildContext context) => const Card(
    child: Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'How fantasy alerts work',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 8),
          Text(
            "When one of your starters or your opponent's starters gains or "
            'loses fantasy points, SCRBRD can briefly show the change automatically.',
          ),
        ],
      ),
    ),
  );
}

class _TeamScore extends StatelessWidget {
  const _TeamScore({required this.team, this.alignEnd = false});

  final SleeperFantasyTeam team;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(team.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        Text(
          _points(team.matchup.points),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      ],
    );
  }
}

class _StarterList extends StatelessWidget {
  const _StarterList({
    required this.title,
    required this.team,
    required this.playerMetadata,
  });

  final String title;
  final SleeperFantasyTeam team;
  final Map<String, SleeperFantasyPlayer> playerMetadata;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final starter in team.starters)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    playerMetadata[starter.playerId]?.fullName ??
                        starter.playerId,
                  ),
                ),
                Text(starter.points == null ? '--' : _points(starter.points!)),
              ],
            ),
          ),
      ],
    );
  }
}

String _points(double value) {
  final fixed = value.toStringAsFixed(2);
  return fixed.endsWith('.00')
      ? fixed.substring(0, fixed.length - 3)
      : fixed.endsWith('0')
      ? fixed.substring(0, fixed.length - 1)
      : fixed;
}

String _espnPoints(double value) {
  final text = value.toString();
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

String _friendlyError(Object error, {bool rosterMissing = false}) {
  if (rosterMissing) {
    return 'That team is no longer available in this league. '
        'Please choose your team again.';
  }
  final message = error.toString().toLowerCase();
  if (message.contains('http 404') || message.contains('not found')) {
    return "We couldn't find that Sleeper league. Check the league ID and try again.";
  }
  if (message.contains('reach sleeper') ||
      message.contains('timed out') ||
      message.contains('network')) {
    return "Couldn't reach Sleeper right now. Try again in a moment.";
  }
  return 'Something went wrong while loading your Sleeper league. Try again.';
}
