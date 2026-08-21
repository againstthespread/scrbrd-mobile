import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  test('NFL NBA MLB and PGA coexist and replacements affect one league', () {
    final session = TrackedDeviceSession();
    final date = DateTime(2026, 8, 21, 18);
    for (final league in [
      SportsLeague.nfl,
      SportsLeague.nba,
      SportsLeague.mlb,
    ]) {
      session.recordTeamSlate(
        league: league,
        selectedDate: date,
        games: [_game(league, '1'), _game(league, '2')],
      );
    }
    session.recordGolf(_golf);

    expect(session.snapshot().keys, SportsLeague.values);
    final mlb = session[SportsLeague.mlb] as TrackedTeamSlate;
    expect(mlb.games, hasLength(2));
    expect(mlb.selectedDate, DateTime(2026, 8, 21));

    session.recordTeamSlate(
      league: SportsLeague.mlb,
      selectedDate: date,
      games: [_game(SportsLeague.mlb, 'new')],
    );
    expect(
      (session[SportsLeague.mlb] as TrackedTeamSlate).games.single.eventId,
      'new',
    );
    expect(session[SportsLeague.nfl], isA<TrackedTeamSlate>());
    expect(session[SportsLeague.nba], isA<TrackedTeamSlate>());
    expect(session[SportsLeague.pga], isA<TrackedGolfLeaderboard>());
  });

  test('stored slate collection is immutable', () {
    final source = [_game(SportsLeague.mlb, '1')];
    final session = TrackedDeviceSession()
      ..recordTeamSlate(
        league: SportsLeague.mlb,
        selectedDate: DateTime(2026, 8, 21),
        games: source,
      );
    source.add(_game(SportsLeague.mlb, '2'));
    final tracked = session[SportsLeague.mlb] as TrackedTeamSlate;
    expect(tracked.games, hasLength(1));
    expect(
      () => tracked.games.add(_game(SportsLeague.mlb, '3')),
      throwsUnsupportedError,
    );
  });
}

GameData _game(SportsLeague league, String id) => GameData(
  league: league.label,
  eventId: id,
  awayTeam: 'A',
  homeTeam: 'H',
  awayScore: 1,
  homeScore: 2,
  status: 'LIVE',
  clock: 'Q1',
  scheduledStartTime: DateTime(2026, 8, 21),
);

const _golf = GolfLeaderboard(
  tournamentId: 'pga-1',
  tournamentName: 'Open',
  golfers: [
    GolfLeaderboardRow(playerId: '1', name: 'Player', rank: '1', score: '-1'),
  ],
  isInProgress: true,
  isOver: false,
);
