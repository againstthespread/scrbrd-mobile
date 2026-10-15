import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sports_hub_mobile/bluetooth_device_transport.dart';
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
  test('bounded timeline exports timestamped, ordered generation metadata', () {
    var now = DateTime.utc(2026, 10, 14, 12);
    final history = RefreshDiagnosticHistory(clock: () => now);
    addTearDown(history.dispose);
    for (
      var index = 0;
      index < RefreshDiagnosticHistory.capacity + 2;
      index++
    ) {
      now = now.add(const Duration(milliseconds: 1));
      history.add(
        'message $index',
        source: 'ble',
        transportId: 3,
        generation: 7,
      );
    }
    expect(history.entries, hasLength(RefreshDiagnosticHistory.capacity));
    expect(history.droppedCount, 2);
    expect(
      history.entries.first.sequence,
      RefreshDiagnosticHistory.capacity + 2,
    );
    expect(history.entries.last.message, 'message 2');
    final text = history.exportText();
    expect(text, contains('evicted=2; clears=0;'));
    expect(text, contains('[ble T3 G7] message 2'));
    expect(text.indexOf('message 2\n'), lessThan(text.indexOf('message 3\n')));
    expect(text, contains('2026-10-14T12:00:00.003Z'));
    expect(history.entries.first.elapsedMilliseconds, greaterThanOrEqualTo(0));
    history.clear();
    expect(history.entries, isEmpty);
    expect(history.droppedCount, 0);
    expect(history.exportText(), contains('clears=1;'));
  });

  test('messages are bounded and cannot inject multiline timeline entries', () {
    final history = RefreshDiagnosticHistory();
    addTearDown(history.dispose);
    history.add('first\nsecond\r${'x' * 1000}');
    expect(
      history.entries.single.message.length,
      RefreshDiagnosticHistory.maxMessageLength,
    );
    expect(history.entries.single.message, startsWith('first second '));
    expect(history.entries.single.message, isNot(contains('\n')));
  });

  test(
    'default transports share history across disposal and recreation',
    () async {
      final first = BluetoothDeviceTransport();
      final second = BluetoothDeviceTransport();
      expect(
        identical(first.diagnosticHistory, second.diagnosticHistory),
        isTrue,
      );
      final id = first.diagnosticId;
      await first.dispose();
      expect(
        second.diagnosticHistory.entries.any(
          (e) => e.transportId == id && e.message == 'transport.dispose',
        ),
        isTrue,
      );
      expect(second.diagnosticId, isNot(id));
      await second.dispose();
    },
  );

  testWidgets(
    'Developer Tools retains history across navigation and exports it',
    (tester) async {
      final history =
          RefreshDiagnosticHistory(clock: () => DateTime.utc(2026, 10, 14))
            ..add(
              'wake.raw accepted=true',
              source: 'ble',
              transportId: 1,
              generation: 2,
            );
      final session = TrackedDeviceSession();
      addTearDown(session.dispose);
      addTearDown(history.dispose);
      String? copied;
      var failCopy = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            if (failCopy) throw PlatformException(code: 'unavailable');
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      Widget tools() => DeveloperToolsScreen(
        repository: SportsRepository(_EmptyDataSource()),
        transport: _NoopTransport(),
        trackedSession: session,
        providerLabel: 'ESPN',
        pushDiagnostics: null,
        onRefreshPushDiagnostics: () async => const PushNotificationDiagnostics(
          permissionStatus: 'authorized',
          apnsToken: null,
          isApplePlatform: false,
          token: null,
        ),
        backgroundRefreshDiagnostics: history,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => tools())),
                child: const Text('Open diagnostics'),
              ),
            ),
          ),
        ),
      );
      Future<void> open() async {
        await tester.tap(find.text('Open diagnostics'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Refresh diagnostics'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
      }

      await history.trackProvider('sports:mlb', () async => 1);
      await open();
      expect(find.byKey(const ValueKey('data-freshness')), findsOneWidget);
      expect(find.textContaining('lastSuccessfulFetch='), findsOneWidget);
      expect(find.textContaining('[ble T1 G2] wake.raw'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      history.add(
        'screen retained',
        source: 'lifecycle',
        transportId: 1,
        generation: 3,
      );
      await open();
      expect(find.textContaining('[ble T1 G2] wake.raw'), findsOneWidget);
      expect(
        find.textContaining('[lifecycle T1 G3] screen retained'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('copy-refresh-diagnostics')));
      await tester.pumpAndSettle();
      expect(copied, history.exportText());
      expect(
        copied!.indexOf('wake.raw'),
        lessThan(copied!.indexOf('screen retained')),
      );
      failCopy = true;
      await tester.tap(find.byKey(const ValueKey('copy-refresh-diagnostics')));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not copy. Select the diagnostic text instead.'),
        findsOneWidget,
      );
      expect(history.entries, hasLength(3));
      await tester.tap(find.byKey(const ValueKey('clear-refresh-diagnostics')));
      await tester.pump();
      expect(find.text('No refresh diagnostics yet.'), findsOneWidget);
    },
  );
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
