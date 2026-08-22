import 'package:flutter/material.dart';

import 'device_transport.dart';
import 'game_data.dart';
import 'game_editor.dart';
import 'golf_leaderboard.dart';
import 'loaded_league_slate_sender.dart';
import 'sports_league.dart';
import 'sports_repository.dart';
import 'session_aware_device_sender.dart';

class LiveGamesScreen extends StatefulWidget {
  const LiveGamesScreen({
    super.key,
    required this.repository,
    required this.transport,
    this.developerMode = false,
  });

  final SportsRepository repository;
  final DeviceTransport transport;
  final bool developerMode;

  @override
  State<LiveGamesScreen> createState() => _LiveGamesScreenState();
}

class _LiveGamesScreenState extends State<LiveGamesScreen> {
  var _isLoading = false;
  var _isSendingSlate = false;
  var _isSendingAllLeagues = false;
  String? _errorMessage;
  var _selectedLeague = SportsLeague.mlb;
  late DateTime _selectedDate;
  List<GameData> _games = const [];
  final Map<SportsLeague, List<GameData>> _loadedGamesByLeague = {};
  final Map<SportsLeague, DateTime> _loadedDatesByLeague = {};
  GolfLeaderboard? _loadedGolfLeaderboard;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshGames());
  }

  Future<void> _refreshGames() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (_selectedLeague == SportsLeague.pga) {
        final leaderboard = await widget.repository.fetchGolfLeaderboardForDate(
          _selectedDate,
        );
        if (!mounted) return;
        setState(() {
          _loadedGolfLeaderboard = leaderboard;
          _loadedDatesByLeague[SportsLeague.pga] = _selectedDate;
          _games = const [];
          if (leaderboard == null) {
            _errorMessage = null;
            _selectedLeague = SportsLeague.mlb;
            _games = _loadedGamesByLeague[SportsLeague.mlb] ?? const [];
          }
        });
        return;
      }
      final games = await widget.repository.fetchGamesForDate(
        _selectedLeague,
        _selectedDate,
      );
      GolfLeaderboard? discoveredGolf;
      try {
        discoveredGolf = await widget.repository.fetchGolfLeaderboardForDate(
          _selectedDate,
        );
      } on Object catch (error) {
        debugPrint('PGA discovery unavailable: $error');
      }
      if (!mounted) {
        return;
      }

      setState(() {
        _games = games;
        _loadedGamesByLeague[_selectedLeague] = games;
        _loadedDatesByLeague[_selectedLeague] = _selectedDate;
        _loadedGolfLeaderboard = discoveredGolf;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _games = const [];
        _loadedGamesByLeague.remove(_selectedLeague);
        if (_selectedLeague == SportsLeague.pga) {
          _loadedGolfLeaderboard = null;
        }
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _sendLoadedSlate() async {
    setState(() => _isSendingSlate = true);
    try {
      if (_selectedLeague == SportsLeague.pga) {
        final sender = widget.transport;
        if (sender is SessionAwareDeviceSender) {
          await sender.sendGolf(
            _loadedGolfLeaderboard!,
            selectedDate: _selectedDate,
          );
        } else {
          await sender.sendGolfLeaderboard(_loadedGolfLeaderboard!);
        }
      } else {
        final sender = widget.transport;
        if (sender is SessionAwareDeviceSender) {
          await sender.sendTeamSlate(_games, selectedDate: _selectedDate);
        } else {
          await sender.sendGameSlate(_games);
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _selectedLeague == SportsLeague.pga
                ? 'Sent ${_loadedGolfLeaderboard!.golfers.length} golfers to SCRBRD.'
                : 'Sent ${_games.length} games to SCRBRD.',
          ),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Slate send failed: $error')));
    } finally {
      if (mounted) setState(() => _isSendingSlate = false);
    }
  }

  Future<void> _sendAllLoadedLeagues() async {
    setState(() => _isSendingAllLeagues = true);
    try {
      final count = await LoadedLeagueSlateSender(transport: widget.transport)
          .send(
            _loadedGamesByLeague,
            loadedGolf: _loadedGolfLeaderboard,
            selectedDates: _loadedDatesByLeague,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sent $count loaded leagues to SCRBRD.')),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Multi-league send failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _isSendingAllLeagues = false);
    }
  }

  void _selectLeague(SportsLeague? league) {
    if (league == null || league == _selectedLeague) {
      return;
    }

    setState(() {
      _selectedLeague = league;
      _games = _loadedGamesByLeague[league] ?? const [];
      _errorMessage = null;
    });
  }

  Future<void> _selectDate() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 2, 12, 31),
    );

    if (pickedDate == null) {
      return;
    }

    setState(() {
      _selectedDate = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
      );
      _games = const [];
      _loadedGamesByLeague.clear();
      _loadedDatesByLeague.clear();
      _loadedGolfLeaderboard = null;
      if (_selectedLeague == SportsLeague.pga) {
        _selectedLeague = SportsLeague.mlb;
      }
      _errorMessage = null;
    });
  }

  void _openGamePreview(GameData gameData) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) {
          return Scaffold(
            appBar: AppBar(title: const Text('Manual Game Packet')),
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: GameEditor(
                      initialGameData: gameData,
                      previewInitially: true,
                      transport: widget.transport,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.developerMode ? 'Games and Slate Tools' : "Today's Games",
        ),
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _refreshGames,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                onPressed: _isLoading ? null : _refreshGames,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
              const SizedBox(height: 12),
              if (widget.developerMode)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            (_selectedLeague == SportsLeague.pga
                                    ? _loadedGolfLeaderboard == null
                                    : _games.isEmpty) ||
                                _isSendingSlate ||
                                _isSendingAllLeagues
                            ? null
                            : _sendLoadedSlate,
                        icon: const Icon(Icons.send),
                        label: Text(
                          _isSendingSlate
                              ? 'Sending slate...'
                              : 'Send Loaded Games to SCRBRD',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            (_loadedGolfLeaderboard == null &&
                                    _loadedGamesByLeague.values.every(
                                      (games) => games.isEmpty,
                                    )) ||
                                _isSendingSlate ||
                                _isSendingAllLeagues
                            ? null
                            : _sendAllLoadedLeagues,
                        icon: const Icon(Icons.send_and_archive),
                        label: Text(
                          _isSendingAllLeagues
                              ? 'Sending loaded leagues...'
                              : 'Send All Loaded Leagues to SCRBRD',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ],
                ),
              if (widget.developerMode) const SizedBox(height: 12),
              DropdownButtonFormField<SportsLeague>(
                initialValue: _selectedLeague,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'League',
                ),
                items: SportsLeague.values
                    .where(
                      (league) =>
                          league != SportsLeague.pga ||
                          _loadedGolfLeaderboard != null,
                    )
                    .map((league) {
                      return DropdownMenuItem(
                        value: league,
                        child: Text(league.label),
                      );
                    })
                    .toList(),
                onChanged: _isLoading ? null : _selectLeague,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _isLoading ? null : _selectDate,
                icon: const Icon(Icons.calendar_month),
                label: Text(_formatDate(_selectedDate)),
              ),
              const SizedBox(height: 16),
              if (_isLoading) const LinearProgressIndicator(),
              if (_isLoading) const SizedBox(height: 16),
              Expanded(
                child: _selectedLeague == SportsLeague.pga
                    ? _GolfLeaderboardContent(
                        leaderboard: _loadedGolfLeaderboard,
                        errorMessage: _errorMessage,
                      )
                    : _LiveGamesContent(
                        games: _games,
                        selectedLeague: _selectedLeague,
                        errorMessage: _errorMessage,
                        onGameSelected: widget.developerMode
                            ? _openGamePreview
                            : null,
                        emptyTextStyle: theme.textTheme.bodyLarge,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }
}

class _GolfLeaderboardContent extends StatelessWidget {
  const _GolfLeaderboardContent({
    required this.leaderboard,
    required this.errorMessage,
  });

  final GolfLeaderboard? leaderboard;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    if (errorMessage != null) {
      return const Center(
        child: Text(
          'Could not load PGA right now. Try again.',
          textAlign: TextAlign.center,
        ),
      );
    }
    final value = leaderboard;
    if (value == null) {
      return const Center(
        child: Text(
          'No covered PGA tournament is available for this date.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          value.tournamentName,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: value.golfers.length,
            itemBuilder: (context, index) {
              final golfer = value.golfers[index];
              return ListTile(
                dense: true,
                leading: Text(golfer.rank),
                title: Text(golfer.name),
                subtitle: golfer.detail == null ? null : Text(golfer.detail!),
                trailing: Text(golfer.score),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _LiveGamesContent extends StatelessWidget {
  const _LiveGamesContent({
    required this.games,
    required this.selectedLeague,
    required this.errorMessage,
    required this.onGameSelected,
    required this.emptyTextStyle,
  });

  final List<GameData> games;
  final SportsLeague selectedLeague;
  final String? errorMessage;
  final ValueChanged<GameData>? onGameSelected;
  final TextStyle? emptyTextStyle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (errorMessage != null) {
      return Center(
        child: Text(
          'Could not load ${selectedLeague.label} right now. Try again.',
          textAlign: TextAlign.center,
          style: emptyTextStyle?.copyWith(color: colorScheme.error),
        ),
      );
    }

    if (games.isEmpty) {
      return Center(
        child: Text(
          'No ${selectedLeague.label} games scheduled for this date.',
          textAlign: TextAlign.center,
          style: emptyTextStyle,
        ),
      );
    }

    return ListView.separated(
      itemCount: games.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final game = games[index];
        return _LiveGameListItem(
          game: game,
          onTap: onGameSelected == null ? null : () => onGameSelected!(game),
        );
      },
    );
  }
}

class _LiveGameListItem extends StatelessWidget {
  const _LiveGameListItem({required this.game, required this.onTap});

  final GameData game;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusColor = switch (game.status) {
      'LIVE' => Colors.red,
      'FINAL' => Colors.green,
      _ => colorScheme.primary,
    };

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest,
      child: ListTile(
        onTap: onTap,
        title: Text('${game.awayTeam} at ${game.homeTeam}'),
        subtitle: Text(
          '${game.league} | ${_displayStatus(game)} | ${game.clock}',
        ),
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: 0.14),
          child: Icon(Icons.sports_football, color: statusColor),
        ),
        trailing: Text(
          '${game.awayScore} - ${game.homeScore}',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  String _displayStatus(GameData game) {
    if (game.status == 'FINAL') {
      return 'FINAL';
    }

    if (game.statusDetail == null || game.statusDetail == game.status) {
      return game.status;
    }

    return '${game.status} (${game.statusDetail})';
  }
}
