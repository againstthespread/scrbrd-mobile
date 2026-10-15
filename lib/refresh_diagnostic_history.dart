import 'dart:collection';

import 'package:flutter/foundation.dart';

class RefreshDiagnosticEntry {
  const RefreshDiagnosticEntry({
    required this.timestamp,
    required this.message,
    this.sequence = 0,
    this.elapsedMilliseconds = 0,
    this.source = 'refresh',
    this.transportId,
    this.generation,
  });

  final DateTime timestamp;
  final String message;
  final int sequence;
  final int elapsedMilliseconds;
  final String source;
  final int? transportId;
  final int? generation;

  String get displayText =>
      '${timestamp.toUtc().toIso8601String()} +${elapsedMilliseconds}ms '
      '#$sequence [$source T${transportId ?? '-'} G${generation ?? '-'}] $message';
}

/// App-isolate lifetime only: navigation/reconnection never clear this ring.
/// Callers supply event metadata, never BLE payloads or provider error text.
class RefreshDiagnosticHistory extends ChangeNotifier {
  RefreshDiagnosticHistory({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    startedAt = _clock();
  }

  static final session = RefreshDiagnosticHistory();
  static const capacity = 512;
  static const maxMessageLength = 240;
  final DateTime Function() _clock;
  final _elapsed = Stopwatch()..start();
  late final DateTime startedAt;
  final _entries = ListQueue<RefreshDiagnosticEntry>();
  int _sequence = 0;
  int _dropped = 0;
  int _clears = 0;

  List<RefreshDiagnosticEntry> get entries => List.unmodifiable(_entries);
  int get droppedCount => _dropped;

  void add(
    String message, {
    String source = 'refresh',
    int? transportId,
    int? generation,
  }) {
    final bounded = message.replaceAll(RegExp(r'[\r\n]'), ' ');
    _entries.addFirst(
      RefreshDiagnosticEntry(
        timestamp: _clock(),
        message: bounded.length > maxMessageLength
            ? bounded.substring(0, maxMessageLength)
            : bounded,
        sequence: ++_sequence,
        elapsedMilliseconds: _elapsed.elapsedMilliseconds,
        source: source,
        transportId: transportId,
        generation: generation,
      ),
    );
    if (_entries.length > capacity) {
      _entries.removeLast();
      _dropped++;
    }
    notifyListeners();
  }

  String exportText() => [
    'SCRBRD H01 diagnostics; session=${startedAt.toUtc().toIso8601String()}; '
        'events=${_entries.length}; evicted=$_dropped; clears=$_clears; '
        'lastSequence=$_sequence; oldest first',
    for (final entry in _entries.toList().reversed) entry.displayText,
  ].join('\n');

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    _clears++;
    _dropped = 0;
    notifyListeners();
  }
}
