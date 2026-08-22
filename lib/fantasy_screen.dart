import 'package:flutter/material.dart';

import 'fantasy_point_delta_tracker.dart';
import 'console_device_transport.dart';
import 'device_transport.dart';
import 'fantasy_scoring_correlation.dart';
import 'espn_nfl_play_repository.dart';
import 'fantasy_nfl_play.dart';
import 'sleeper_api_client.dart';
import 'sleeper_fantasy_repository.dart';
import 'sleeper_league_id_store.dart';
import 'sleeper_models.dart';
import 'sleeper_player_repository.dart';

class FantasyScreen extends StatefulWidget {
  const FantasyScreen({
    super.key,
    this.repository,
    this.leagueIdStore,
    this.playerRepository,
    this.nflPlayRepository,
    this.transport,
  });

  final SleeperFantasyRepository? repository;
  final SleeperLeagueIdStore? leagueIdStore;
  final SleeperPlayerRepository? playerRepository;
  final EspnNflPlayRepository? nflPlayRepository;
  final DeviceTransport? transport;

  @override
  State<FantasyScreen> createState() => _FantasyScreenState();
}

class _FantasyScreenState extends State<FantasyScreen> {
  final _leagueIdController = TextEditingController();
  final _deltaTracker = FantasyPointDeltaTracker();
  final _correlator = const FantasyScoringCorrelator();
  SleeperApiClient? _ownedApiClient;
  SleeperApiClient? _ownedPlayerApiClient;
  late final SleeperFantasyRepository _repository;
  late final SleeperPlayerRepository _playerRepository;
  late final EspnNflPlayRepository _nflPlayRepository;
  late final bool _ownsNflPlayRepository;
  late final SleeperLeagueIdStore _leagueIdStore;
  late final DeviceTransport _transport;
  SleeperLeagueSnapshot? _snapshot;
  SleeperFantasyMatchup? _selectedMatchup;
  int? _selectedRosterId;
  bool _isLoading = false;
  String? _error;
  List<FantasyPointDelta> _recentPointChanges = const [];
  List<FantasyPointReconciliation> _reconciliations = const [];
  Map<String, SleeperFantasyPlayer> _playerMetadata = const {};
  List<FantasyNflPlay> _recentNflPlays = const [];
  bool _isRefreshingNflPlays = false;
  String? _nflPlayError;
  bool _isSendingFantasyAlert = false;
  List<FantasyScoringEvent> _recentFantasyEvents = const [];
  bool _isObservingFantasy = false;

  @override
  void initState() {
    super.initState();
    if (widget.repository case final repository?) {
      _repository = repository;
    } else {
      _ownedApiClient = SleeperApiClient();
      _repository = SleeperFantasyRepository(_ownedApiClient!);
    }
    if (widget.playerRepository case final playerRepository?) {
      _playerRepository = playerRepository;
    } else {
      final apiClient =
          _ownedApiClient ?? (_ownedPlayerApiClient = SleeperApiClient());
      _playerRepository = SleeperPlayerRepository(apiClient: apiClient);
    }
    _leagueIdStore =
        widget.leagueIdStore ?? SharedPreferencesSleeperLeagueIdStore();
    _ownsNflPlayRepository = widget.nflPlayRepository == null;
    _nflPlayRepository = widget.nflPlayRepository ?? EspnNflPlayRepository();
    _transport = widget.transport ?? const ConsoleDeviceTransport();
    _restoreLeagueId();
  }

  @override
  void dispose() {
    _leagueIdController.dispose();
    _ownedApiClient?.close();
    _ownedPlayerApiClient?.close();
    if (_ownsNflPlayRepository) _nflPlayRepository.close();
    super.dispose();
  }

  Future<void> _refreshNflPlays() async {
    setState(() {
      _isRefreshingNflPlays = true;
      _nflPlayError = null;
    });
    try {
      final plays = await _nflPlayRepository.refresh(DateTime.now());
      if (!mounted) return;
      setState(() {
        _recentNflPlays = plays;
        _isRefreshingNflPlays = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _nflPlayError = error.toString();
        _isRefreshingNflPlays = false;
      });
    }
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
      _recentPointChanges = const [];
      _reconciliations = const [];
      _recentFantasyEvents = const [];
      _playerMetadata = const {};
    });
    _deltaTracker.reset();
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

  Future<void> _refreshMatchup() async {
    final rosterId = _selectedRosterId;
    if (rosterId == null) return;
    final leagueId = _leagueIdController.text.trim();
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final snapshot = await _repository.loadLeague(leagueId);
      final matchup = snapshot.matchupForRoster(rosterId);
      final deltaResult = _deltaTracker.observe(matchup);
      final metadata = await _resolvePlayerMetadata(matchup);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _selectedMatchup = matchup;
        _recentPointChanges = deltaResult.events;
        _reconciliations = deltaResult.reconciliations;
        _playerMetadata = {..._playerMetadata, ...metadata};
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

  Future<void> _observeFantasyCycle() async {
    final rosterId = _selectedRosterId;
    if (rosterId == null || _isObservingFantasy) return;
    final leagueId = _leagueIdController.text.trim();
    setState(() {
      _isObservingFantasy = true;
      _error = null;
      _nflPlayError = null;
    });
    try {
      final snapshot = await _repository.loadLeague(leagueId);
      final matchup = snapshot.matchupForRoster(rosterId);
      final deltaResult = _deltaTracker.observe(matchup);
      final metadata = await _resolvePlayerMetadata(matchup);
      final allMetadata = {..._playerMetadata, ...metadata};
      final plays = await _nflPlayRepository.refresh(DateTime.now());
      final events = _correlator.correlate(
        deltas: deltaResult.events,
        players: allMetadata,
        plays: plays,
        scoringSettings: snapshot.league.scoringSettings,
      );
      for (final event in events) {
        debugPrint('Fantasy correlation: ${event.diagnostic}');
      }
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _selectedMatchup = matchup;
        _recentPointChanges = deltaResult.events;
        _reconciliations = deltaResult.reconciliations;
        _playerMetadata = allMetadata;
        _recentNflPlays = plays;
        _recentFantasyEvents = events;
        _isObservingFantasy = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _isObservingFantasy = false;
      });
    }
  }

  Future<void> _sendTestFantasyAlert() async {
    if (_isSendingFantasyAlert) return;
    final matchup = _selectedMatchup;
    final event = _recentFantasyEvents.isNotEmpty
        ? _recentFantasyEvents.first
        : _sampleFantasyEvent();
    setState(() => _isSendingFantasyAlert = true);
    try {
      await _transport.sendFantasyAlert(
        event,
        userName: matchup?.team.name ?? 'PETER',
        userScore: matchup?.team.matchup.points ?? 104.7,
        opponentName: matchup?.opponent.name ?? 'MIKE',
        opponentScore: matchup?.opponent.matchup.points ?? 97.2,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fantasy alert sent to SCRBRD.')),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Fantasy alert failed: $error')));
    } finally {
      if (mounted) setState(() => _isSendingFantasyAlert = false);
    }
  }

  Future<void> _selectRoster(int? rosterId) async {
    if (rosterId == null || _snapshot == null) return;
    try {
      final matchup = _snapshot!.matchupForRoster(rosterId);
      final deltaResult = _deltaTracker.observe(matchup);
      setState(() {
        _selectedRosterId = rosterId;
        _selectedMatchup = matchup;
        _recentPointChanges = deltaResult.events;
        _reconciliations = deltaResult.reconciliations;
        _error = null;
      });
      final metadata = await _resolvePlayerMetadata(matchup);
      if (!mounted) return;
      setState(() => _playerMetadata = {..._playerMetadata, ...metadata});
    } on Object catch (error) {
      setState(() {
        _selectedRosterId = rosterId;
        _selectedMatchup = null;
        _error = error.toString();
      });
    }
  }

  Future<Map<String, SleeperFantasyPlayer>> _resolvePlayerMetadata(
    SleeperFantasyMatchup matchup,
  ) => _playerRepository.resolvePlayersSafely([
    ...matchup.team.matchup.starters,
    ...matchup.opponent.matchup.starters,
  ]);

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
            _MatchupCard(
              matchup: matchup,
              isLoading: _isLoading,
              onRefresh: _refreshMatchup,
              playerMetadata: _playerMetadata,
            ),
            const SizedBox(height: 12),
            _RecentPointChangesCard(
              changes: _recentPointChanges,
              reconciliations: _reconciliations,
              playerMetadata: _playerMetadata,
            ),
            const SizedBox(height: 12),
            _RecentFantasyEventsCard(
              events: _recentFantasyEvents,
              isRefreshing: _isObservingFantasy,
              onRefresh: _observeFantasyCycle,
            ),
          ],
          const SizedBox(height: 12),
          _RecentNflPlaysCard(
            plays: _recentNflPlays,
            isRefreshing: _isRefreshingNflPlays,
            error: _nflPlayError,
            onRefresh: _refreshNflPlays,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _isSendingFantasyAlert ? null : _sendTestFantasyAlert,
            icon: const Icon(Icons.send_outlined),
            label: Text(
              _isSendingFantasyAlert
                  ? 'SENDING TEST FANTASY ALERT...'
                  : 'SEND TEST FANTASY ALERT TO SCRBRD',
            ),
          ),
        ],
      ),
    );
  }
}

FantasyScoringEvent _sampleFantasyEvent() {
  const player = SleeperFantasyPlayer(
    sleeperPlayerId: 'sample-chase',
    fullName: "Ja'Marr Chase",
    firstName: "Ja'Marr",
    lastName: 'Chase',
    position: 'WR',
    nflTeam: 'CIN',
    espnPlayerId: null,
  );
  const delta = FantasyPointDelta(
    playerId: 'sample-chase',
    side: FantasyMatchupSide.user,
    previousPoints: 0,
    currentPoints: 12,
    delta: 12,
  );
  return const FantasyScoringEvent(
    delta: delta,
    player: player,
    matchedPlay: null,
    confidence: FantasyCorrelationConfidence.high,
    explanation: '50 YD REC TD',
    predictedPoints: 12,
    diagnostic: 'deterministic manual fantasy alert sample',
  );
}

class _RecentFantasyEventsCard extends StatelessWidget {
  const _RecentFantasyEventsCard({
    required this.events,
    required this.isRefreshing,
    required this.onRefresh,
  });

  final List<FantasyScoringEvent> events;
  final bool isRefreshing;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'RECENT FANTASY EVENTS',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: isRefreshing ? null : onRefresh,
                  tooltip: 'Refresh Sleeper and ESPN together',
                  icon: const Icon(Icons.sync),
                ),
              ],
            ),
            if (isRefreshing) const LinearProgressIndicator(),
            if (!isRefreshing && events.isEmpty)
              const Text(
                'No new correlated events. First refresh establishes both baselines.',
              )
            else
              for (final event in events)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        event.player?.fullName ?? event.delta.playerId,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      if (event.explanation case final explanation?)
                        Text(explanation),
                      Text(_signedPoints(event.delta.delta)),
                      Text(
                        event.confidence == FantasyCorrelationConfidence.none
                            ? 'NO PLAY MATCH'
                            : '${event.confidence.name.toUpperCase()} CONFIDENCE',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _RecentNflPlaysCard extends StatelessWidget {
  const _RecentNflPlaysCard({
    required this.plays,
    required this.isRefreshing,
    required this.error,
    required this.onRefresh,
  });

  final List<FantasyNflPlay> plays;
  final bool isRefreshing;
  final String? error;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'RECENT NFL PLAYS',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: isRefreshing ? null : onRefresh,
                  tooltip: 'Refresh NFL plays',
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (isRefreshing) const LinearProgressIndicator(),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else if (plays.isEmpty)
              const Text(
                'No new plays detected. First refresh establishes a baseline.',
              )
            else
              for (final play in plays)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        play.possessionTeam ?? 'NFL',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      Text(play.description),
                      Text(
                        [
                          if (play.quarter != null) 'Q${play.quarter}',
                          if (play.gameClock != null) play.gameClock!,
                        ].join(' '),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _MatchupCard extends StatelessWidget {
  const _MatchupCard({
    required this.matchup,
    required this.isLoading,
    required this.onRefresh,
    required this.playerMetadata,
  });

  final SleeperFantasyMatchup matchup;
  final bool isLoading;
  final VoidCallback onRefresh;
  final Map<String, SleeperFantasyPlayer> playerMetadata;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Current matchup',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  onPressed: isLoading ? null : onRefresh,
                  tooltip: 'Refresh matchup',
                  icon: const Icon(Icons.refresh),
                ),
              ],
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
              playerMetadata: playerMetadata,
            ),
            const SizedBox(height: 20),
            _StarterList(
              title: '${matchup.opponent.name} starters',
              team: matchup.opponent,
              playerMetadata: playerMetadata,
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentPointChangesCard extends StatelessWidget {
  const _RecentPointChangesCard({
    required this.changes,
    required this.reconciliations,
    required this.playerMetadata,
  });

  final List<FantasyPointDelta> changes;
  final List<FantasyPointReconciliation> reconciliations;
  final Map<String, SleeperFantasyPlayer> playerMetadata;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'RECENT POINT CHANGES',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            if (changes.isEmpty)
              const Text('No starter point changes detected.')
            else
              for (final change in changes)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${change.side == FantasyMatchupSide.user ? 'You' : 'Opponent'} · '
                          '${playerMetadata[change.playerId]?.fullName ?? change.playerId}',
                        ),
                      ),
                      Text(_signedPoints(change.delta)),
                    ],
                  ),
                ),
            if (reconciliations.any((item) => !item.matches)) ...[
              const SizedBox(height: 10),
              Text(
                'Diagnostic: starter deltas differ from a matchup total change.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
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

String _points(double value) => value.toStringAsFixed(value % 1 == 0 ? 0 : 2);

String _signedPoints(double value) =>
    '${value >= 0 ? '+' : ''}${value.toStringAsFixed(value % 1 == 0 ? 1 : 2)}';
