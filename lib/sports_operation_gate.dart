import 'dart:async';

/// Serializes startup sync ownership and subsequent WAKE-driven refresh work.
/// Wakes received during startup are coalesced into one post-sync refresh.
class SportsOperationGate {
  SportsOperationGate({this.onDiagnostic});

  final void Function(String message)? onDiagnostic;

  bool _initialSyncActive = false;
  bool _liveRefreshActive = false;
  bool _deferredWake = false;
  Future<void> Function()? _deferredRefresh;

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
      if (_deferredWake) {
        final refresh = _deferredRefresh;
        _deferredWake = false;
        _deferredRefresh = null;
        if (refresh != null) {
          _diagnose('post-sync deferred WAKE executed');
          await requestLiveRefresh(refresh);
        }
      }
    }
  }

  Future<void> requestLiveRefresh(Future<void> Function() refresh) async {
    if (_initialSyncActive) {
      _deferredWake = true;
      _deferredRefresh = refresh;
      _diagnose('WAKE received during initial sync; deferred');
      return;
    }
    if (_liveRefreshActive) {
      _diagnose('WAKE skipped/coalesced because refresh active');
      return;
    }
    _liveRefreshActive = true;
    _diagnose('WAKE received; live refresh started');
    try {
      await refresh();
    } finally {
      _liveRefreshActive = false;
    }
  }

  void clearDeferredWake() {
    _deferredWake = false;
    _deferredRefresh = null;
  }

  void _diagnose(String message) => onDiagnostic?.call(message);
}
