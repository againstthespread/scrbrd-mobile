import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/fantasy_point_delta_tracker.dart';
import 'package:sports_hub_mobile/fantasy_scoring_correlation.dart';
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

  test('fantasy alert send does not mutate tracked session', () async {
    final session = TrackedDeviceSession()
      ..recordTeamSlate(
        league: SportsLeague.nfl,
        selectedDate: _date,
        games: [_game('NFL', 'nfl')],
      )
      ..recordGolf(_golf);
    final before = session.snapshot();
    final transport = _Transport();
    final sender = SessionAwareDeviceSender(
      transport: transport,
      session: session,
    );

    await sender.sendFantasyAlert(
      _alert,
      userName: 'Peter',
      userScore: 104.7,
      opponentName: 'Mike',
      opponentScore: 97.2,
    );

    expect(transport.fantasyAlerts, 1);
    expect(session.snapshot().keys, before.keys);
    expect(session[SportsLeague.nfl], same(before[SportsLeague.nfl]));
    expect(session[SportsLeague.pga], same(before[SportsLeague.pga]));
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
  int fantasyAlerts = 0;
  @override
  Future<void> sendControlCommand(String command) => _send();
  Future<void> _send() async {
    if (fail) throw StateError('failed');
  }

  @override
  Future<void> sendGameData(GameData gameData) => _send();
  @override
  Future<void> sendGameSlate(List<GameData> games) => _send();
  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) => _send();
  @override
  Future<void> sendFantasyAlert(
    FantasyScoringEvent event, {
    required String userName,
    required double userScore,
    required String opponentName,
    required double opponentScore,
  }) async {
    fantasyAlerts++;
    await _send();
  }
}

const _alert = FantasyScoringEvent(
  delta: FantasyPointDelta(
    playerId: '1',
    side: FantasyMatchupSide.user,
    previousPoints: 0,
    currentPoints: 12,
    delta: 12,
  ),
  player: null,
  matchedPlay: null,
  confidence: FantasyCorrelationConfidence.none,
  explanation: null,
  predictedPoints: null,
  diagnostic: 'test',
);
