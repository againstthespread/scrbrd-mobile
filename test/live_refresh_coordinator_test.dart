import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_data_source.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/live_refresh_coordinator.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  test('one wake checks MLB and PGA and sends only changed PGA', () async {
    final team = _Source({
      SportsLeague.mlb: [_game('MLB', '1', 1)],
    });
    final golf = _GolfSource(_golf('-2'));
    final session = _session(teamScore: 1, golfScore: '-1');
    final transport = _Transport();
    final coordinator = _coordinator(team, golf, session, transport);

    await coordinator.refreshTrackedSessionOnce();

    expect(team.requested, [SportsLeague.mlb]);
    expect(golf.fetchCount, 1);
    expect(transport.slates, isEmpty);
    expect(transport.golf, hasLength(1));
  });

  test('change in non-first and final slate game sends full slate', () async {
    final old = List.generate(15, (i) => _game('MLB', '$i', 0));
    final fresh = List<GameData>.of(old);
    fresh[14] = _game('MLB', '14', 1);
    final source = _Source({SportsLeague.mlb: fresh});
    final session = TrackedDeviceSession()
      ..recordTeamSlate(
        league: SportsLeague.mlb,
        selectedDate: _date,
        games: old,
      );
    final transport = _Transport();

    await _coordinator(
      source,
      _GolfSource(_golf('-1')),
      session,
      transport,
    ).refreshTrackedSessionOnce();

    expect(transport.slates.single, hasLength(15));
    expect(
      (session[SportsLeague.mlb] as TrackedTeamSlate).games.last.awayScore,
      1,
    );
  });

  test(
    'empty/failing league preserves baseline and later league continues',
    () async {
      final source = _Source({
        SportsLeague.nfl: const [],
        SportsLeague.mlb: [_game('MLB', '1', 2)],
      });
      final session = TrackedDeviceSession()
        ..recordTeamSlate(
          league: SportsLeague.nfl,
          selectedDate: _date,
          games: [_game('NFL', '1', 1)],
        )
        ..recordTeamSlate(
          league: SportsLeague.mlb,
          selectedDate: _date,
          games: [_game('MLB', '1', 1)],
        );
      final transport = _Transport();

      await _coordinator(
        source,
        _GolfSource(_golf('-1')),
        session,
        transport,
      ).refreshTrackedSessionOnce();

      expect(transport.slates.single.first.league, 'MLB');
      expect(
        (session[SportsLeague.nfl] as TrackedTeamSlate).games.single.awayScore,
        1,
      );
    },
  );

  test('foreground needs no Live Activity; background does', () async {
    final source = _Source({
      SportsLeague.mlb: [_game('MLB', '1', 2)],
    });
    final session = _session(teamScore: 1, golfScore: null);
    final foreground = _Transport();
    await _coordinator(
      source,
      _GolfSource(_golf('-1')),
      session,
      foreground,
      background: false,
      liveActivity: false,
    ).refreshTrackedSessionOnce();
    expect(foreground.slates, hasLength(1));

    final background = _Transport();
    await _coordinator(
      source,
      _GolfSource(_golf('-1')),
      session,
      background,
      background: true,
      liveActivity: false,
    ).refreshTrackedSessionOnce();
    expect(background.slates, isEmpty);
  });

  test('overlapping wakes are globally suppressed', () async {
    final pending = Completer<List<GameData>>();
    final source = _Source({})..pending = pending;
    final diagnostics = <String>[];
    final coordinator = _coordinator(
      source,
      _GolfSource(_golf('-1')),
      _session(teamScore: 1, golfScore: null),
      _Transport(),
      diagnostics: diagnostics.add,
    );
    final first = coordinator.refreshTrackedSessionOnce();
    await Future<void>.delayed(Duration.zero);
    await coordinator.refreshTrackedSessionOnce();
    pending.complete([_game('MLB', '1', 1)]);
    await first;
    expect(
      diagnostics,
      contains('refresh skipped because another refresh is in progress'),
    );
  });
}

final _date = DateTime(2026, 8, 21);

TrackedDeviceSession _session({
  required int teamScore,
  required String? golfScore,
}) {
  final session = TrackedDeviceSession()
    ..recordTeamSlate(
      league: SportsLeague.mlb,
      selectedDate: _date,
      games: [_game('MLB', '1', teamScore)],
    );
  if (golfScore != null) session.recordGolf(_golf(golfScore));
  return session;
}

LiveRefreshCoordinator _coordinator(
  _Source source,
  _GolfSource golf,
  TrackedDeviceSession session,
  _Transport transport, {
  bool background = false,
  bool liveActivity = true,
  void Function(String)? diagnostics,
}) => LiveRefreshCoordinator(
  repository: SportsRepository(source, golfDataSource: golf),
  transport: transport,
  session: session,
  isAppBackgrounded: () => background,
  isBleConnected: () => true,
  isLiveActivityActive: () async => liveActivity,
  onDiagnostic: diagnostics,
);

GameData _game(String league, String id, int score) => GameData(
  eventId: id,
  league: league,
  awayTeam: 'A',
  homeTeam: 'H',
  awayScore: score,
  homeScore: 0,
  status: 'LIVE',
  clock: 'Top 5th',
  scheduledStartTime: _date,
);

GolfLeaderboard _golf(String score) => GolfLeaderboard(
  tournamentId: 'pga-1',
  tournamentName: 'Open',
  golfers: [
    GolfLeaderboardRow(playerId: '1', name: 'Player', rank: '1', score: score),
  ],
  isInProgress: true,
  isOver: false,
);

class _Source implements SportsDataSource {
  _Source(this.responses);
  final Map<SportsLeague, List<GameData>> responses;
  final requested = <SportsLeague>[];
  Completer<List<GameData>>? pending;
  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime date,
  ) async {
    requested.add(league);
    final games = pending == null
        ? responses[league] ?? const []
        : await pending!.future;
    return games
        .map(
          (g) => SportsGame(
            eventId: g.eventId,
            league: g.league,
            awayTeam: g.awayTeam,
            homeTeam: g.homeTeam,
            awayScore: g.awayScore,
            homeScore: g.homeScore,
            status: g.status,
            clock: g.clock,
            scheduledStartTime: g.scheduledStartTime,
            baseballState: g.baseballState,
          ),
        )
        .toList();
  }
}

class _GolfSource implements GolfDataSource {
  _GolfSource(this.response);
  final GolfLeaderboard response;
  int fetchCount = 0;
  @override
  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(String id) async {
    fetchCount++;
    return response;
  }

  @override
  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(DateTime date) async =>
      response;
}

class _Transport implements DeviceTransport {
  final slates = <List<GameData>>[];
  final golf = <GolfLeaderboard>[];
  @override
  Future<void> sendGameData(GameData gameData) async {}
  @override
  Future<void> sendGameSlate(List<GameData> games) async => slates.add(games);
  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async =>
      golf.add(leaderboard);
}
