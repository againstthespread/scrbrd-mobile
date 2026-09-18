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
        (sum, player) => sum + player.points,
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
