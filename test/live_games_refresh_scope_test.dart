import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_data_source.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/live_games_screen.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  for (final league in [SportsLeague.mlb, SportsLeague.nfl, SportsLeague.nba]) {
    testWidgets('${league.label} Refresh fetches only ${league.label}', (
      tester,
    ) async {
      final teamSource = _RecordingTeamSource();
      final golfSource = _RecordingGolfSource();
      final session = TrackedDeviceSession();
      addTearDown(session.dispose);
      await _pumpScreen(tester, teamSource, golfSource, session);

      teamSource.requested.clear();
      if (league != SportsLeague.mlb) {
        await _selectLeague(tester, league);
      }
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();

      expect(teamSource.requested, [league]);
      expect(golfSource.dateFetchCount, 0);
      expect(session.snapshot(), isEmpty);
    });
  }

  testWidgets('tracked PGA is available and explicit PGA Refresh fetches PGA', (
    tester,
  ) async {
    final teamSource = _RecordingTeamSource();
    final golfSource = _RecordingGolfSource();
    final session = TrackedDeviceSession()
      ..recordGolf(_leaderboard, selectedDate: DateTime(2026, 8, 22));
    addTearDown(session.dispose);
    await _pumpScreen(tester, teamSource, golfSource, session);

    await _selectLeague(tester, SportsLeague.pga);
    teamSource.requested.clear();
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();

    expect(teamSource.requested, isEmpty);
    expect(golfSource.dateFetchCount, 1);
  });

  testWidgets('untracked PGA stays unavailable without hidden discovery', (
    tester,
  ) async {
    final teamSource = _RecordingTeamSource();
    final golfSource = _RecordingGolfSource();
    final session = TrackedDeviceSession();
    addTearDown(session.dispose);
    await _pumpScreen(tester, teamSource, golfSource, session);

    await tester.tap(find.byType(DropdownButtonFormField<SportsLeague>));
    await tester.pumpAndSettle();
    expect(find.text('PGA'), findsNothing);
    expect(golfSource.dateFetchCount, 0);
  });
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _RecordingTeamSource teamSource,
  _RecordingGolfSource golfSource,
  TrackedDeviceSession session,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: LiveGamesScreen(
        repository: SportsRepository(teamSource, golfDataSource: golfSource),
        transport: _NoopTransport(),
        trackedSession: session,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectLeague(WidgetTester tester, SportsLeague league) async {
  await tester.tap(find.byType(DropdownButtonFormField<SportsLeague>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(league.label).last);
  await tester.pumpAndSettle();
}

class _RecordingTeamSource implements SportsDataSource {
  final requested = <SportsLeague>[];

  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  ) async {
    requested.add(league);
    return [
      SportsGame(
        eventId: '${league.label}-1',
        league: league.label,
        awayTeam: 'Away',
        homeTeam: 'Home',
        awayScore: 0,
        homeScore: 0,
        status: 'UPCOMING',
        clock: '7:00 PM',
        scheduledStartTime: selectedDate,
      ),
    ];
  }
}

class _RecordingGolfSource implements GolfDataSource {
  var dateFetchCount = 0;

  @override
  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(DateTime date) async {
    dateFetchCount++;
    return _leaderboard;
  }

  @override
  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(String id) async =>
      _leaderboard;
}

const _leaderboard = GolfLeaderboard(
  tournamentId: 'pga-1',
  tournamentName: 'Test Open',
  golfers: [
    GolfLeaderboardRow(
      playerId: 'golfer-1',
      name: 'Golfer One',
      rank: '1',
      score: '-1',
      detail: 'THRU 5',
    ),
  ],
  isInProgress: true,
  isOver: false,
);

class _NoopTransport extends DeviceTransport {
  @override
  Future<void> sendControlCommand(String command) async {}

  @override
  Future<void> sendGameData(GameData gameData) async {}

  @override
  Future<void> sendGameSlate(List<GameData> games) async {}

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {}
}
