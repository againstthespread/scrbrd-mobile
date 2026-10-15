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
  final Map<String, DataFreshnessSnapshot> _freshness = {};
  int _freshnessSequence = 0;
  int get freshnessRevision => _freshnessSequence;
  Map<String, DataFreshnessSnapshot> get freshness =>
      Map.unmodifiable(_freshness);

  FreshnessOperation beginFreshness(
    String key, {
    required bool provider,
    String scope = '',
  }) {
    key = key.replaceAll(RegExp(r'[\r\n]'), ' ');
    if (key.length > 96) key = key.substring(0, 96);
    scope = scope.replaceAll(RegExp(r'[\r\n]'), ' ');
    if (scope.length > 96) scope = scope.substring(0, 96);
    final token = FreshnessOperation(
      key,
      ++_freshnessSequence,
      provider,
      scope,
    );
    final previous = _freshness.remove(key) ?? const DataFreshnessSnapshot();
    _freshness[key] = previous.update(
      provider: provider,
      state: provider ? 'fetching' : 'writing',
      attemptAt: _clock().toUtc(),
      token: token.id,
      scope: scope,
    );
    if (_freshness.length > 64) _freshness.remove(_freshness.keys.first);
    notifyListeners();
    return token;
  }

  void finishFreshness(FreshnessOperation token, String state) {
    final previous = _freshness[token.key];
    if (previous == null) return;
    if ((token.provider ? previous.providerToken : previous.deliveryToken) !=
        token.id) {
      // A newer rejected send must not hide an older write that actually
      // completed. Keep the latest attempt's state, but record the write fact.
      // Provider results from superseded requests cannot re-verify old content.
      if (!token.provider && state == 'written') {
        _freshness[token.key] = previous.update(
          provider: false,
          state: previous.deliveryState,
          successAt: _clock().toUtc(),
          successScope: token.scope,
        );
        notifyListeners();
      }
      return;
    }
    _freshness[token.key] = previous.update(
      provider: token.provider,
      state: state,
      successAt: state == 'fetched' || state == 'empty' || state == 'written'
          ? _clock().toUtc()
          : null,
    );
    add(
      '${token.key} ${token.provider ? 'provider' : 'delivery'}=$state',
      source: 'freshness',
    );
  }

  void deliveryState(String key, String state) {
    final token = beginFreshness(key, provider: false);
    finishFreshness(token, state);
  }

  Future<T> trackProvider<T>(
    String key,
    Future<T> Function() fetch, {
    String scope = '',
    bool Function()? isCurrent,
    bool Function(T)? isEmpty,
  }) async {
    final token = beginFreshness(key, provider: true, scope: scope);
    try {
      final value = await fetch();
      finishFreshness(
        token,
        isCurrent?.call() == false
            ? 'cancelled'
            : isEmpty?.call(value) == true
            ? 'empty'
            : 'fetched',
      );
      return value;
    } on Object {
      finishFreshness(
        token,
        isCurrent?.call() == false ? 'cancelled' : 'failed',
      );
      rethrow;
    }
  }

  Future<void> trackDelivery(
    String key,
    Future<void> Function() write, {
    String scope = '',
    bool Function()? isCurrent,
  }) async {
    final token = beginFreshness(key, provider: false, scope: scope);
    try {
      if (isCurrent?.call() == false) {
        throw StateError('BLE operation cancelled.');
      }
      await write();
      if (isCurrent?.call() == false) {
        throw StateError('BLE operation cancelled.');
      }
      finishFreshness(token, 'written');
    } on Object {
      finishFreshness(
        token,
        isCurrent?.call() == false ? 'cancelled' : 'failed',
      );
      rethrow;
    }
  }

  String get freshnessText => [
    'Freshness (UTC; app-session history; asOf=${_clock().toUtc().toIso8601String()}). Fetch and write timestamps are independent. '
        'Failed/cancelled/empty fetches do not verify cached content; unchanged data is not a new BLE delivery. '
        'BLE writes do not confirm ESP processing or display.',
    for (final entry in _freshness.entries)
      '${entry.key}: ${entry.value.displayText}',
  ].join('\n');

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
    freshnessText,
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

class FreshnessOperation {
  const FreshnessOperation(this.key, this.id, this.provider, this.scope);
  final String key;
  final int id;
  final bool provider;
  final String scope;
}

/// Provider verification and phone-side writes are separate facts. A write of
/// cached data never advances provider freshness. No device receipt is implied.
class DataFreshnessSnapshot {
  const DataFreshnessSnapshot({
    this.lastProviderSuccess,
    this.lastBleWrite,
    this.providerAttemptAt,
    this.deliveryAttemptAt,
    this.providerState = 'unknown',
    this.deliveryState = 'unknown',
    this.providerScope = '',
    this.deliveryScope = '',
    this.lastProviderSuccessScope = '',
    this.lastBleWriteScope = '',
    this.providerToken = 0,
    this.deliveryToken = 0,
  });
  final DateTime? lastProviderSuccess;
  final DateTime? lastBleWrite;
  final DateTime? providerAttemptAt;
  final DateTime? deliveryAttemptAt;
  final String providerState;
  final String deliveryState;
  final String lastProviderSuccessScope;
  final String lastBleWriteScope;
  final String providerScope;
  final String deliveryScope;
  final int providerToken;
  final int deliveryToken;

  DataFreshnessSnapshot update({
    required bool provider,
    required String state,
    DateTime? attemptAt,
    DateTime? successAt,
    int? token,
    String? scope,
    String? successScope,
  }) => DataFreshnessSnapshot(
    lastProviderSuccess: provider
        ? successAt ?? lastProviderSuccess
        : lastProviderSuccess,
    lastBleWrite: provider ? lastBleWrite : successAt ?? lastBleWrite,
    providerAttemptAt: provider
        ? attemptAt ?? providerAttemptAt
        : providerAttemptAt,
    deliveryAttemptAt: provider
        ? deliveryAttemptAt
        : attemptAt ?? deliveryAttemptAt,
    providerState: provider ? state : providerState,
    deliveryState: provider ? deliveryState : state,
    lastProviderSuccessScope: provider && successAt != null
        ? providerScope
        : lastProviderSuccessScope,
    lastBleWriteScope: !provider && successAt != null
        ? successScope ?? deliveryScope
        : lastBleWriteScope,
    providerScope: provider ? scope ?? providerScope : providerScope,
    deliveryScope: provider ? deliveryScope : scope ?? deliveryScope,
    providerToken: provider ? token ?? providerToken : providerToken,
    deliveryToken: provider ? deliveryToken : token ?? deliveryToken,
  );

  String get displayText =>
      'provider=$providerState scope=$providerScope '
      'attempt=${providerAttemptAt?.toIso8601String() ?? "never"} '
      'lastSuccessfulFetch=${lastProviderSuccess?.toIso8601String() ?? "never"} fetchedScope=$lastProviderSuccessScope; '
      'delivery=$deliveryState scope=$deliveryScope '
      'attempt=${deliveryAttemptAt?.toIso8601String() ?? "never"} '
      'lastCompletedBleWrite=${lastBleWrite?.toIso8601String() ?? "never"} writtenScope=$lastBleWriteScope; '
      'ESP=unconfirmed';
}
