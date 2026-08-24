import 'package:flutter/material.dart';

import 'favorites_store.dart';
import 'sports_league.dart';
import 'team_catalog.dart';

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key, required this.store});

  final FavoritesStore store;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Favorites')),
    body: AnimatedBuilder(
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
                      onTap: () => store.setFavorite(
                        team,
                        !store.isFavorite(team.league, team.key),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
