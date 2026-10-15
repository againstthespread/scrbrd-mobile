import 'dart:async';

import 'package:reactive_ble_platform_interface/reactive_ble_platform_interface.dart';

/// A single-listener WAKE stream whose cancel future includes native cleanup.
/// The pinned plugin's broadcast Repeater does not provide this barrier.
/// A timeout belongs to the caller: it must not release this actual barrier.
Stream<List<int>> acknowledgedWakeStream({
  required Future<CharacteristicInstance> Function() resolve,
  required Stream<CharacteristicValue> values,
  required Future<void> Function(CharacteristicInstance) enable,
  required Future<void> Function(CharacteristicInstance) disable,
  required bool Function() isCurrent,
  required void Function(String) trace,
}) {
  late final StreamController<List<int>> controller;
  Future<void>? setup;
  StreamSubscription<CharacteristicValue>? valueSubscription;
  CharacteristicInstance? instance;
  var cancelled = false;
  var enableStarted = false;

  Future<void> start() async {
    try {
      final resolved = await resolve();
      if (cancelled || !isCurrent()) return;
      instance = resolved;
      valueSubscription = values.listen(
        (update) {
          if (cancelled || update.characteristic != resolved) return;
          try {
            controller.add(update.result.dematerialize());
          } on Object catch (error, stack) {
            controller.addError(error, stack);
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!cancelled) controller.addError(error, stack);
        },
        onDone: () {
          if (!cancelled) unawaited(controller.close());
        },
      );
      enableStarted = true;
      trace('subscription.native-enable start');
      await enable(resolved);
      trace('subscription.native-enable completed');
    } on Object catch (error, stack) {
      trace('subscription.native-enable failed type=${error.runtimeType}');
      if (!cancelled) controller.addError(error, stack);
    }
  }

  controller = StreamController<List<int>>(
    onListen: () => setup = start(),
    onCancel: () async {
      cancelled = true;
      // Even cancellation during enable must wait for its result before off.
      await setup;
      try {
        await valueSubscription?.cancel();
      } finally {
        if (enableStarted) {
          trace('subscription.native-disable start');
          try {
            await disable(instance!);
            trace('subscription.native-disable completed');
          } on Object catch (error) {
            trace(
              'subscription.native-disable failed type=${error.runtimeType}',
            );
            rethrow;
          }
        }
      }
    },
  );
  return controller.stream;
}
