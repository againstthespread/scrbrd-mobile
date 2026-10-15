import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/logical_device_transaction.dart';

void main() {
  test(
    'F29 nested transaction retains ownership until every packet finishes',
    () async {
      final queue = LogicalDeviceTransactionQueue();
      final release = Completer<void>();
      final order = <String>[];
      final first = queue.run(() async {
        order.add('start');
        await release.future;
        await queue.run(() async => order.add('chunk'));
        order.add('end');
      });
      final next = queue.run(() async => order.add('manual'));
      expect(order, ['start']);
      release.complete();
      await Future.wait([first, next]);
      expect(order, ['start', 'chunk', 'end', 'manual']);
    },
  );

  test(
    'F29 queue is bounded and excess explicit work fails truthfully',
    () async {
      final queue = LogicalDeviceTransactionQueue(maxPending: 2);
      final release = Completer<void>();
      final active = queue.run(() => release.future);
      final second = queue.run(() async => 2);
      final third = queue.run(() async => 3);
      await expectLater(queue.run(() async => 4), throwsStateError);
      release.complete();
      await active;
      expect(await second, 2);
      expect(await third, 3);
    },
  );

  test(
    'F29 reset cancels active and queued work without waiting for native completion',
    () async {
      final queue = LogicalDeviceTransactionQueue();
      final native = Completer<void>();
      var staleWrote = false;
      var queuedWrote = false;
      final active = queue.run(() async {
        await native.future;
        await queue.run(() async => staleWrote = true);
      });
      final pending = queue.run(() async => queuedWrote = true);
      final cancelled = expectLater(active, throwsStateError);
      final rejected = expectLater(pending, throwsStateError);
      queue.reset('disconnect');
      await Future.wait([cancelled, rejected]);
      expect(await queue.run(() async => 'reconnected'), 'reconnected');
      native.complete();
      await Future<void>.delayed(Duration.zero);
      expect(staleWrote, isFalse);
      expect(queuedWrote, isFalse);
    },
  );

  test(
    'F29 late inherited callbacks cannot acquire another owner lease',
    () async {
      final queue = LogicalDeviceTransactionQueue();
      final callback = Completer<void>();
      late Future<void> lateWork;
      var wrote = false;
      await queue.run(() async {
        lateWork = callback.future.then(
          (_) => queue.run(() async {
            wrote = true;
          }),
        );
      });
      final rejected = expectLater(lateWork, throwsStateError);
      await queue.run(() async {
        callback.complete();
      });
      await rejected;
      expect(wrote, isFalse);
    },
  );

  test(
    'F29 superseded pending work is checked at admission and does not write',
    () async {
      final queue = LogicalDeviceTransactionQueue();
      final release = Completer<void>();
      var current = true;
      var writes = 0;
      final active = queue.run(() => release.future);
      final stale = queue.run(() async {
        writes++;
      }, isCurrent: () => current);
      final cancelled = expectLater(stale, throwsStateError);
      current = false;
      release.complete();
      await active;
      await cancelled;
      await queue.run(() async {
        writes++;
      });
      expect(writes, 1);
    },
  );

  test(
    'F29 a failed transaction releases the next owner and supports retry',
    () async {
      final queue = LogicalDeviceTransactionQueue();
      final failed = queue.run(() async => throw StateError('write failed'));
      final rejected = expectLater(failed, throwsStateError);
      final next = queue.run(() async => 'manual');
      await rejected;
      expect(await next, 'manual');
      expect(await queue.run(() async => 'retry'), 'retry');
    },
  );
}
