import 'dart:async';

/// Serializes startup sync ownership and subsequent WAKE-driven refresh work.
/// Wakes received during startup or an active refresh are coalesced into one
/// subsequent refresh pass.
class SportsOperationGate {
  SportsOperationGate({this.onDiagnostic});

  final void Function(String message)? onDiagnostic;

  int _epoch = 0;
  final _connectionWaiters = <Completer<void>>{};

  /// Called after connection-generation invalidation. Old operations retain
  /// their own generation guards; they must not hold the next session's gate.
  void resetConnection() {
    _epoch++;

    _initialSyncActive = false;
    _queuedInitialSyncs = 0;
    _initialSyncTail = Future<void>.value();
    _liveRefreshFinished = null;
    _liveRefreshActive = false;
    clearDeferredWake();
    for (final waiter in _connectionWaiters.toList()) {
      waiter.complete();
    }
    _connectionWaiters.clear();
    _diagnose('connection ownership reset');
  }

  bool _initialSyncActive = false;
  int _queuedInitialSyncs = 0;
  Future<void> _initialSyncTail = Future<void>.value();
  Completer<void>? _liveRefreshFinished;
  bool _liveRefreshActive = false;
  bool _refreshPending = false;
  Future<void> Function()? _pendingRefresh;

  int _diagnosticOperationId = 0;
  String get diagnosticState =>
      'initial=$_initialSyncActive queued=$_queuedInitialSyncs '
      'live=$_liveRefreshActive pending=$_refreshPending';

  bool get isInitialSyncActive => _initialSyncActive || _queuedInitialSyncs > 0;
  bool get isLiveRefreshActive => _liveRefreshActive;

  Future<void> runInitialSync(Future<void> Function() operation) async {
    final epoch = _epoch;
    final cancelled = Completer<void>();
    _connectionWaiters.add(cancelled);
    final ended = cancelled.future;
    final op = ++_diagnosticOperationId;
    final previous = _initialSyncTail;
    final finished = Completer<void>();
    _initialSyncTail = finished.future;
    _queuedInitialSyncs++;
    _diagnose('initial sync queued op=$op');
    try {
      await Future.any([previous, ended]);
      if (epoch != _epoch) return;
      // A reconnect's startup must not overlap an older refresh's final writes.
      final liveFinished = _liveRefreshFinished;
      if (liveFinished != null) {
        _diagnose('initial sync waiting for live owner op=$op');
        await Future.any([liveFinished.future, ended]);
        if (epoch != _epoch) return;
      }
      _initialSyncActive = true;
      _diagnose('initial sync ownership acquired op=$op');
      await Future.any([Future<void>.sync(operation), ended]);
    } finally {
      _connectionWaiters.remove(cancelled);
      finished.complete();
      if (epoch == _epoch) {
        _initialSyncActive = false;
        _queuedInitialSyncs--;
        _diagnose('initial sync ownership released op=$op');
        if (_queuedInitialSyncs == 0 && _refreshPending) {
          final refresh = _takePendingRefresh();
          if (refresh != null) {
            _diagnose('post-sync deferred WAKE executed');
            await requestLiveRefresh(refresh);
          }
        }
      }
    }
  }

  Future<void> requestLiveRefresh(Future<void> Function() refresh) async {
    if (isInitialSyncActive) {
      _markRefreshPending(
        refresh,
        firstDiagnostic: 'WAKE received during initial sync; deferred',
        existingDiagnostic:
            'WAKE received during initial sync; deferred WAKE already pending',
      );
      return;
    }
    if (_liveRefreshActive) {
      _markRefreshPending(
        refresh,
        firstDiagnostic:
            'WAKE received during active live refresh; '
            'one follow-up refresh pending',
        existingDiagnostic:
            'WAKE received during active live refresh; '
            'follow-up already pending',
      );
      return;
    }

    await _drainLiveRefreshes(refresh);
  }

  Future<void> _drainLiveRefreshes(
    Future<void> Function() initialRefresh,
  ) async {
    final epoch = _epoch;
    final cancelled = Completer<void>();
    _connectionWaiters.add(cancelled);
    final ended = cancelled.future;
    final op = ++_diagnosticOperationId;
    _liveRefreshActive = true;
    final finished = Completer<void>();
    _liveRefreshFinished = finished;
    _diagnose('live refresh ownership acquired op=$op');
    var refresh = initialRefresh;
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      while (true) {
        _diagnose('WAKE received; live refresh started');
        try {
          await Future.any([Future<void>.sync(refresh), ended]);
        } on Object catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
          _diagnose('live refresh failed type=${error.runtimeType}');
        }

        if (epoch != _epoch || _queuedInitialSyncs > 0) break;
        final pendingRefresh = _takePendingRefresh();
        if (pendingRefresh == null) {
          _diagnose('live refresh completed; no deferred WAKE pending');
          break;
        }
        _diagnose('live refresh completed; deferred WAKE refresh starting');
        refresh = pendingRefresh;
      }
    } finally {
      _connectionWaiters.remove(cancelled);
      finished.complete();
      if (epoch == _epoch) {
        _liveRefreshActive = false;
        _liveRefreshFinished = null;
        _diagnose('live refresh ownership released op=$op');
      }
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  void clearDeferredWake() {
    final hadPendingRefresh = _refreshPending;
    _refreshPending = false;
    _pendingRefresh = null;
    if (hadPendingRefresh) {
      _diagnose('BLE disconnected; deferred WAKE cleared');
    }
  }

  void _markRefreshPending(
    Future<void> Function() refresh, {
    required String firstDiagnostic,
    required String existingDiagnostic,
  }) {
    final alreadyPending = _refreshPending;
    _refreshPending = true;
    _pendingRefresh = refresh;
    _diagnose(alreadyPending ? existingDiagnostic : firstDiagnostic);
  }

  Future<void> Function()? _takePendingRefresh() {
    if (!_refreshPending) return null;
    final refresh = _pendingRefresh;
    _refreshPending = false;
    _pendingRefresh = null;
    return refresh;
  }

  void _diagnose(String message) =>
      onDiagnostic?.call('$message; $diagnosticState');
}
