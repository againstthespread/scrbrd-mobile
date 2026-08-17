import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

class PushNotificationService {
  const PushNotificationService({FirebaseMessaging? messaging})
    : messagingOverride = messaging;

  final FirebaseMessaging? messagingOverride;

  Future<void> initializeForDevelopment() async {
    final messaging = messagingOverride ?? FirebaseMessaging.instance;

    try {
      final settings = await messaging.requestPermission();
      debugPrint(
        'FCM notification permission status: '
        '${settings.authorizationStatus.name}',
      );

      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('FCM registration token not requested: permission denied.');
        return;
      }

      if (_isApplePlatform) {
        final apnsToken = await messaging.getAPNSToken();
        if (apnsToken == null || apnsToken.isEmpty) {
          debugPrint(
            'FCM registration token not requested: APNs token unavailable.',
          );
          return;
        }

        debugPrint('APNs token: $apnsToken');
      }

      final token = await messaging.getToken();
      if (token == null || token.isEmpty) {
        debugPrint('FCM registration token unavailable.');
        return;
      }

      debugPrint('FCM registration token: $token');
    } on Object catch (error) {
      debugPrint('FCM development setup failed: $error');
    }
  }

  Future<PushNotificationDiagnostics> readDiagnostics() async {
    try {
      final messaging = messagingOverride ?? FirebaseMessaging.instance;
      final settings = await messaging.getNotificationSettings();
      String? apnsToken;
      if (_isApplePlatform) {
        final retrievedAPNSToken = await messaging.getAPNSToken();
        if (retrievedAPNSToken != null && retrievedAPNSToken.isNotEmpty) {
          apnsToken = retrievedAPNSToken;
        }
      }

      final token = !_isApplePlatform || apnsToken != null
          ? await messaging.getToken()
          : null;
      return PushNotificationDiagnostics(
        permissionStatus: settings.authorizationStatus.name,
        apnsToken: apnsToken,
        isApplePlatform: _isApplePlatform,
        token: token == null || token.isEmpty ? null : token,
      );
    } on Object catch (error) {
      return PushNotificationDiagnostics(
        permissionStatus: 'unknown',
        apnsToken: null,
        isApplePlatform: _isApplePlatform,
        token: null,
        errorMessage: error.toString(),
      );
    }
  }

  bool get _isApplePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);
}

class PushNotificationDiagnostics {
  const PushNotificationDiagnostics({
    required this.permissionStatus,
    required this.apnsToken,
    required this.isApplePlatform,
    required this.token,
    this.errorMessage,
  });

  final String permissionStatus;
  final String? apnsToken;
  final bool isApplePlatform;
  final String? token;
  final String? errorMessage;

  String get apnsTokenStatus => isApplePlatform
      ? apnsToken ?? 'APNs token unavailable'
      : 'Not applicable on this platform';

  String get tokenStatus => token ?? 'FCM token unavailable';
}
