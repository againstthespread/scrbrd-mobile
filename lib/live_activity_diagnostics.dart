import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// TEMPORARY LIVE ACTIVITY/BACKGROUND BLE DIAGNOSTICS: Remove after iOS testing.
class LiveActivityDiagnostics {
  static const _channel = MethodChannel(
    'com.againstthespread.scrbrd/live_activity_diagnostics',
  );

  bool get _isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<String> start() async {
    if (!_isSupportedPlatform) {
      return 'Live Activities are available only on iOS.';
    }

    debugPrint('TEMP LIVE ACTIVITY DIAGNOSTIC: start attempt');
    try {
      final activityId = await _channel.invokeMethod<String>(
        'startScrbrdLiveActivity',
      );
      final message = activityId == null
          ? 'Live Activity start returned no Activity ID.'
          : 'Live Activity started: $activityId';
      debugPrint('TEMP LIVE ACTIVITY DIAGNOSTIC: $message');
      return message;
    } on Object catch (error, stackTrace) {
      debugPrint('TEMP LIVE ACTIVITY DIAGNOSTIC: start failed: $error');
      debugPrint('TEMP LIVE ACTIVITY DIAGNOSTIC: $stackTrace');
      return 'Live Activity start failed: $error';
    }
  }

  Future<String> end() async {
    if (!_isSupportedPlatform) {
      return 'Live Activities are available only on iOS.';
    }

    try {
      await _channel.invokeMethod<void>('endScrbrdLiveActivity');
      const message = 'Live Activity ended.';
      debugPrint('TEMP LIVE ACTIVITY DIAGNOSTIC: $message');
      return message;
    } on Object catch (error, stackTrace) {
      debugPrint('TEMP LIVE ACTIVITY DIAGNOSTIC: end failed: $error');
      debugPrint('TEMP LIVE ACTIVITY DIAGNOSTIC: $stackTrace');
      return 'Live Activity end failed: $error';
    }
  }

  Future<bool> isActive() async {
    if (!_isSupportedPlatform) {
      return false;
    }

    return await _channel.invokeMethod<bool>('isScrbrdLiveActivityActive') ??
        false;
  }
}
