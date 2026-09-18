import 'package:flutter/material.dart';

import 'fantasy_league_config.dart';
import 'fantasy_live_observation_coordinator.dart';
import 'sleeper_discovery.dart';
import 'sleeper_username_store.dart';

class SleeperDiscoveryScreen extends StatefulWidget {
  const SleeperDiscoveryScreen({
    super.key,
    required this.coordinator,
    this.usernameStore,
    this.manualFallback,
  });
  final FantasyLiveObservationCoordinator coordinator;
  final SleeperUsernameStore? usernameStore;
  final Future<bool?> Function()? manualFallback;

  @override
  State<SleeperDiscoveryScreen> createState() => _SleeperDiscoveryScreenState();
}

class _SleeperDiscoveryScreenState extends State<SleeperDiscoveryScreen> {
  final _username = TextEditingController();
  final _selected = <String>{};
  List<SleeperDiscoveredLeague> _leagues = const [];
  Set<String> _alreadyAdded = {};
  bool _busy = false;
  String? _error;

  SleeperUsernameStore get _usernameStore =>
      widget.usernameStore ?? SharedPreferencesSleeperUsernameStore();

  @override
  void initState() {
    super.initState();
    _usernameStore.read().then((value) {
      if (mounted && value != null) {
        setState(() => _username.text = value);
      }
    });
  }

  @override
  void dispose() {
    _username.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    if (_username.text.trim().isEmpty) {
      setState(() => _error = 'Enter a Sleeper username.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _selected.clear();
    });
    try {
      final result = await widget.coordinator.repository.discoverLeagues(
        _username.text,
        currentFantasySeason(),
      );
      final configs = await widget.coordinator.leagueConfigStore.readAll();
      await _usernameStore.save(result.$1.username);
      if (!mounted) return;
      setState(() {
        _username.text = result.$1.username;
        _leagues = result.$2;
        _alreadyAdded = configs
            .where((config) => config.provider == FantasyProvider.sleeper)
            .map((config) => config.leagueId)
            .toSet();
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addSelected() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final store = widget.coordinator.leagueConfigStore;
      final existing = await store.readAll();
      for (final item in _leagues.where(
        (item) => _selected.contains(item.league.leagueId),
      )) {
        if (item.rosterId == null) continue;
        final prior = existing.where(
          (c) => c.id == 'sleeper:${item.league.leagueId}',
        );
        if (prior.isNotEmpty) continue;
        await store.upsert(
          FantasyLeagueConfig(
            provider: FantasyProvider.sleeper,
            leagueId: item.league.leagueId,
            teamId: item.rosterId.toString(),
            displayName: item.league.name,
            teamDisplayName: item.teamDisplayName,
          ),
        );
      }
      await widget.coordinator.loadConfigurationStatus();
      if (mounted) Navigator.of(context).pop(true);
    } on Object {
      if (mounted) {
        setState(() => _error = 'Could not save the selected leagues.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseTeam(SleeperDiscoveredLeague item) async {
    final choice = await showModalBottomSheet<SleeperDiscoveryRoster>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Choose your team')),
            for (final roster in item.rosters)
              ListTile(
                title: Text(roster.name),
                onTap: () => Navigator.of(context).pop(roster),
              ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    setState(() {
      final index = _leagues.indexOf(item);
      _leagues = [
        for (var i = 0; i < _leagues.length; i++)
          i == index
              ? item.copyWith(
                  rosterId: choice.rosterId,
                  teamDisplayName: choice.name,
                )
              : _leagues[i],
      ];
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Find Sleeper Leagues')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _username,
          enabled: !_busy,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Sleeper username',
          ),
          onSubmitted: (_) => _discover(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _discover,
          child: const Text('Find My Leagues'),
        ),
        if (widget.manualFallback != null)
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    final changed = await widget.manualFallback!();
                    if (!mounted || changed != true) return;
                    Navigator.of(this.context).pop(true);
                  },
            child: const Text('Add by League ID instead'),
          ),
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
        if (!_busy && _leagues.isEmpty && _error == null)
          const SizedBox.shrink(),
        if (_leagues.isNotEmpty) ...[
          const SizedBox(height: 20),
          for (final item in _leagues)
            Column(
              children: [
                CheckboxListTile(
                  value: _selected.contains(item.league.leagueId),
                  enabled:
                      !_busy &&
                      !_alreadyAdded.contains(item.league.leagueId) &&
                      item.rosterId != null,
                  title: Text(item.league.name),
                  subtitle: Text(
                    _alreadyAdded.contains(item.league.leagueId)
                        ? 'Already added'
                        : item.rosterId == null
                        ? "We couldn't identify your team"
                        : item.teamDisplayName ?? 'Your team',
                  ),
                  onChanged: (selected) => setState(() {
                    if (selected ?? false) {
                      _selected.add(item.league.leagueId);
                    } else {
                      _selected.remove(item.league.leagueId);
                    }
                  }),
                ),
                if (!_alreadyAdded.contains(item.league.leagueId) &&
                    item.rosterId == null &&
                    item.rosters.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _busy ? null : () => _chooseTeam(item),
                      child: const Text('CHOOSE TEAM'),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy || _selected.isEmpty ? null : _addSelected,
            child: Text(
              'Add ${_selected.length} League${_selected.length == 1 ? '' : 's'}',
            ),
          ),
        ],
      ],
    ),
  );
}
