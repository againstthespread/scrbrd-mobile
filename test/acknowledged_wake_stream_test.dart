import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_ble_platform_interface/reactive_ble_platform_interface.dart';
import 'package:sports_hub_mobile/acknowledged_wake_stream.dart';

final _instance = CharacteristicInstance(
  characteristicId: Uuid.parse('d8f6a9b2-7a5e-4e8c-9f2a-2b2f5b6c1001'),
  characteristicInstanceId: 'wake',
  serviceId: Uuid.parse('d8f6a9b0-7a5e-4e8c-9f2a-2b2f5b6c1001'),
  serviceInstanceId: 'service',
  deviceId: 'esp2',
);

void main() {
  test(
    'H01 cancel waits for native enable then native disable completion',
    () async {
      final enabled = Completer<void>(), disabled = Completer<void>();
      final events = <String>[];
      final values = StreamController<CharacteristicValue>.broadcast();
      final listener = acknowledgedWakeStream(
        resolve: () async => _instance,
        values: values.stream,
        enable: (_) {
          events.add('enable');
          return enabled.future;
        },
        disable: (_) {
          events.add('disable');
          return disabled.future;
        },
        isCurrent: () => true,
        trace: (_) {},
      ).listen((_) {});
      await Future<void>.delayed(Duration.zero);
      var cancelled = false;
      final cleanup = listener.cancel().then((_) => cancelled = true);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['enable']);
      expect(cancelled, isFalse);
      enabled.complete();
      await Future<void>.delayed(Duration.zero);
      expect(events, ['enable', 'disable']);
      expect(cancelled, isFalse);
      disabled.complete();
      await cleanup;
      expect(cancelled, isTrue);
      await values.close();
    },
  );

  test(
    'H01 stale resolution cannot enable notifications on replacement connection',
    () async {
      final resolved = Completer<CharacteristicInstance>();
      var current = true, enabled = false, disabled = false;
      final values = StreamController<CharacteristicValue>.broadcast();
      final listener = acknowledgedWakeStream(
        resolve: () => resolved.future,
        values: values.stream,
        enable: (_) async {
          enabled = true;
        },
        disable: (_) async {
          disabled = true;
        },
        isCurrent: () => current,
        trace: (_) {},
      ).listen((_) {});
      current = false;
      final cleanup = listener.cancel();
      resolved.complete(_instance);
      await cleanup;
      expect(enabled, isFalse);
      expect(disabled, isFalse);
      await values.close();
    },
  );

  test(
    'H01 native enable ack differs from value receipt and filters characteristic',
    () async {
      final trace = <String>[], received = <List<int>>[];
      final values = StreamController<CharacteristicValue>.broadcast();
      final listener = acknowledgedWakeStream(
        resolve: () async => _instance,
        values: values.stream,
        enable: (_) async {},
        disable: (_) async {},
        isCurrent: () => true,
        trace: trace.add,
      ).listen(received.add);
      await Future<void>.delayed(Duration.zero);
      expect(trace, contains('subscription.native-enable completed'));
      expect(received, isEmpty);
      values.add(
        CharacteristicValue(
          characteristic: CharacteristicInstance(
            characteristicId: _instance.characteristicId,
            characteristicInstanceId: 'other',
            serviceId: _instance.serviceId,
            serviceInstanceId: 'service',
            deviceId: 'esp2',
          ),
          result: const Result.success([1]),
        ),
      );
      values.add(
        CharacteristicValue(
          characteristic: _instance,
          result: const Result.success([87, 65, 75, 69]),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, [
        [87, 65, 75, 69],
      ]);
      await listener.cancel();
      expect(trace, contains('subscription.native-disable completed'));
      await values.close();
    },
  );

  test(
    'H01 native disable failure is propagated to the replacement barrier',
    () async {
      final values = StreamController<CharacteristicValue>.broadcast();
      final listener = acknowledgedWakeStream(
        resolve: () async => _instance,
        values: values.stream,
        enable: (_) async {},
        disable: (_) async {
          throw StateError('native off failed');
        },
        isCurrent: () => true,
        trace: (_) {},
      ).listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await expectLater(listener.cancel(), throwsStateError);
      await values.close();
    },
  );
}
