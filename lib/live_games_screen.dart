import 'package:flutter/material.dart';

import 'device_transport.dart';
import 'game_data.dart';
import 'game_editor.dart';
import 'selected_game_auto_updater.dart';
import 'sports_league.dart';
import 'sports_repository.dart';

class LiveGamesScreen extends StatefulWidget {
  const LiveGamesScreen({
    super.key,
    required this.repository,
    required this.transport,
    this.autoUpdateRefreshInterval =
        SelectedGameAutoUpdater.defaultRefreshInterval,
  });

  final SportsRepository repository;
  final DeviceTransport transport;
  final Duration autoUpdateRefreshInterval;

  @override
  State<LiveGamesScreen> createState() => _LiveGamesScreenState();
}

class _LiveGamesScreenState extends State<LiveGamesScreen> {
  var _isLoading = false;
  String? _errorMessage;
  var _selectedLeague = SportsLeague.mlb;
  late DateTime _selectedDate;
  List<GameData> _games = const [];
  SelectedGameAutoUpdater? _autoUpdater;
  String? _autoUpdateMessage;
  final List<String> _autoUpdateDiagnostics = [];
  var _isDisposing = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
  }

  @override
  void dispose() {
    _isDisposing = true;
    _autoUpdater?.dispose();
    super.dispose();
  }

  Future<void> _refreshGames() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final games = await widget.repository.fetchGamesForDate(
        _selectedLeague,
        _selectedDate,
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _games = games;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _games = const [];
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

  void _selectLeague(SportsLeague? league) {
    if (league == null || league == _selectedLeague) {
      return;
    }

    setState(() {
      _selectedLeague = league;
      _games = const [];
      _errorMessage = null;
      _autoUpdateMessage = null;
      _autoUpdateDiagnostics.clear();
    });
    _autoUpdater?.dispose();
    _autoUpdater = null;
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
      _errorMessage = null;
      _autoUpdateMessage = null;
      _autoUpdateDiagnostics.clear();
    });
    _autoUpdater?.dispose();
    _autoUpdater = null;
  }

  void _openGamePreview(GameData gameData) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) {
          return Scaffold(
            appBar: AppBar(title: const Text('Packet Preview')),
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
                      onPacketSent: (sentGameData) {
                        _startAutoUpdates(
                          selectedGame: gameData,
                          lastSentGame: sentGameData,
                        );
                      },
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

  void _startAutoUpdates({
    required GameData selectedGame,
    required GameData lastSentGame,
  }) {
    _autoUpdater?.dispose();
    _recordAutoUpdateDiagnostic('updater created');
    final updater = SelectedGameAutoUpdater(
      repository: widget.repository,
      transport: widget.transport,
      league: _selectedLeague,
      selectedDate: _selectedDate,
      selectedGame: selectedGame,
      lastSentGame: lastSentGame,
      refreshInterval: widget.autoUpdateRefreshInterval,
      onError: (error) {
        if (!mounted) {
          return;
        }

        setState(() {
          _autoUpdateMessage = 'Auto update paused: $error';
        });
      },
      onDiagnostic: _recordAutoUpdateDiagnostic,
    );
    updater.start();
    _autoUpdater = updater;

    if (!mounted) {
      return;
    }

    setState(() {
      _autoUpdateMessage =
          'Auto updates enabled every '
          '${widget.autoUpdateRefreshInterval.inSeconds}s.';
    });
  }

  void _recordAutoUpdateDiagnostic(String message) {
    if (!mounted || _isDisposing) {
      return;
    }

    final now = DateTime.now();
    final timestamp =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';

    setState(() {
      _autoUpdateDiagnostics.insert(0, '$timestamp $message');
      if (_autoUpdateDiagnostics.length > 12) {
        _autoUpdateDiagnostics.removeLast();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Games'),
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
              DropdownButtonFormField<SportsLeague>(
                initialValue: _selectedLeague,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'League',
                ),
                items: SportsLeague.values.map((league) {
                  return DropdownMenuItem(
                    value: league,
                    child: Text(league.label),
                  );
                }).toList(),
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
              if (_autoUpdateMessage != null) ...[
                Text(
                  _autoUpdateMessage!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (_autoUpdateDiagnostics.isNotEmpty) ...[
                _AutoUpdateDiagnosticsPanel(
                  diagnostics: _autoUpdateDiagnostics,
                ),
                const SizedBox(height: 12),
              ],
              Expanded(
                child: _LiveGamesContent(
                  games: _games,
                  selectedLeague: _selectedLeague,
                  errorMessage: _errorMessage,
                  onGameSelected: _openGamePreview,
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
  final ValueChanged<GameData> onGameSelected;
  final TextStyle? emptyTextStyle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (errorMessage != null) {
      return Center(
        child: Text(
          errorMessage!,
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
        return _LiveGameListItem(game: game, onTap: () => onGameSelected(game));
      },
    );
  }
}

class _AutoUpdateDiagnosticsPanel extends StatelessWidget {
  const _AutoUpdateDiagnosticsPanel({required this.diagnostics});

  final List<String> diagnostics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Temporary Auto-Update Diagnostics',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 160,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: diagnostics
                    .map(
                      (message) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          message,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveGameListItem extends StatelessWidget {
  const _LiveGameListItem({required this.game, required this.onTap});

  final GameData game;
  final VoidCallback onTap;

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
