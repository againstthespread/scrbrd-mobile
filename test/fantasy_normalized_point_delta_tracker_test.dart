import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/fantasy_league_config.dart';
import 'package:sports_hub_mobile/fantasy_point_delta_tracker.dart';
import 'package:sports_hub_mobile/fantasy_provider_models.dart';

void main() {
  FantasyMatchupSnapshot matchup({
    int period = 1,
    List<FantasyScoringPlayer> starters = const [
      FantasyScoringPlayer(id: '-16001', name: 'D/ST', points: 8),
    ],
  }) => FantasyMatchupSnapshot(
    league: FantasyLeagueDetails(
      provider: FantasyProvider.espn,
      leagueId: 'league',
      season: 2026,
      name: 'League',
      scoringPeriod: period,
      matchupPeriod: period,
      teams: const [
        FantasyTeamDetails(id: '1', name: 'Home'),
        FantasyTeamDetails(id: '2', name: 'Away'),
      ],
    ),
    team: FantasyScoringTeam(
      team: const FantasyTeamDetails(id: '1', name: 'Home'),
      totalPoints: starters.fold<double>(
        0,
        (sum, player) => sum + (player.points ?? 0),
      ),
      starters: starters,
    ),
    opponent: const FantasyScoringTeam(
      team: FantasyTeamDetails(id: '2', name: 'Away'),
      totalPoints: 0,
      starters: [],
    ),
  );

  test('negative ESPN D/ST identity and decimal delta are preserved', () {
    final tracker = FantasyNormalizedPointDeltaTracker();
    expect(tracker.observe(matchup()).baselineReset, isTrue);
    final next = tracker.observe(
      matchup(
        starters: const [
          FantasyScoringPlayer(id: '-16001', name: 'D/ST', points: 10.5),
        ],
      ),
    );
    expect(next.events.single.playerId, '-16001');
    expect(next.events.single.delta, 2.5);
  });

  test('unavailable starter retains baseline while other players score', () {
    final tracker = FantasyNormalizedPointDeltaTracker();
    FantasyMatchupSnapshot current(double? defense, double other) => matchup(
      starters: [
        FantasyScoringPlayer(id: '-16001', name: 'D/ST', points: defense),
        FantasyScoringPlayer(id: '123', name: 'Starter', points: other),
      ],
    );
    tracker.observe(current(10, 3));
    final partial = tracker.observe(current(null, 4));
    expect(partial.events.single.playerId, '123');
    expect(partial.events.single.delta, 1);
    expect(tracker.observe(current(null, 4)).events, isEmpty);
    final recovered = tracker.observe(current(11, 4));
    expect(recovered.events.single.playerId, '-16001');
    expect(recovered.events.single.delta, 1);
  });

  test('initial unavailable points establish baseline only when known', () {
    final tracker = FantasyNormalizedPointDeltaTracker();
    FantasyMatchupSnapshot current(double? points) => matchup(
      starters: [
        FantasyScoringPlayer(id: '-16001', name: 'D/ST', points: points),
      ],
    );
    expect(tracker.observe(current(null)).baselineReset, isTrue);
    expect(tracker.observe(current(null)).events, isEmpty);
    expect(tracker.observe(current(0)).events, isEmpty);
    expect(tracker.observe(current(-2.5)).events.single.delta, -2.5);
    tracker.observe(matchup(starters: const []));
    // Removed/reintroduced players must not retain the old lineup baseline.
    expect(tracker.observe(current(10)).events, isEmpty);
  });

  test('new scoring period and new starter establish safe baselines', () {
    final tracker = FantasyNormalizedPointDeltaTracker();
    tracker.observe(matchup());
    expect(tracker.observe(matchup(period: 2)).events, isEmpty);
    final samePeriodNewStarter = tracker.observe(
      matchup(
        period: 2,
        starters: const [
          FantasyScoringPlayer(id: '-16001', name: 'D/ST', points: 8),
          FantasyScoringPlayer(id: '123', name: 'New starter', points: 12),
        ],
      ),
    );
    expect(samePeriodNewStarter.events, isEmpty);
  });

  test('removed starters leave remaining player tracking intact', () {
    final tracker = FantasyNormalizedPointDeltaTracker();
    tracker.observe(
      matchup(
        starters: const [
          FantasyScoringPlayer(id: '-16001', name: 'D/ST', points: 8),
          FantasyScoringPlayer(id: '123', name: 'Starter', points: 3),
        ],
      ),
    );
    final next = tracker.observe(
      matchup(
        starters: const [
          FantasyScoringPlayer(id: '-16001', name: 'D/ST', points: 9),
        ],
      ),
    );
    expect(next.events.single.playerId, '-16001');
    expect(next.events.single.delta, 1);
  });
}
