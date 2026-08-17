import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'background_score_refresh_dispatcher.dart';
import 'connection_screen.dart';
import 'firebase_options.dart';
import 'push_notification_service.dart';
import 'sports_data_io_data_source.dart';
import 'sports_repository.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint('Background message ID: ${message.messageId}');
  debugPrint('Background message data: ${message.data}');

  if (message.data['type'] != 'score_refresh') {
    return;
  }

  debugPrint(
    'TEMP BACKGROUND SCORE UPDATER: background FCM score_refresh received',
  );
  final completed =
      await BackgroundScoreRefreshDispatcher.dispatchScoreRefreshToMainIsolate();
  debugPrint(
    'TEMP BACKGROUND SCORE UPDATER: score_refresh completed by connected '
    'app isolate=$completed',
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  BackgroundScoreRefreshDispatcher.instance.initializeMainIsolate();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await const PushNotificationService().initializeForDevelopment();
  runApp(const SportsHubApp());
}

class SportsHubApp extends StatelessWidget {
  const SportsHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    final sportsRepository = SportsRepository(SportsDataIODataSource());

    return MaterialApp(
      title: 'Sports Hub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: ConnectionScreen(repository: sportsRepository),
    );
  }
}
