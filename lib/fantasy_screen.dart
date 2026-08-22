import 'package:flutter/material.dart';

import 'fantasy_live_observation_coordinator.dart';
import 'sleeper_fantasy_config.dart';
import 'sleeper_fantasy_repository.dart';
import 'sleeper_models.dart';
import 'sleeper_player_repository.dart';

class FantasyScreen extends StatefulWidget {
  const FantasyScreen({
    super.key,
    required this.coordinator,
    required this.configStore,
    required this.playerRepository,
  });

  final FantasyLiveObservationCoordinator coordinator;
  final SleeperFantasyConfigStore configStore;
  final SleeperPlayerRepository playerRepository;

  @override
  State<FantasyScreen> createState() => _FantasyScreenState();
}

class _FantasyScreenState extends State<FantasyScreen> {
  final _leagueIdController = TextEditingController();
  late final SleeperPlayerRepository _playerRepository;
  late final SleeperFantasyConfigStore _configStore;
  SleeperLeagueSnapshot? _snapshot;
  SleeperFantasyMatchup? _selectedMatchup;
  int? _selectedRosterId;
  bool _isLoading = false;
  bool _isSendingTest = false;
  bool _alertsEnabled = true;
  String _loadingLabel = '';
  String? _error;
  String? _notice;
  Map<String, SleeperFantasyPlayer> _playerMetadata = const {};

  @override
  void initState() {
    super.initState();
    _playerRepository = widget.playerRepository;
    _configStore = widget.configStore;
    widget.coordinator.addListener(_handleCoordinatorChanged);
    _restoreConfiguration();
  }

  @override
  void dispose() {
    _leagueIdController.dispose();
    widget.coordinator.removeListener(_handleCoordinatorChanged);
    super.dispose();
  }

  void _handleCoordinatorChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _restoreConfiguration() async {
    final config = await _configStore.read();
    if (!mounted || config == null) return;
    _leagueIdController.text = config.leagueId;
    setState(() {
      _selectedRosterId = config.rosterId;
      _alertsEnabled = config.alertsEnabled;
    });
    await _loadSetup(config.leagueId, restoredRosterId: config.rosterId);
  }

  Future<void> _connectLeague() async {
    final leagueId = _leagueIdController.text.trim();
    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _loadingLabel = 'Connecting to Sleeper...';
      _error = null;
      _notice = null;
      _snapshot = null;
      _selectedRosterId = null;
      _selectedMatchup = null;
      _playerMetadata = const {};
    });
    try {
      final snapshot = await widget.coordinator.configureLeague(leagueId);
      final config = await _configStore.read();
      final rosterId = config?.rosterId;
      final matchup = rosterId == null
          ? null
          : snapshot.matchupForRoster(rosterId);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _selectedRosterId = rosterId;
        _selectedMatchup = matchup;
        _alertsEnabled = config?.alertsEnabled ?? true;
        _isLoading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(error);
        _isLoading = false;
      });
    }
  }

  Future<void> _loadSetup(String leagueId, {int? restoredRosterId}) async {
    setState(() {
      _isLoading = true;
      _loadingLabel = 'Loading matchup...';
    });
    try {
      final snapshot = await widget.coordinator.configureLeague(leagueId);
      SleeperFantasyMatchup? matchup;
      if (restoredRosterId != null) {
        try {
          matchup = snapshot.matchupForRoster(restoredRosterId);
        } on Object {
          await widget.coordinator.clearRosterSelection();
          if (!mounted) return;
          setState(() {
            _snapshot = snapshot;
            _selectedRosterId = null;
            _selectedMatchup = null;
            _error = _friendlyError(const Object(), rosterMissing: true);
            _isLoading = false;
          });
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _selectedMatchup = matchup;
        _isLoading = false;
      });
      if (matchup != null) await _loadPlayerMetadata(matchup);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = _friendlyError(error);
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _refreshMatchup() async {
    final rosterId = _selectedRosterId;
    if (rosterId == null) return;
    setState(() {
      _isLoading = true;
      _loadingLabel = 'Refreshing...';
      _error = null;
      _notice = null;
    });
    try {
      final result = await widget.coordinator.observe();
      final matchup = result.matchup;
      if (matchup == null) {
        throw const SleeperFantasyException('Current matchup is unavailable.');
      }
      final metadata = await _resolvePlayerMetadata(matchup);
      if (!mounted) return;
      setState(() {
        _selectedMatchup = matchup;
        _playerMetadata = {..._playerMetadata, ...metadata};
        _isLoading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(error);
        _isLoading = false;
      });
    }
  }

  Future<void> _selectRoster(int? rosterId) async {
    if (rosterId == null || _snapshot == null) return;
    try {
      final matchup = _snapshot!.matchupForRoster(rosterId);
      await widget.coordinator.selectRoster(rosterId);
      setState(() {
        _selectedRosterId = rosterId;
        _selectedMatchup = matchup;
        _error = null;
      });
      final metadata = await _resolvePlayerMetadata(matchup);
      if (!mounted) return;
      setState(() => _playerMetadata = {..._playerMetadata, ...metadata});
    } on Object catch (error) {
      setState(() {
        _selectedRosterId = rosterId;
        _selectedMatchup = null;
        _error = _friendlyError(error, rosterMissing: true);
      });
    }
  }

  Future<Map<String, SleeperFantasyPlayer>> _resolvePlayerMetadata(
    SleeperFantasyMatchup matchup,
  ) => _playerRepository.resolvePlayersSafely([
    ...matchup.team.matchup.starters,
    ...matchup.opponent.matchup.starters,
  ]);

  Future<void> _loadPlayerMetadata(SleeperFantasyMatchup matchup) async {
    final metadata = await _resolvePlayerMetadata(matchup);
    if (mounted) {
      setState(() => _playerMetadata = {..._playerMetadata, ...metadata});
    }
  }

  Future<void> _setAlertsEnabled(bool enabled) async {
    if (_isLoading) return;
    setState(() => _alertsEnabled = enabled);
    await widget.coordinator.setAlertsEnabled(enabled);
  }

  Future<void> _sendTestAlert() async {
    if (_isSendingTest) return;
    setState(() {
      _isSendingTest = true;
      _error = null;
      _notice = null;
    });
    try {
      final sent = await widget.coordinator.sendTestAlert();
      if (!mounted) return;
      setState(() {
        _notice = sent
            ? 'Test alert sent to SCRBRD.'
            : 'Connect to SCRBRD before sending a test alert.';
      });
    } on Object {
      if (mounted) {
        setState(() {
          _error =
              'The test alert could not be sent. Check your SCRBRD connection.';
        });
      }
    } finally {
      if (mounted) setState(() => _isSendingTest = false);
    }
  }

  void _changeLeagueOrTeam() {
    setState(() {
      _selectedMatchup = null;
      _error = null;
      _notice = null;
    });
  }

  void _chooseDifferentLeague() {
    setState(() {
      _snapshot = null;
      _selectedMatchup = null;
      _selectedRosterId = null;
      _error = null;
      _notice = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final matchup = _selectedMatchup;
    return Scaffold(
      appBar: AppBar(title: const Text('Fantasy Football')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (snapshot == null) ...[
            Text(
              'Fantasy Football',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'Connect your Sleeper league to get live fantasy scoring alerts '
              'on SCRBRD.',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _leagueIdController,
              enabled: !_isLoading,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Sleeper League ID',
                helperText: 'Find your league ID in the Sleeper league URL.',
              ),
              onSubmitted: (_) => _connectLeague(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _isLoading ? null : _connectLeague,
              child: const Text('CONNECT LEAGUE'),
            ),
          ] else if (matchup == null) ...[
            Text(
              snapshot.league.name,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text('Choose your team'),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              initialValue: _selectedRosterId,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Your team',
              ),
              items: snapshot.rosters
                  .map(
                    (roster) => DropdownMenuItem(
                      value: roster.rosterId,
                      child: Text(snapshot.rosterLabel(roster)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: _isLoading ? null : _selectRoster,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _isLoading ? null : _chooseDifferentLeague,
              child: const Text('USE A DIFFERENT LEAGUE'),
            ),
          ] else ...[
            _FantasyStatusCard(
              leagueName: snapshot.league.name,
              matchup: matchup,
              week: snapshot.week,
              alertsEnabled: _alertsEnabled,
              onAlertsChanged: _isLoading ? null : _setAlertsEnabled,
            ),
            const SizedBox(height: 12),
            _MatchupCard(matchup: matchup, playerMetadata: _playerMetadata),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _isLoading ? null : _refreshMatchup,
              icon: const Icon(Icons.refresh),
              label: const Text('REFRESH MATCHUP'),
            ),
            TextButton(
              onPressed: _isLoading ? null : _changeLeagueOrTeam,
              child: const Text('CHANGE LEAGUE / TEAM'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _isSendingTest ? null : _sendTestAlert,
              child: Text(
                _isSendingTest ? 'SENDING TEST ALERT...' : 'SEND TEST ALERT',
              ),
            ),
            const SizedBox(height: 12),
            const _FantasyExplanationCard(),
          ],
          if (_isLoading) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(_loadingLabel, textAlign: TextAlign.center),
          ],
          if (_error case final error?) ...[
            const SizedBox(height: 16),
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_notice case final notice?) ...[
            const SizedBox(height: 12),
            Text(notice, textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
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
