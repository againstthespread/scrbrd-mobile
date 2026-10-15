import 'dart:async';
import 'dart:collection';

/// Optional transport capability. A transaction contains prepared writes only;
/// provider fetching belongs outside ownership of the Bluetooth connection.
abstract interface class LogicalDeviceTransport {
  Future<T> runTransaction<T>(
    Future<T> Function() operation, {
    bool Function()? isCurrent,
  });
}

Future<T> runDeviceTransaction<T>(
  Object transport,
  Future<T> Function() operation, {
  bool Function()? isCurrent,
}) async {
  if (transport is LogicalDeviceTransport) {
    return transport.runTransaction(operation, isCurrent: isCurrent);
  }
  if (isCurrent?.call() == false) throw StateError('Delivery cancelled.');
  final result = await operation();
  if (isCurrent?.call() == false) throw StateError('Delivery cancelled.');
  return result;
}

/// One active transaction and a bounded FIFO. Existing refresh coordinators
/// coalesce automatic requests before admission; explicit sends retain order.
/// A session reset releases callers immediately, even if native work never
/// settles. The old lease remains invalid in every asynchronous continuation.
class LogicalDeviceTransactionQueue {
  LogicalDeviceTransactionQueue({this.maxPending = 16, this.onDiagnostic});

  final int maxPending;
  final void Function(String)? onDiagnostic;
  final _zoneKey = Object();
  final _pending = Queue<_Transaction>();
  _Transaction? _active;
  int _epoch = 0;
  int _sequence = 0;

  void checkOwnership() {
    final lease = Zone.current[_zoneKey];
    if (lease is! _Transaction ||
        !identical(lease, _active) ||
        lease.epoch != _epoch ||
        lease.isCurrent?.call() == false) {
      throw StateError('Delivery cancelled; transaction ownership expired.');
    }
  }

  Future<T> run<T>(
    Future<T> Function() operation, {
    bool Function()? isCurrent,
  }) async {
    // Nested writes join only the current live lease. A late callback inheriting
    // an old Zone must never acquire a fresh lease on a different connection.
    if (Zone.current[_zoneKey] != null) {
      checkOwnership();
      if (isCurrent?.call() == false) throw StateError('Delivery cancelled.');
      final value = await operation();
      checkOwnership();
      if (isCurrent?.call() == false) throw StateError('Delivery cancelled.');
      return value;
    }
    if (isCurrent?.call() == false) throw StateError('Delivery cancelled.');
    if (_active != null && _pending.length >= maxPending) {
      onDiagnostic?.call(
        'transaction.rejected reason=queue-full pending=${_pending.length}',
      );
      throw StateError('Bluetooth delivery queue is full. Try again shortly.');
    }
    final job = _Transaction(++_sequence, _epoch, operation, isCurrent);
    _pending.add(job);
    onDiagnostic?.call(
      'transaction.queued id=${job.id} pending=${_pending.length}',
    );
    _startNext();
    return await job.completion.future as T;
  }

  void reset(String reason) {
    _epoch++;
    final jobs = [?_active, ..._pending];
    _active = null;
    _pending.clear();
    for (final job in jobs) {
      if (!job.completion.isCompleted) {
        job.completion.completeError(StateError('Delivery cancelled: $reason'));
        onDiagnostic?.call('transaction.cancelled id=${job.id} reason=$reason');
      }
    }
  }

  void _startNext() {
    if (_active != null || _pending.isEmpty) return;
    final job = _pending.removeFirst();
    _active = job;
    unawaited(_execute(job));
  }

  Future<void> _execute(_Transaction job) async {
    try {
      final value = await runZoned(() async {
        checkOwnership();
        onDiagnostic?.call('transaction.started id=${job.id}');
        final value = await job.operation();
        checkOwnership();
        return value;
      }, zoneValues: {_zoneKey: job});
      if (!job.completion.isCompleted) {
        job.completion.complete(value);
        onDiagnostic?.call(
          'transaction.completed id=${job.id} ESP=unconfirmed',
        );
      }
    } on Object catch (error, stack) {
      if (!job.completion.isCompleted) {
        job.completion.completeError(error, stack);
        onDiagnostic?.call(
          'transaction.failed id=${job.id} type=${error.runtimeType}',
        );
      }
    } finally {
      if (identical(_active, job)) {
        _active = null;
        // Let the caller commit delivery bookkeeping before the next owner.
        scheduleMicrotask(_startNext);
      }
    }
  }
}

class _Transaction {
  _Transaction(this.id, this.epoch, this.operation, this.isCurrent);
  final int id;
  final int epoch;
  final Future<Object?> Function() operation;
  final bool Function()? isCurrent;
  final completion = Completer<Object?>();
}
