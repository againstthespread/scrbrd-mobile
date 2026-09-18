import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/push_notification_service.dart';
import 'package:sports_hub_mobile/refresh_diagnostic_history.dart';
import 'package:sports_hub_mobile/settings_screen.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  test('history retains newest-first timestamped entries and caps at 20', () {
    var second = 0;
    final history = RefreshDiagnosticHistory(
      clock: () => DateTime(2026, 9, 18, 13, 14, second++),
    );

    for (var index = 0; index < 21; index++) {
      history.add('message $index');
    }

    expect(history.entries, hasLength(20));
    expect(history.entries.first.message, 'message 20');
    expect(history.entries.last.message, 'message 1');
    expect(history.entries.first.displayText, '1:14:20 PM — message 20');
  });

  testWidgets('Developer Tools displays and clears refresh diagnostics', (
    tester,
  ) async {
    final history = RefreshDiagnosticHistory(
      clock: () => DateTime(2026, 9, 18, 13, 14, 2),
    )..add('BLE WAKE received; lifecycle=paused; BLE connected=true');
    final session = TrackedDeviceSession();
    addTearDown(session.dispose);
    addTearDown(history.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: DeveloperToolsScreen(
          repository: SportsRepository(_EmptyDataSource()),
          transport: _NoopTransport(),
          trackedSession: session,
          providerLabel: 'ESPN',
          pushDiagnostics: null,
          onRefreshPushDiagnostics: () async =>
              const PushNotificationDiagnostics(
                permissionStatus: 'authorized',
                apnsToken: null,
                isApplePlatform: false,
                token: null,
              ),
          backgroundRefreshDiagnostics: history,
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('Refresh diagnostics'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.textContaining('1:14:02 PM — BLE WAKE received'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('clear-refresh-diagnostics')));
    await tester.pump();
    expect(find.text('No refresh diagnostics yet.'), findsOneWidget);
  });
}

class _EmptyDataSource implements SportsDataSource {
  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  ) async => [];
}

class _NoopTransport implements DeviceTransport {
  @override
  Future<void> sendControlCommand(String command) async {}

  @override
  Future<void> sendGameData(GameData gameData) async {}

  @override
  Future<void> sendGameSlate(List<GameData> games) async {}

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {}
}
