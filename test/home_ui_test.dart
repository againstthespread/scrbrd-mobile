import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/ble_device_state.dart';
import 'package:sports_hub_mobile/connection_screen.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/initial_device_sync_coordinator.dart';
import 'package:sports_hub_mobile/push_notification_service.dart';
import 'package:sports_hub_mobile/settings_screen.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  testWidgets('disconnected Home shows the primary connect action', (
    tester,
  ) async {
    await _pumpHome(tester);

    expect(find.text('SCRBRD'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Connect to SCRBRD'), findsOneWidget);
  });

  testWidgets('connected and syncing states use friendly status copy', (
    tester,
  ) async {
    await _pumpHome(
      tester,
      connectionState: BleConnectionState.connected,
      sync: const InitialSyncSnapshot(
        status: InitialSyncStatus.syncing,
        successfullySyncedLeagueCount: 2,
      ),
    );

    expect(find.text("Syncing today's sports..."), findsOneWidget);
    expect(find.text('2 leagues loaded'), findsOneWidget);
    expect(find.text('Connect to SCRBRD'), findsNothing);
    expect(find.text('Disconnect'), findsOneWidget);
  });

  testWidgets('completed and partial sync states render cleanly', (
    tester,
  ) async {
    await _pumpHome(
      tester,
      connectionState: BleConnectionState.connected,
      sync: const InitialSyncSnapshot(
        status: InitialSyncStatus.complete,
        successfullySyncedLeagueCount: 3,
      ),
    );
    expect(find.text('3 leagues synced'), findsOneWidget);

    await _pumpHome(
      tester,
      connectionState: BleConnectionState.connected,
      sync: const InitialSyncSnapshot(status: InitialSyncStatus.partialFailure),
    );
    expect(find.text("Some sports couldn't be loaded"), findsOneWidget);
  });

  testWidgets("Today's Sports reflects only TrackedDeviceSession content", (
    tester,
  ) async {
    final session = TrackedDeviceSession();
    addTearDown(session.dispose);
    session.recordTeamSlate(
      league: SportsLeague.nfl,
      selectedDate: DateTime(2026, 8, 21),
      games: [_game('NFL', 'nfl-1')],
    );
    session.recordTeamSlate(
      league: SportsLeague.mlb,
      selectedDate: DateTime(2026, 8, 21),
      games: [_game('MLB', 'mlb-1'), _game('MLB', 'mlb-2')],
    );
    session.recordGolf(
      const GolfLeaderboard(
        tournamentId: 'pga-1',
        tournamentName: 'BMW Championship',
        golfers: [
          GolfLeaderboardRow(
            playerId: '1',
            name: 'Golfer One',
            rank: '1',
            score: '-5',
          ),
        ],
        isInProgress: true,
        isOver: false,
      ),
    );

    await _pumpHome(
      tester,
      connectionState: BleConnectionState.connected,
      content: session.snapshot(),
    );

    expect(find.text("Today's Sports"), findsOneWidget);
    expect(find.text('NFL'), findsOneWidget);
    expect(find.text('1 game'), findsOneWidget);
    expect(find.text('MLB'), findsOneWidget);
    expect(find.text('2 games'), findsOneWidget);
    expect(find.text('PGA'), findsOneWidget);
    expect(find.text('BMW Championship'), findsOneWidget);
    expect(find.text('NBA'), findsNothing);
  });

  testWidgets("View Today's Games action invokes navigation callback", (
    tester,
  ) async {
    var opened = false;
    await _pumpHome(tester, onViewGames: () => opened = true);

    await tester.tap(find.text("View Today's Games"));
    expect(opened, isTrue);
  });

  testWidgets('normal Home hides developer and prototype details', (
    tester,
  ) async {
    await _pumpHome(tester);

    expect(find.textContaining('TEMP'), findsNothing);
    expect(find.textContaining('Peter Sports Hub'), findsNothing);
    expect(find.textContaining('Data provider'), findsNothing);
    expect(find.textContaining('FCM'), findsNothing);
    expect(find.textContaining('APNs'), findsNothing);
    expect(find.textContaining('Developer Tools'), findsNothing);
  });

  testWidgets('Developer Tools retains manual and diagnostic controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DeveloperToolsScreen(
          repository: SportsRepository(_EmptyDataSource()),
          transport: _NoopTransport(),
          providerLabel: 'ESPN',
          pushDiagnostics: const PushNotificationDiagnostics(
            permissionStatus: 'authorized',
            apnsToken: 'apns-token',
            isApplePlatform: true,
            token: 'fcm-token',
          ),
          onRefreshPushDiagnostics: () async =>
              const PushNotificationDiagnostics(
                permissionStatus: 'authorized',
                apnsToken: 'apns-token',
                isApplePlatform: true,
                token: 'fcm-token',
              ),
          liveActivityStatus: 'Inactive',
          onStartLiveActivity: () async {},
          onEndLiveActivity: () async {},
          backgroundRefreshStatus: 'Waiting',
        ),
      ),
    );

    expect(find.text('Games and slate tools'), findsOneWidget);
    expect(find.text('Manual game packet'), findsOneWidget);
    expect(find.text('Start Live Activity'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Push notification diagnostics'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Push notification diagnostics'), findsOneWidget);
    expect(find.text('APNs token'), findsOneWidget);
    expect(find.text('FCM token'), findsOneWidget);
  });
}

Future<void> _pumpHome(
  WidgetTester tester, {
  BleConnectionState connectionState = BleConnectionState.disconnected,
  InitialSyncSnapshot sync = const InitialSyncSnapshot(
    status: InitialSyncStatus.idle,
  ),
  Map<SportsLeague, TrackedLeagueContent> content = const {},
  VoidCallback? onViewGames,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: ScrbrdHomeView(
        snapshot: BleDeviceSnapshot(state: connectionState),
        initialSyncSnapshot: sync,
        trackedContent: content,
        onConnect: () {},
        onDisconnect: () {},
        onCandidateSelected: (_) {},
        onViewGames: onViewGames ?? () {},
        onOpenSettings: () {},
      ),
    ),
  );
}

GameData _game(String league, String eventId) => GameData(
  league: league,
  awayTeam: 'Away',
  homeTeam: 'Home',
  awayScore: 0,
  homeScore: 0,
  status: 'UPCOMING',
  clock: '7:00 PM',
  eventId: eventId,
  scheduledStartTime: DateTime(2026, 8, 21, 19),
);

class _EmptyDataSource implements SportsDataSource {
  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  ) async => const [];
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
