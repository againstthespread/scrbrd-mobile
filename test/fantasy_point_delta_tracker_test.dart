import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/fantasy_point_delta_tracker.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';

void main() {
  late FantasyPointDeltaTracker tracker;

  setUp(() => tracker = FantasyPointDeltaTracker());

  test('first snapshot establishes baseline with zero events', () {
    final result = tracker.observe(_matchup());
    expect(result.events, isEmpty);
    expect(result.baselineReset, isTrue);
  });

  test('unchanged second snapshot produces zero events', () {
    tracker.observe(_matchup());
    expect(tracker.observe(_matchup()).events, isEmpty);
  });

  test('one starter gain produces one positive delta', () {
    tracker.observe(_matchup());
    final result = tracker.observe(_matchup(userPoints: {'u1': 26.3, 'u2': 5}));
    expect(result.events, hasLength(1));
    expect(result.events.single.playerId, 'u1');
    expect(result.events.single.delta, 12);
  });

  test('one starter loss produces one negative delta', () {
    tracker.observe(_matchup(userPoints: {'u1': 26.3, 'u2': 5}));
    final event = tracker.observe(_matchup()).events.single;
    expect(event.delta, -12);
    expect(event.previousPoints, 26.3);
    expect(event.currentPoints, 14.3);
  });

  test('fractional scoring is preserved', () {
    tracker.observe(_matchup());
    final event = tracker
        .observe(_matchup(userPoints: {'u1': 14.8, 'u2': 5}))
        .events
        .single;
    expect(event.delta, 0.5);
  });

  test('floating-point noise produces no event', () {
    tracker.observe(_matchup());
    final result = tracker.observe(
      _matchup(userPoints: {'u1': 14.3000000003, 'u2': 5}),
    );
    expect(result.events, isEmpty);
  });

  test('multiple user starter changes preserve starter order', () {
    tracker.observe(_matchup());
    final events = tracker
        .observe(_matchup(userPoints: {'u1': 20.3, 'u2': 8}))
        .events;
    expect(events.map((event) => event.playerId), ['u1', 'u2']);
  });

  test('user and opponent changes identify the correct side', () {
    tracker.observe(_matchup());
    final events = tracker
        .observe(
          _matchup(
            userPoints: {'u1': 20.3, 'u2': 5},
            opponentPoints: {'o1': 20, 'o2': 6},
          ),
        )
        .events;
    expect(events.map((event) => event.side), [
      FantasyMatchupSide.user,
      FantasyMatchupSide.opponent,
    ]);
  });

  test('bench player point changes are ignored', () {
    tracker.observe(_matchup(userBenchPoints: 1));
    final result = tracker.observe(_matchup(userBenchPoints: 20));
    expect(result.events, isEmpty);
  });

  test('newly inserted starter establishes its own baseline', () {
    tracker.observe(_matchup(userStarters: const ['u1']));
    final result = tracker.observe(
      _matchup(
        userStarters: const ['u1', 'u3'],
        userPoints: {'u1': 14.3, 'u3': 20},
      ),
    );
    expect(result.events, isEmpty);
  });

  test('removed starter does not produce a negative event', () {
    tracker.observe(_matchup());
    final result = tracker.observe(
      _matchup(userStarters: const ['u1'], userPoints: {'u1': 14.3}),
    );
    expect(result.events, isEmpty);
  });

  test('temporarily missing point value produces no zero delta', () {
    tracker.observe(_matchup());
    final result = tracker.observe(_matchup(userPoints: {'u2': 5}));
    expect(result.events, isEmpty);
  });

  test('returning point value compares with last reliable baseline', () {
    tracker.observe(_matchup());
    tracker.observe(_matchup(userPoints: {'u2': 5}));
    final event = tracker
        .observe(_matchup(userPoints: {'u1': 16.3, 'u2': 5}))
        .events
        .single;
    expect(event.playerId, 'u1');
    expect(event.previousPoints, 14.3);
    expect(event.delta, 2);
  });

  test('week change resets baseline', () {
    tracker.observe(_matchup());
    final result = tracker.observe(
      _matchup(week: 9, userPoints: {'u1': 0, 'u2': 0}),
    );
    expect(result.events, isEmpty);
    expect(result.baselineReset, isTrue);
  });

  test('league change resets baseline', () {
    tracker.observe(_matchup());
    final result = tracker.observe(
      _matchup(leagueId: 'other', userPoints: {'u1': 0, 'u2': 0}),
    );
    expect(result.events, isEmpty);
    expect(result.baselineReset, isTrue);
  });

  test('opponent identity change resets baseline', () {
    tracker.observe(_matchup());
    final result = tracker.observe(
      _matchup(
        opponentRosterId: 3,
        matchupId: 10,
        opponentPoints: {'o1': 0, 'o2': 0},
      ),
    );
    expect(result.events, isEmpty);
    expect(result.baselineReset, isTrue);
  });

  test('large legitimate positive delta is preserved', () {
    tracker.observe(_matchup());
    final event = tracker
        .observe(_matchup(userPoints: {'u1': 64.3, 'u2': 5}))
        .events
        .single;
    expect(event.delta, 50);
  });

  test('large legitimate negative correction is preserved', () {
    tracker.observe(_matchup(userPoints: {'u1': 64.3, 'u2': 5}));
    final event = tracker.observe(_matchup()).events.single;
    expect(event.delta, -50);
  });

  test('event order is user starters then opponent starters', () {
    tracker.observe(_matchup());
    final events = tracker
        .observe(
          _matchup(
            userPoints: {'u1': 15.3, 'u2': 7},
            opponentPoints: {'o1': 20, 'o2': 9},
          ),
        )
        .events;
    expect(events.map((event) => event.playerId), ['u1', 'u2', 'o1', 'o2']);
  });

  test('matchup total reconciliation observes matching totals', () {
    tracker.observe(_matchup(userTotal: 19.3));
    final result = tracker.observe(
      _matchup(userPoints: {'u1': 20.3, 'u2': 5}, userTotal: 25.3),
    );
    final reconciliation = result.reconciliations.first;
    expect(reconciliation.matchupTotalDelta, 6);
    expect(reconciliation.starterDeltaTotal, 6);
    expect(reconciliation.matches, isTrue);
  });

  test('reconciliation mismatch does not suppress player events', () {
    tracker.observe(_matchup(userTotal: 19.3));
    final result = tracker.observe(
      _matchup(userPoints: {'u1': 20.3, 'u2': 5}, userTotal: 30.3),
    );
    expect(result.events, hasLength(1));
    expect(result.reconciliations.first.matches, isFalse);
    expect(result.reconciliations.first.discrepancy, 5);
  });

  test('tracker is a pure fantasy-domain component', () {
    expect(tracker, isA<FantasyPointDeltaTracker>());
    expect(tracker.observe(_matchup()).events, isEmpty);
  });

  test('delta engine has no BLE interaction', () {
    final source = File(
      'lib/fantasy_point_delta_tracker.dart',
    ).readAsStringSync();
    expect(source.toLowerCase(), isNot(contains('bluetooth')));
    expect(source.toLowerCase(), isNot(contains('device_transport')));
  });

  test('delta engine makes no ESPN request', () {
    final source = File(
      'lib/fantasy_point_delta_tracker.dart',
    ).readAsStringSync();
    expect(source.toLowerCase(), isNot(contains('espn')));
    expect(source.toLowerCase(), isNot(contains('http')));
  });

  test('fantasy delta diagnostics introduce no periodic timer', () {
    final sources = [
      File('lib/fantasy_point_delta_tracker.dart').readAsStringSync(),
      File('lib/fantasy_screen.dart').readAsStringSync(),
    ].join();
    expect(sources, isNot(contains('Timer.periodic')));
  });
}

SleeperFantasyMatchup _matchup({
  String leagueId = 'league-1',
  int week = 8,
  int userRosterId = 1,
  int opponentRosterId = 2,
  int matchupId = 9,
  List<String> userStarters = const ['u1', 'u2'],
  List<String> opponentStarters = const ['o1', 'o2'],
  Map<String, double> userPoints = const {'u1': 14.3, 'u2': 5},
  Map<String, double> opponentPoints = const {'o1': 17, 'o2': 6},
  double userBenchPoints = 1,
  double userTotal = 19.3,
  double opponentTotal = 23,
}) => SleeperFantasyMatchup(
  league: SleeperLeague(
    leagueId: leagueId,
    name: 'League',
    season: '2026',
    status: 'in_season',
    scoringSettings: const {},
    rosterPositions: const [],
  ),
  week: week,
  team: SleeperFantasyTeam(
    roster: SleeperRoster(
      rosterId: userRosterId,
      ownerId: 'user',
      players: const ['u1', 'u2', 'bench'],
      starters: userStarters,
    ),
    user: const SleeperUser(userId: 'user', displayName: 'User'),
    matchup: SleeperMatchup(
      rosterId: userRosterId,
      matchupId: matchupId,
      points: userTotal,
      starters: userStarters,
      playerPoints: {...userPoints, 'bench': userBenchPoints},
    ),
  ),
  opponent: SleeperFantasyTeam(
    roster: SleeperRoster(
      rosterId: opponentRosterId,
      ownerId: 'opponent',
      players: const ['o1', 'o2'],
      starters: opponentStarters,
    ),
    user: const SleeperUser(userId: 'opponent', displayName: 'Opponent'),
    matchup: SleeperMatchup(
      rosterId: opponentRosterId,
      matchupId: matchupId,
      points: opponentTotal,
      starters: opponentStarters,
      playerPoints: opponentPoints,
    ),
  ),
);
