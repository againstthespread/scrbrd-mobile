import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/push_notification_service.dart';

void main() {
  late List<String> logs;
  late DebugPrintCallback originalDebugPrint;

  setUp(() {
    logs = [];
    originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });
  tearDown(() {
    debugPrint = originalDebugPrint;
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'registration requests permission and tokens without logging their values',
    () async {
      final messaging = _Messaging();
      await PushNotificationService(
        messaging: messaging,
      ).initializeForDevelopment();

      expect(messaging.calls, ['permission', 'apns', 'fcm']);
      expect(logs.join('\n'), contains('APNs token available=true'));
      expect(
        logs.join('\n'),
        contains('FCM registration token available=true'),
      );
      expect(logs.join('\n'), isNot(contains(_Messaging.apnsSecret)));
      expect(logs.join('\n'), isNot(contains(_Messaging.fcmSecret)));
    },
  );

  test('denied permission still prevents token requests', () async {
    final messaging = _Messaging()..authorization = AuthorizationStatus.denied;
    await PushNotificationService(
      messaging: messaging,
    ).initializeForDevelopment();
    expect(messaging.calls, ['permission']);
  });

  test('missing APNs token still prevents FCM token request', () async {
    final messaging = _Messaging()..apns = null;
    await PushNotificationService(
      messaging: messaging,
    ).initializeForDevelopment();
    expect(messaging.calls, ['permission', 'apns']);
  });

  test(
    'registration errors cannot echo credentials into console logs',
    () async {
      final messaging = _Messaging()..failToken = true;
      await PushNotificationService(
        messaging: messaging,
      ).initializeForDevelopment();
      expect(logs.join('\n'), contains('FCM setup failed: StateError'));
      expect(logs.join('\n'), isNot(contains(_Messaging.fcmSecret)));
    },
  );

  test(
    'intentional Developer Tools token diagnostics remain available',
    () async {
      final messaging = _Messaging();
      final diagnostics = await PushNotificationService(
        messaging: messaging,
      ).readDiagnostics();
      expect(diagnostics.token, _Messaging.fcmSecret);
      expect(diagnostics.apnsToken, _Messaging.apnsSecret);
      expect(logs, isEmpty);
    },
  );
}

class _Settings extends Fake implements NotificationSettings {
  _Settings(this.authorizationStatus);
  @override
  final AuthorizationStatus authorizationStatus;
}

class _Messaging extends Fake implements FirebaseMessaging {
  static const apnsSecret = 'test-apns-secret-not-for-console';
  static const fcmSecret = 'test-fcm-secret-not-for-console';
  final calls = <String>[];
  String? apns = apnsSecret;
  bool failToken = false;
  AuthorizationStatus authorization = AuthorizationStatus.authorized;

  @override
  Future<NotificationSettings> requestPermission({
    bool alert = true,
    bool announcement = false,
    bool badge = true,
    bool carPlay = false,
    bool criticalAlert = false,
    bool provisional = false,
    bool sound = true,
    bool providesAppNotificationSettings = false,
  }) async {
    calls.add('permission');
    return _Settings(authorization);
  }

  @override
  Future<NotificationSettings> getNotificationSettings() async =>
      _Settings(authorization);

  @override
  Future<String?> getAPNSToken() async {
    calls.add('apns');
    return apns;
  }

  @override
  Future<String?> getToken({
    String? vapidKey,
    String? serviceWorkerScriptPath,
  }) async {
    calls.add('fcm');
    if (failToken) throw StateError(fcmSecret);
    return fcmSecret;
  }
}
