import 'dart:async';

/// Serializes startup sync ownership and subsequent WAKE-driven refresh work.
/// Wakes received during startup or an active refresh are coalesced into one
/// subsequent refresh pass.
class SportsOperationGate {
  SportsOperationGate({this.onDiagnostic});

  final void Function(String message)? onDiagnostic;

  bool _initialSyncActive = false;
  int _queuedInitialSyncs = 0;
  Future<void> _initialSyncTail = Future<void>.value();
  Completer<void>? _liveRefreshFinished;
  bool _liveRefreshActive = false;
  bool _refreshPending = false;
  Future<void> Function()? _pendingRefresh;

  bool get isInitialSyncActive => _initialSyncActive || _queuedInitialSyncs > 0;
  bool get isLiveRefreshActive => _liveRefreshActive;

  Future<void> runInitialSync(Future<void> Function() operation) async {
    final previous = _initialSyncTail;
    final finished = Completer<void>();
    _initialSyncTail = finished.future;
    _queuedInitialSyncs++;
    await previous;
    // A reconnect's startup must not overlap an older refresh's final writes.
    final liveFinished = _liveRefreshFinished;
    if (liveFinished != null) await liveFinished.future;
    _initialSyncActive = true;
    _diagnose('initial sync ownership acquired');
    try {
      await operation();
    } finally {
      _initialSyncActive = false;
      _queuedInitialSyncs--;
      finished.complete();
      _diagnose('initial sync ownership released');
      if (_queuedInitialSyncs == 0 && _refreshPending) {
        final refresh = _takePendingRefresh();
        if (refresh != null) {
          _diagnose('post-sync deferred WAKE executed');
          await requestLiveRefresh(refresh);
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
    _liveRefreshActive = true;
    final finished = Completer<void>();
    _liveRefreshFinished = finished;
    var refresh = initialRefresh;
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      while (true) {
        _diagnose('WAKE received; live refresh started');
        try {
          await refresh();
        } on Object catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
          _diagnose('live refresh failed: $error');
        }

        if (_queuedInitialSyncs > 0) break;
        final pendingRefresh = _takePendingRefresh();
        if (pendingRefresh == null) {
          _diagnose('live refresh completed; no deferred WAKE pending');
          break;
        }
        _diagnose('live refresh completed; deferred WAKE refresh starting');
        refresh = pendingRefresh;
      }
    } finally {
      _liveRefreshActive = false;
      _liveRefreshFinished = null;
      finished.complete();
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

  void _diagnose(String message) => onDiagnostic?.call(message);
}
