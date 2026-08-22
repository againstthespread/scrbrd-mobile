import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/loaded_league_slate_sender.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/session_aware_device_sender.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  test(
    'sends three non-empty leagues in stable order and skips empty',
    () async {
      final transport = _RecordingTransport();
      final count = await LoadedLeagueSlateSender(transport: transport).send(
        {
          SportsLeague.mlb: [_game('MLB')],
          SportsLeague.nfl: [_game('NFL')],
          SportsLeague.nba: const [],
        },
        loadedGolf: _golf(),
        selectedDates: _dates,
      );

      expect(count, 3);
      expect(transport.sentLeagues, ['NFL', 'MLB', 'PGA']);
    },
  );

  test('one league failure stops the overall send', () async {
    final transport = _RecordingTransport(failingLeague: 'NBA');
    final sender = LoadedLeagueSlateSender(transport: transport);

    await expectLater(
      sender.send({
        SportsLeague.nfl: [_game('NFL')],
        SportsLeague.nba: [_game('NBA')],
        SportsLeague.mlb: [_game('MLB')],
      }, selectedDates: _dates),
      throwsA(
        isA<LeagueSlateSendException>().having(
          (error) => error.league,
          'league',
          SportsLeague.nba,
        ),
      ),
    );
    expect(transport.sentLeagues, ['NFL', 'NBA']);
  });

  test('send all records every successful league including PGA', () async {
    final raw = _RecordingTransport();
    final session = TrackedDeviceSession();
    final sender = LoadedLeagueSlateSender(
      transport: SessionAwareDeviceSender(transport: raw, session: session),
    );
    await sender.send(
      {
        SportsLeague.nfl: [_game('NFL')],
        SportsLeague.nba: [_game('NBA')],
        SportsLeague.mlb: [_game('MLB')],
      },
      loadedGolf: _golf(),
      selectedDates: _dates,
    );
    expect(session.snapshot().keys, SportsLeague.values);
  });

  test('partial failure records only successfully completed leagues', () async {
    final raw = _RecordingTransport(failingLeague: 'NBA');
    final session = TrackedDeviceSession();
    final sender = LoadedLeagueSlateSender(
      transport: SessionAwareDeviceSender(transport: raw, session: session),
    );
    await expectLater(
      sender.send(
        {
          SportsLeague.nfl: [_game('NFL')],
          SportsLeague.nba: [_game('NBA')],
          SportsLeague.mlb: [_game('MLB')],
        },
        loadedGolf: _golf(),
        selectedDates: _dates,
      ),
      throwsA(isA<LeagueSlateSendException>()),
    );
    expect(session.snapshot().keys, [SportsLeague.nfl]);
  });
}

final _dates = {
  for (final league in SportsLeague.values) league: DateTime(2026, 8, 21),
};

GameData _game(String league) {
  return GameData(
    league: league,
    awayTeam: 'AWAY',
    homeTeam: 'HOME',
    awayScore: 1,
    homeScore: 2,
    status: 'LIVE',
    clock: 'Q1',
    eventId: '$league-1',
    scheduledStartTime: DateTime(2026, 8, 21),
  );
}

GolfLeaderboard _golf() => const GolfLeaderboard(
  tournamentId: '1',
  tournamentName: 'Tournament',
  golfers: [
    GolfLeaderboardRow(playerId: '400', name: 'Golfer', rank: '1', score: '-8'),
  ],
  isInProgress: true,
  isOver: false,
);

class _RecordingTransport implements DeviceTransport {
  _RecordingTransport({this.failingLeague});

  final String? failingLeague;
  final sentLeagues = <String>[];

  @override
  Future<void> sendControlCommand(String command) async {}

  @override
  Future<void> sendGameData(GameData gameData) async {}

  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    final league = games.first.league;
    sentLeagues.add(league);
    if (league == failingLeague) {
      throw StateError('simulated failure');
    }
  }

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {
    sentLeagues.add('PGA');
    if (failingLeague == 'PGA') throw StateError('simulated failure');
  }
}
