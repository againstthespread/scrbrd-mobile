import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'connection_screen.dart';
import 'firebase_options.dart';
import 'push_notification_service.dart';
import 'sports_data_io_data_source.dart';
import 'sports_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
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
