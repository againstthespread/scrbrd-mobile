import 'dart:async';

/// Serializes startup sync ownership and subsequent WAKE-driven refresh work.
/// Wakes received during startup or an active refresh are coalesced into one
/// subsequent refresh pass.
class SportsOperationGate {
  SportsOperationGate({this.onDiagnostic});

  final void Function(String message)? onDiagnostic;

  bool _initialSyncActive = false;
  bool _liveRefreshActive = false;
  bool _refreshPending = false;
  Future<void> Function()? _pendingRefresh;

  bool get isInitialSyncActive => _initialSyncActive;
  bool get isLiveRefreshActive => _liveRefreshActive;

  Future<void> runInitialSync(Future<void> Function() operation) async {
    if (_initialSyncActive) return;
    _initialSyncActive = true;
    _diagnose('initial sync ownership acquired');
    try {
      await operation();
    } finally {
      _initialSyncActive = false;
      _diagnose('initial sync ownership released');
      if (_refreshPending) {
        final refresh = _takePendingRefresh();
        if (refresh != null) {
          _diagnose('post-sync deferred WAKE executed');
          await requestLiveRefresh(refresh);
        }
      }
    }
  }

  Future<void> requestLiveRefresh(Future<void> Function() refresh) async {
    if (_initialSyncActive) {
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
