import 'package:flutter/material.dart';

import 'device_content_preferences.dart';
import 'device_content_preferences_store.dart';

class DeviceContentScreen extends StatefulWidget {
  const DeviceContentScreen({super.key, required this.store});
  final DeviceContentPreferencesStore store;
  @override
  State<DeviceContentScreen> createState() => _DeviceContentScreenState();
}

class _DeviceContentScreenState extends State<DeviceContentScreen> {
  late DeviceContentPreferences _preferences;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _preferences = widget.store.read();
  }

  Future<void> _update(DeviceContentPreferences value) async {
    if (_saving || !mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() => _saving = true);
    try {
      await widget.store.save(value);
      if (mounted) setState(() => _preferences = widget.store.read());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Could not save preferences. Please retry.'),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _update(value),
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
    appBar: AppBar(title: const Text('SCRBRD Content')),
    body: AbsorbPointer(
      absorbing: _saving,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Choose what appears on your SCRBRD and the order you want to see it.',
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      label: const Text('Everything'),
                      onPressed: () => _update(
                        preferencesForPreset(DeviceContentPreset.everything),
                      ),
                    ),
                    ActionChip(
                      label: const Text('Fantasy Focus'),
                      onPressed: () => _update(
                        preferencesForPreset(DeviceContentPreset.fantasyFocus),
                      ),
                    ),
                    ActionChip(
                      label: const Text('Sports Only'),
                      onPressed: () => _update(
                        preferencesForPreset(DeviceContentPreset.sportsOnly),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  'YOUR CONTENT',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _preferences.entries.length,
              // ignore: deprecated_member_use
              onReorder: (oldIndex, newIndex) =>
                  _update(_preferences.reordered(oldIndex, newIndex)),
              itemBuilder: (context, index) {
                final entry = _preferences.entries[index];
                return Card(
                  key: ValueKey(entry.category),
                  child: ListTile(
                    leading: const Icon(Icons.drag_handle),
                    title: Text(
                      entry.category.displayName,
                      style: TextStyle(
                        color: entry.enabled
                            ? null
                            : Theme.of(context).disabledColor,
                      ),
                    ),
                    trailing: Switch(
                      value: entry.enabled,
                      onChanged: (enabled) => _update(
                        _preferences.withEnabled(entry.category, enabled),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Text(
              _preferences.enabledCategories.isEmpty
                  ? "No content selected. SCRBRD won't load sports until you enable at least one category. Changes apply the next time SCRBRD connects."
                  : 'Changes apply the next time SCRBRD connects.',
              style: TextStyle(
                color: _preferences.enabledCategories.isEmpty
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
