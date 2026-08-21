import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/session_aware_device_sender.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  test('manual one-game send replaces only its own league tracking', () async {
    final session = TrackedDeviceSession()
      ..recordTeamSlate(
        league: SportsLeague.mlb,
        selectedDate: _date,
        games: [_game('MLB', 'mlb')],
      )
      ..recordGolf(_golf);
    final sender = SessionAwareDeviceSender(
      transport: _Transport(),
      session: session,
    );

    await sender.sendGameData(_game('NFL', 'nfl'));

    expect((session[SportsLeague.nfl] as TrackedTeamSlate).games, hasLength(1));
    expect(session[SportsLeague.mlb], isA<TrackedTeamSlate>());
    expect(session[SportsLeague.pga], isA<TrackedGolfLeaderboard>());
  });

  test('unsafe manual packet removes only that league baseline', () async {
    final session = TrackedDeviceSession()
      ..recordTeamSlate(
        league: SportsLeague.nfl,
        selectedDate: _date,
        games: [_game('NFL', 'old')],
      )
      ..recordGolf(_golf);
    final sender = SessionAwareDeviceSender(
      transport: _Transport(),
      session: session,
    );

    await sender.sendGameData(_game('NFL', null));

    expect(session[SportsLeague.nfl], isNull);
    expect(session[SportsLeague.pga], isA<TrackedGolfLeaderboard>());
  });

  test('failed complete transfer does not change baseline', () async {
    final old = _game('MLB', 'old');
    final session = TrackedDeviceSession()
      ..recordTeamSlate(
        league: SportsLeague.mlb,
        selectedDate: _date,
        games: [old],
      );
    final sender = SessionAwareDeviceSender(
      transport: _Transport(fail: true),
      session: session,
    );

    await expectLater(
      sender.sendTeamSlate([_game('MLB', 'new')], selectedDate: _date),
      throwsStateError,
    );
    expect(
      (session[SportsLeague.mlb] as TrackedTeamSlate).games.single,
      same(old),
    );
  });
}

final _date = DateTime(2026, 8, 21);

GameData _game(String league, String? id) => GameData(
  eventId: id,
  league: league,
  awayTeam: 'A',
  homeTeam: 'H',
  awayScore: 1,
  homeScore: 0,
  status: 'LIVE',
  clock: 'Q1',
  scheduledStartTime: _date,
);

const _golf = GolfLeaderboard(
  tournamentId: 'pga',
  tournamentName: 'Open',
  golfers: [
    GolfLeaderboardRow(playerId: '1', name: 'P', rank: '1', score: 'E'),
  ],
  isInProgress: true,
  isOver: false,
);

class _Transport implements DeviceTransport {
  _Transport({this.fail = false});
  final bool fail;
  Future<void> _send() async {
    if (fail) throw StateError('failed');
  }

  @override
  Future<void> sendGameData(GameData gameData) => _send();
  @override
  Future<void> sendGameSlate(List<GameData> games) => _send();
  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) => _send();
}
