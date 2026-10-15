import 'package:flutter/material.dart';

import 'college_football.dart';
import 'college_football_preferences_store.dart';

class CollegeFootballScreen extends StatefulWidget {
  const CollegeFootballScreen({super.key, required this.store});
  final CollegeFootballPreferencesStore store;

  @override
  State<CollegeFootballScreen> createState() => _CollegeFootballScreenState();
}

class _CollegeFootballScreenState extends State<CollegeFootballScreen> {
  CollegeFootballPreferencesStore get store => widget.store;
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
    appBar: AppBar(title: const Text('College Football')),
    body: AbsorbPointer(
      absorbing: _saving,
      child: AnimatedBuilder(
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
                          if (!selected &&
                              preferences.conferences.length == 1) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Keep at least one conference selected. Disable NCAAF in SCRBRD Content to hide college football.',
                                ),
                              ),
                            );
                            return;
                          }
                          _save(
                            () => store.save(
                              preferences.toggled(conference, selected),
                            ),
                          );
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
    ),
  );
}
