import 'package:flutter/material.dart';

import 'favorites_store.dart';
import 'sports_league.dart';
import 'team_catalog.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key, required this.store});

  final FavoritesStore store;

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  FavoritesStore get store => widget.store;
  bool _saving = false;

  Future<void> _save(Future<void> Function() operation) async {
    if (_saving || !mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() => _saving = true);
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Could not save preferences. Please retry.'),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _save(operation),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Favorites')),
    body: AbsorbPointer(
      absorbing: _saving,
      child: AnimatedBuilder(
        animation: store,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'Choose the teams you care about most.\n'
                'SCRBRD will put their games first when they play.',
              ),
            ),
            for (final league in const [
              SportsLeague.nfl,
              SportsLeague.nba,
              SportsLeague.mlb,
            ]) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
                child: Text(
                  league.label,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Card(
                child: Column(
                  children: [
                    for (final team in TeamCatalog.forLeague(league))
                      ListTile(
                        title: Text(team.displayName),
                        leading: Icon(
                          store.isFavorite(team.league, team.key)
                              ? Icons.star
                              : Icons.star_border,
                          color: store.isFavorite(team.league, team.key)
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        onTap: () {
                          final enabled = !store.isFavorite(
                            team.league,
                            team.key,
                          );
                          _save(() => store.setFavorite(team, enabled));
                        },
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
