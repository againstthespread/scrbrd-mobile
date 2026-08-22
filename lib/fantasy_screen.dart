import 'package:flutter/material.dart';

import 'sleeper_api_client.dart';
import 'sleeper_fantasy_repository.dart';
import 'sleeper_league_id_store.dart';
import 'sleeper_models.dart';

class FantasyScreen extends StatefulWidget {
  const FantasyScreen({super.key, this.repository, this.leagueIdStore});

  final SleeperFantasyRepository? repository;
  final SleeperLeagueIdStore? leagueIdStore;

  @override
  State<FantasyScreen> createState() => _FantasyScreenState();
}

class _FantasyScreenState extends State<FantasyScreen> {
  final _leagueIdController = TextEditingController();
  SleeperApiClient? _ownedApiClient;
  late final SleeperFantasyRepository _repository;
  late final SleeperLeagueIdStore _leagueIdStore;
  SleeperLeagueSnapshot? _snapshot;
  SleeperFantasyMatchup? _selectedMatchup;
  int? _selectedRosterId;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.repository case final repository?) {
      _repository = repository;
    } else {
      _ownedApiClient = SleeperApiClient();
      _repository = SleeperFantasyRepository(_ownedApiClient!);
    }
    _leagueIdStore =
        widget.leagueIdStore ?? SharedPreferencesSleeperLeagueIdStore();
    _restoreLeagueId();
  }

  @override
  void dispose() {
    _leagueIdController.dispose();
    _ownedApiClient?.close();
    super.dispose();
  }

  Future<void> _restoreLeagueId() async {
    final savedId = await _leagueIdStore.read();
    if (!mounted || savedId == null) return;
    _leagueIdController.text = savedId;
  }

  Future<void> _connectLeague() async {
    final leagueId = _leagueIdController.text.trim();
    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _error = null;
      _snapshot = null;
      _selectedRosterId = null;
      _selectedMatchup = null;
    });
    try {
      final snapshot = await _repository.loadLeague(leagueId);
      await _leagueIdStore.save(leagueId);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _isLoading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _isLoading = false;
      });
    }
  }

  void _selectRoster(int? rosterId) {
    if (rosterId == null || _snapshot == null) return;
    try {
      final matchup = _snapshot!.matchupForRoster(rosterId);
      setState(() {
        _selectedRosterId = rosterId;
        _selectedMatchup = matchup;
        _error = null;
      });
    } on Object catch (error) {
      setState(() {
        _selectedRosterId = rosterId;
        _selectedMatchup = null;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(title: const Text('Fantasy Football')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Sleeper diagnostic',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          const Text(
            'Connect a league and select your roster to inspect the current '
            'week matchup. Nothing on this screen is sent to SCRBRD.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _leagueIdController,
            enabled: !_isLoading,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Sleeper league ID',
            ),
            onSubmitted: (_) => _connectLeague(),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _isLoading ? null : _connectLeague,
            child: Text(_isLoading ? 'Connecting...' : 'Connect league'),
          ),
          if (_isLoading) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_error case final error?) ...[
            const SizedBox(height: 16),
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (snapshot != null) ...[
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      snapshot.league.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text('NFL week ${snapshot.week}'),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      initialValue: _selectedRosterId,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Your Sleeper roster',
                      ),
                      items: snapshot.rosters
                          .map(
                            (roster) => DropdownMenuItem(
                              value: roster.rosterId,
                              child: Text(snapshot.rosterLabel(roster)),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: _selectRoster,
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_selectedMatchup case final matchup?) ...[
            const SizedBox(height: 12),
            _MatchupCard(matchup: matchup),
          ],
        ],
      ),
    );
  }
}

class _MatchupCard extends StatelessWidget {
  const _MatchupCard({required this.matchup});

  final SleeperFantasyMatchup matchup;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Current matchup',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
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
            const Divider(height: 32),
            _StarterList(
              title: '${matchup.team.name} starters',
              team: matchup.team,
            ),
            const SizedBox(height: 20),
            _StarterList(
              title: '${matchup.opponent.name} starters',
              team: matchup.opponent,
            ),
          ],
        ),
      ),
    );
  }
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
  const _StarterList({required this.title, required this.team});

  final String title;
  final SleeperFantasyTeam team;

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
                Expanded(child: SelectableText(starter.playerId)),
                Text(starter.points == null ? '--' : _points(starter.points!)),
              ],
            ),
          ),
      ],
    );
  }
}

String _points(double value) => value.toStringAsFixed(value % 1 == 0 ? 0 : 2);
