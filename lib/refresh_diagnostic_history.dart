import 'package:flutter/foundation.dart';

class RefreshDiagnosticEntry {
  const RefreshDiagnosticEntry({
    required this.timestamp,
    required this.message,
  });

  final DateTime timestamp;
  final String message;

  String get displayText => '${_formatTimestamp(timestamp)} — $message';
}

class RefreshDiagnosticHistory extends ChangeNotifier {
  RefreshDiagnosticHistory({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const capacity = 20;
  final DateTime Function() _clock;
  final _entries = <RefreshDiagnosticEntry>[];

  List<RefreshDiagnosticEntry> get entries => List.unmodifiable(_entries);

  void add(String message) {
    _entries.insert(
      0,
      RefreshDiagnosticEntry(timestamp: _clock(), message: message),
    );
    if (_entries.length > capacity) {
      _entries.removeRange(capacity, _entries.length);
    }
    notifyListeners();
  }

  void clear() {
    if (_entries.isEmpty) {
      return;
    }
    _entries.clear();
    notifyListeners();
  }
}

String _formatTimestamp(DateTime timestamp) {
  final hour = timestamp.hour % 12 == 0 ? 12 : timestamp.hour % 12;
  final minute = timestamp.minute.toString().padLeft(2, '0');
  final second = timestamp.second.toString().padLeft(2, '0');
  final period = timestamp.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute:$second $period';
}
