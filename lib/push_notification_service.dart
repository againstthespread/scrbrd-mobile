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
      final token = await messaging.getToken();
      return PushNotificationDiagnostics(
        permissionStatus: settings.authorizationStatus.name,
        token: token == null || token.isEmpty ? null : token,
      );
    } on Object catch (error) {
      return PushNotificationDiagnostics(
        permissionStatus: 'unknown',
        token: null,
        errorMessage: error.toString(),
      );
    }
  }
}

class PushNotificationDiagnostics {
  const PushNotificationDiagnostics({
    required this.permissionStatus,
    required this.token,
    this.errorMessage,
  });

  final String permissionStatus;
  final String? token;
  final String? errorMessage;

  String get tokenStatus => token ?? 'FCM token unavailable';
}
