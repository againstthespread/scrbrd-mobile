import 'package:flutter/material.dart';

import 'espn_fantasy_client.dart';
import 'espn_fantasy_credentials.dart';
import 'espn_fantasy_setup.dart';
import 'fantasy_league_config.dart';
import 'fantasy_live_observation_coordinator.dart';
import 'fantasy_provider_models.dart';

String espnSetupError(Object error) {
  if (error is EspnFantasyException) {
    return switch (error.failure) {
      EspnFantasyFailure.missingCredentials =>
        'ESPN needs reconnection. Enter your SWID and espn_s2.',
      EspnFantasyFailure.unauthorized =>
        'ESPN rejected these cookies. Check SWID and espn_s2, then reconnect.',
      EspnFantasyFailure.leagueUnavailable =>
        'This ESPN league could not be found or accessed.',
      EspnFantasyFailure.teamUnavailable =>
        'This ESPN team is no longer available. Choose another team.',
      EspnFantasyFailure.network =>
        'Could not reach ESPN right now. Try again.',
      EspnFantasyFailure.matchupUnavailable =>
        'The current ESPN matchup is unavailable.',
      EspnFantasyFailure.invalidRequest => 'Enter a valid ESPN league ID.',
      EspnFantasyFailure.invalidResponse =>
        'ESPN returned unexpected league data. Try again later.',
    };
  }
  return 'Could not complete ESPN setup. Try again.';
}

class EspnFantasySetupScreen extends StatefulWidget {
  const EspnFantasySetupScreen({
    super.key,
    required this.coordinator,
    required this.credentialsStore,
    required this.gateway,
    required this.season,
    this.config,
  });

  final FantasyLiveObservationCoordinator coordinator;
  final EspnFantasyCredentialsStore credentialsStore;
  final EspnFantasySetupGateway gateway;
  final int season;
  final FantasyLeagueConfig? config;

  @override
  State<EspnFantasySetupScreen> createState() => _EspnFantasySetupScreenState();
}

class _EspnFantasySetupScreenState extends State<EspnFantasySetupScreen> {
  final _leagueId = TextEditingController();
  final _swid = TextEditingController();
  final _espnS2 = TextEditingController();
  FantasyLeagueDetails? _league;
  String? _teamId;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  bool _needsCredentials = false;

  @override
  void initState() {
    super.initState();
    _leagueId.text = widget.config?.leagueId ?? '';
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final hasCredentials = await widget.credentialsStore.hasCredentials();
      if (!mounted) return;
      setState(() {
        _needsCredentials = !hasCredentials;
        _loading = false;
      });
      if (widget.config != null && hasCredentials) await _load();
    } on Object {
      if (mounted) {
        setState(() {
          _needsCredentials = true;
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _leagueId.dispose();
    _swid.dispose();
    _espnS2.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = _leagueId.text.trim();
    if (id.isEmpty) {
      setState(() => _error = 'Enter an ESPN league ID.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      FantasyLeagueDetails league;
      if (_needsCredentials) {
        final credentials = EspnFantasyCredentials(
          swid: _swid.text.trim(),
          espnS2: _espnS2.text.trim(),
        );
        league = await widget.gateway.validateAndLoadLeague(
          credentials,
          widget.season,
          id,
        );
        await widget.credentialsStore.save(credentials);
      } else {
        league = await widget.gateway.loadLeague(widget.season, id);
      }
      if (!mounted) return;
      setState(() {
        _league = league;
        _teamId = league.teams.any((team) => team.id == widget.config?.teamId)
            ? widget.config!.teamId
            : null;
        _needsCredentials = false;
        _swid.clear();
        _espnS2.clear();
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          if (error is EspnFantasyException &&
              (error.failure == EspnFantasyFailure.unauthorized ||
                  error.failure == EspnFantasyFailure.missingCredentials)) {
            _needsCredentials = true;
          }
          _error = espnSetupError(error);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final league = _league;
    final teamId = _teamId;
    if (league == null || teamId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Confirm that the chosen team has a current matchup before persisting.
      await widget.gateway.loadMatchup(widget.season, league.leagueId, teamId);
      final team = league.teams.firstWhere((team) => team.id == teamId);
      final store = widget.coordinator.leagueConfigStore;
      final existing = (await store.readAll()).where(
        (config) =>
            config.provider == FantasyProvider.espn &&
            config.leagueId == league.leagueId,
      );
      await store.upsert(
        FantasyLeagueConfig(
          provider: FantasyProvider.espn,
          leagueId: league.leagueId,
          teamId: teamId,
          displayName: league.name,
          teamDisplayName: team.name,
          alertsEnabled: existing.isEmpty ? true : existing.first.alertsEnabled,
        ),
      );
      await widget.coordinator.loadConfigurationStatus();
      if (widget.coordinator.primaryLeagueId == 'espn:${league.leagueId}') {
        try {
          await widget.coordinator.syncPrimaryEspnMatchup();
        } on Object {
          // The saved setup remains valid if device display sync fails.
        }
      }
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = espnSetupError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.config == null ? 'Add ESPN League' : 'Change Team'),
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_loading)
          const LinearProgressIndicator()
        else ...[
          if (_needsCredentials) ...[
            const Text(
              'SWID and espn_s2 are ESPN authentication cookies. They are stored securely on this device.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('espn-swid'),
              controller: _swid,
              enabled: !_busy,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'SWID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('espn-s2'),
              controller: _espnS2,
              enabled: !_busy,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'espn_s2',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (_league == null) ...[
            TextField(
              key: const ValueKey('espn-league-id'),
              controller: _leagueId,
              enabled: !_busy && widget.config == null,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'ESPN League ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _load,
              child: Text(
                _needsCredentials ? 'Connect and Load League' : 'Load League',
              ),
            ),
          ] else ...[
            Text(
              _league!.name,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text(
              'Scoring period ${_league!.scoringPeriod} • Matchup period ${_league!.matchupPeriod}',
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('espn-team'),
              initialValue: _teamId,
              decoration: const InputDecoration(
                labelText: 'Your team',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final team in _league!.teams)
                  DropdownMenuItem(value: team.id, child: Text(team.name)),
              ],
              onChanged: _busy ? null : (id) => setState(() => _teamId = id),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || _teamId == null ? null : _save,
              child: Text(widget.config == null ? 'Add League' : 'Save Team'),
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
      ],
    ),
  );
}

class EspnCredentialsScreen extends StatefulWidget {
  const EspnCredentialsScreen({
    super.key,
    required this.credentialsStore,
    required this.gateway,
    required this.season,
    required this.validationLeagueId,
  });
  final EspnFantasyCredentialsStore credentialsStore;
  final EspnFantasySetupGateway gateway;
  final int season;
  final String validationLeagueId;
  @override
  State<EspnCredentialsScreen> createState() => _EspnCredentialsScreenState();
}

class _EspnCredentialsScreenState extends State<EspnCredentialsScreen> {
  final _swid = TextEditingController();
  final _espnS2 = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _swid.dispose();
    _espnS2.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final credentials = EspnFantasyCredentials(
        swid: _swid.text.trim(),
        espnS2: _espnS2.text.trim(),
      );
      await widget.gateway.validateAndLoadLeague(
        credentials,
        widget.season,
        widget.validationLeagueId,
      );
      await widget.credentialsStore.save(credentials);
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = espnSetupError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.credentialsStore.clear();
      if (mounted) Navigator.of(context).pop(true);
    } on Object {
      if (mounted) {
        setState(() => _error = 'Could not disconnect ESPN. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ESPN Connection')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Update your ESPN authentication cookies. Saved ESPN leagues remain available after disconnecting.',
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('manage-espn-swid'),
          controller: _swid,
          enabled: !_busy,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'SWID',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('manage-espn-s2'),
          controller: _espnS2,
          enabled: !_busy,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'espn_s2',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _connect,
          child: const Text('Reconnect ESPN'),
        ),
        TextButton(
          onPressed: _busy ? null : _disconnect,
          child: const Text('Disconnect ESPN'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}
