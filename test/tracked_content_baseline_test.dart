import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/tracked_content_baseline.dart';

void main() {
  group('TrackedContentBaseline', () {
    test('individual team send establishes the tracked game', () {
      final baseline = TrackedContentBaseline();

      baseline.recordTeamGame(_game('one'));

      expect(baseline.game?.eventId, 'one');
      expect(baseline.golf, isNull);
    });

    test('slate send tracks the first displayed game', () {
      final baseline = TrackedContentBaseline();

      baseline.recordTeamSlate([_game('first'), _game('second')]);

      expect(baseline.game?.eventId, 'first');
      expect(baseline.golf, isNull);
    });

    test('PGA and team baselines are mutually exclusive', () {
      final baseline = TrackedContentBaseline();
      baseline.recordTeamGame(_game('team'));

      baseline.recordGolf(_golf);
      expect(baseline.game, isNull);
      expect(baseline.golf, same(_golf));

      baseline.recordTeamGame(_game('new-team'));
      expect(baseline.game?.eventId, 'new-team');
      expect(baseline.golf, isNull);
    });

    test('empty slate cannot establish a baseline', () {
      expect(
        () => TrackedContentBaseline().recordTeamSlate(const []),
        throwsArgumentError,
      );
    });
  });
}

GameData _game(String eventId) => GameData(
  eventId: eventId,
  league: 'MLB',
  awayTeam: 'NYY',
  homeTeam: 'BOS',
  awayScore: 1,
  homeScore: 2,
  status: 'LIVE',
  clock: 'Top 4th',
);

final _golf = GolfLeaderboard(
  tournamentId: 'pga-1',
  tournamentName: 'Championship',
  golfers: const [],
  isInProgress: true,
  isOver: false,
);
