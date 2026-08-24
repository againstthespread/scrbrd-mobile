import 'package:flutter/material.dart';

import 'college_football.dart';
import 'college_football_preferences_store.dart';

class CollegeFootballScreen extends StatelessWidget {
  const CollegeFootballScreen({super.key, required this.store});
  final CollegeFootballPreferencesStore store;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('College Football')),
    body: AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final preferences = store.read();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Choose the conferences you want on your SCRBRD.'),
            const SizedBox(height: 8),
            const Text(
              'Games are included when at least one team belongs to a selected conference.',
            ),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  for (final conference in NcaafConference.values)
                    CheckboxListTile(
                      title: Text(conference.displayName),
                      value: preferences.contains(conference),
                      onChanged: (selected) {
                        if (selected == null) return;
                        if (!selected && preferences.conferences.length == 1) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Keep at least one conference selected. Disable NCAAF in SCRBRD Content to hide college football.',
                              ),
                            ),
                          );
                          return;
                        }
                        store.save(preferences.toggled(conference, selected));
                      },
                    ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Changes apply to automatic device sync the next time SCRBRD connects.',
              ),
            ),
          ],
        );
      },
    ),
  );
}
