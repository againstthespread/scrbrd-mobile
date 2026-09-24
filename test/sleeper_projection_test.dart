import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sports_hub_mobile/sleeper_api_client.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';
import 'package:sports_hub_mobile/sleeper_projection.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';

void main() {
  group('Sleeper settling projection', () {
    late _MemoryBaselineStore store;
    late _ProjectionSource source;
    late _StatusSource statuses;
    late Map<String, SleeperFantasyPlayer> metadata;
    late SleeperSettlingProjectionService service;

    setUp(() {
      store = _MemoryBaselineStore();
      source = _ProjectionSource();
      statuses = _StatusSource();
      metadata = {};
      service = _service(
        store: store,
        source: source,
        statuses: statuses,
        metadata: metadata,
      );
    });

    test('pregame sums starters and excludes bench players', () async {
      _addPlayer(source, metadata, 'qb', 'BUF', {'pass_yd': 250});
      _addPlayer(source, metadata, 'rb', 'KC', {'rush_yd': 80});
      _addPlayer(source, metadata, 'bench', 'MIA', {'rush_yd': 200});
      statuses.values.addAll({
        'BUF': SleeperNflGamePhase.upcoming,
        'KC': SleeperNflGamePhase.upcoming,
        'MIA': SleeperNflGamePhase.upcoming,
      });
      final matchup = _matchup(
        starters: const ['qb', 'rb'],
        bench: const ['bench'],
        scoring: const {'pass_yd': 0.04, 'rush_yd': 0.1},
      );

      final result = await _capture(service, matchup);

      expect(result.team.projectedTotalPoints, 18);
      expect(source.calls['qb'], 1);
      expect(source.calls['rb'], 1);
      expect(source.calls['bench'], isNull);
    });

    test('live players retain their original frozen projection', () async {
      _addPlayer(source, metadata, 'p1', 'BUF', {'rush_yd': 120});
      statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
      final pregame = _matchup(
        starters: const ['p1'],
        scoring: const {'rush_yd': 0.1},
        actual: const {'p1': 0},
      );
      await service.refresh(pregame);

      statuses.values['BUF'] = SleeperNflGamePhase.live;
      source.projections['p1'] = _projection('p1', 'BUF', {'rush_yd': 300});
      final live = _matchup(
        starters: const ['p1'],
        scoring: const {'rush_yd': 0.1},
        actual: const {'p1': 20},
        actualTotal: 20,
      );
      await service.refresh(live);

      expect((await service.applyCached(live)).team.projectedTotalPoints, 12);
      expect(source.calls['p1'], 1);
    });

    test('FINAL substitutes actual in the 100 + (14 - 12) example', () async {
      _addPlayer(source, metadata, 'finished', 'BUF', {'rush_yd': 12});
      _addPlayer(source, metadata, 'remaining', 'KC', {'rush_yd': 88});
      statuses.values.addAll({
        'BUF': SleeperNflGamePhase.upcoming,
        'KC': SleeperNflGamePhase.upcoming,
      });
      final matchup = _matchup(
        starters: const ['finished', 'remaining'],
        scoring: const {'rush_yd': 1},
        actual: const {'finished': 14, 'remaining': 0},
        actualTotal: 14,
      );
      await service.refresh(matchup);
      expect(
        (await service.applyCached(matchup)).team.projectedTotalPoints,
        100,
      );

      statuses.values['BUF'] = SleeperNflGamePhase.finalStatus;
      await service.refresh(matchup);

      expect(
        (await service.applyCached(matchup)).team.projectedTotalPoints,
        102,
      );
    });

    test('several FINAL players settle independently', () async {
      _addPlayer(source, metadata, 'a', 'BUF', {'rush_yd': 10});
      _addPlayer(source, metadata, 'b', 'KC', {'rush_yd': 20});
      _addPlayer(source, metadata, 'c', 'MIA', {'rush_yd': 30});
      statuses.values.addAll({
        'BUF': SleeperNflGamePhase.upcoming,
        'KC': SleeperNflGamePhase.upcoming,
        'MIA': SleeperNflGamePhase.upcoming,
      });
      final matchup = _matchup(
        starters: const ['a', 'b', 'c'],
        scoring: const {'rush_yd': 1},
        actual: const {'a': 13, 'b': 16, 'c': 2},
        actualTotal: 31,
      );
      await service.refresh(matchup);

      statuses.values.addAll({
        'BUF': SleeperNflGamePhase.finalStatus,
        'KC': SleeperNflGamePhase.finalStatus,
      });
      await service.refresh(matchup);

      expect(
        (await service.applyCached(matchup)).team.projectedTotalPoints,
        59,
      );
    });

    test('all FINAL starters converge to the Sleeper actual total', () async {
      _addPlayer(source, metadata, 'a', 'BUF', {'rush_yd': 10});
      _addPlayer(source, metadata, 'b', 'KC', {'rush_yd': 20});
      statuses.values.addAll({
        'BUF': SleeperNflGamePhase.upcoming,
        'KC': SleeperNflGamePhase.upcoming,
      });
      final matchup = _matchup(
        starters: const ['a', 'b'],
        scoring: const {'rush_yd': 1},
        actual: const {'a': 14.25, 'b': 7.5},
        actualTotal: 21.75,
      );
      await service.refresh(matchup);

      statuses.values.updateAll((_, _) => SleeperNflGamePhase.finalStatus);
      await service.refresh(matchup);
      final result = await service.applyCached(matchup);

      expect(result.team.projectedTotalPoints, matchup.team.matchup.points);
    });

    test(
      'missing active starter projection makes the team unavailable',
      () async {
        _addPlayer(source, metadata, 'known', 'BUF', {'rush_yd': 10});
        metadata['missing'] = _player('missing', 'KC');
        statuses.values.addAll({
          'BUF': SleeperNflGamePhase.upcoming,
          'KC': SleeperNflGamePhase.upcoming,
        });
        final matchup = _matchup(
          starters: const ['known', 'missing'],
          scoring: const {'rush_yd': 1},
        );

        expect(
          (await _capture(service, matchup)).team.projectedTotalPoints,
          isNull,
        );
      },
    );

    test('missing projection is sufficient once the game is FINAL', () async {
      metadata['missing'] = _player('missing', 'BUF');
      _addPlayer(source, metadata, 'known', 'BUF', {'rush_yd': 10});
      statuses.values['BUF'] = SleeperNflGamePhase.finalStatus;
      final matchup = _matchup(
        starters: const ['missing', 'known'],
        scoring: const {'rush_yd': 1},
        actual: const {'missing': 8, 'known': 11},
        actualTotal: 19,
      );

      expect((await _capture(service, matchup)).team.projectedTotalPoints, 19);
    });

    test('unknown game status never substitutes actual points', () async {
      _addPlayer(source, metadata, 'p1', 'BUF', {'rush_yd': 10});
      statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
      final matchup = _matchup(
        starters: const ['p1'],
        scoring: const {'rush_yd': 1},
        actual: const {'p1': 50},
        actualTotal: 50,
      );
      await service.refresh(matchup);

      final reconstructed = _service(
        store: store,
        source: source,
        statuses: _StatusSource(),
        metadata: metadata,
      );
      expect(
        (await reconstructed.applyCached(matchup)).team.projectedTotalPoints,
        10,
      );
    });

    test(
      'two leagues score one raw projection with their own settings',
      () async {
        _addPlayer(source, metadata, 'qb', 'BUF', {'pass_yd': 300});
        statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
        final fourPoint = _matchup(
          leagueId: 'four-point',
          starters: const ['qb'],
          scoring: const {'pass_yd': 0.04},
        );
        final fivePoint = _matchup(
          leagueId: 'five-point',
          starters: const ['qb'],
          scoring: const {'pass_yd': 0.05},
        );

        expect(
          (await _capture(service, fourPoint)).team.projectedTotalPoints,
          12,
        );
        expect(
          (await _capture(service, fivePoint)).team.projectedTotalPoints,
          15,
        );
        expect(source.calls['qb'], 1);
      },
    );

    test('bench-to-starter before kickoff freezes the new starter', () async {
      _addPlayer(source, metadata, 'starter', 'BUF', {'rush_yd': 10});
      _addPlayer(source, metadata, 'bench', 'KC', {'rush_yd': 20});
      statuses.values.addAll({
        'BUF': SleeperNflGamePhase.upcoming,
        'KC': SleeperNflGamePhase.upcoming,
      });
      final original = _matchup(
        starters: const ['starter'],
        bench: const ['bench'],
        scoring: const {'rush_yd': 1},
      );
      await service.refresh(original);
      expect(source.calls['bench'], isNull);

      final changed = _matchup(
        starters: const ['starter', 'bench'],
        scoring: const {'rush_yd': 1},
      );
      await service.refresh(changed);

      expect(
        (await service.applyCached(changed)).team.projectedTotalPoints,
        30,
      );
      expect(source.calls['bench'], 1);
    });

    test('player moved into lineup after kickoff is not backfilled', () async {
      _addPlayer(source, metadata, 'starter', 'BUF', {'rush_yd': 10});
      _addPlayer(source, metadata, 'late', 'KC', {'rush_yd': 20});
      statuses.values.addAll({
        'BUF': SleeperNflGamePhase.upcoming,
        'KC': SleeperNflGamePhase.upcoming,
      });
      await service.refresh(
        _matchup(
          starters: const ['starter'],
          bench: const ['late'],
          scoring: const {'rush_yd': 1},
        ),
      );
      statuses.values['KC'] = SleeperNflGamePhase.live;
      final changed = _matchup(
        starters: const ['starter', 'late'],
        scoring: const {'rush_yd': 1},
      );
      await service.refresh(changed);

      expect(
        (await service.applyCached(changed)).team.projectedTotalPoints,
        isNull,
      );
    });

    test('remote projection changes never rebase a frozen player', () async {
      _addPlayer(source, metadata, 'p1', 'BUF', {'rush_yd': 10});
      statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
      final matchup = _matchup(
        starters: const ['p1'],
        scoring: const {'rush_yd': 1},
      );
      await service.refresh(matchup);
      source.projections['p1'] = _projection('p1', 'BUF', {'rush_yd': 99});
      await service.refresh(matchup);

      expect(
        (await service.applyCached(matchup)).team.projectedTotalPoints,
        10,
      );
      expect(source.calls['p1'], 1);
    });

    test('frozen baseline survives service reconstruction', () async {
      _addPlayer(source, metadata, 'p1', 'BUF', {'rush_yd': 10});
      statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
      final matchup = _matchup(
        starters: const ['p1'],
        scoring: const {'rush_yd': 1},
      );
      await service.refresh(matchup);
      source.projections['p1'] = _projection('p1', 'BUF', {'rush_yd': 99});

      final reconstructed = _service(
        store: store,
        source: source,
        statuses: statuses,
        metadata: metadata,
      );

      expect(
        (await reconstructed.applyCached(matchup)).team.projectedTotalPoints,
        10,
      );
      expect(source.calls['p1'], 1);
    });

    test('week rollover never reuses a prior weekly baseline', () async {
      _addPlayer(source, metadata, 'p1', 'BUF', {'rush_yd': 10});
      statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
      final weekOne = _matchup(
        starters: const ['p1'],
        scoring: const {'rush_yd': 1},
      );
      await service.refresh(weekOne);

      final weekTwo = _matchup(
        week: 2,
        starters: const ['p1'],
        scoring: const {'rush_yd': 1},
      );

      expect(
        (await service.applyCached(weekTwo)).team.projectedTotalPoints,
        isNull,
      );
      expect(store.snapshot?.week, 2);
    });

    test('an old in-flight refresh cannot write into a new week', () async {
      _addPlayer(source, metadata, 'p1', 'BUF', {'rush_yd': 10});
      statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
      final weekOne = _matchup(
        starters: const ['p1'],
        scoring: const {'rush_yd': 1},
      );
      final weekTwo = _matchup(
        week: 2,
        starters: const ['p1'],
        scoring: const {'rush_yd': 1},
      );
      source.started = Completer<void>();
      source.gate = Completer<void>();

      final oldRefresh = service.refresh(weekOne);
      await source.started!.future;
      await service.applyCached(weekTwo);
      source.gate!.complete();
      await oldRefresh;

      expect(store.snapshot?.week, 2);
      expect(
        (await service.applyCached(weekTwo)).team.projectedTotalPoints,
        isNull,
      );
    });

    test(
      'projection source failure yields unavailable without throwing',
      () async {
        metadata['p1'] = _player('p1', 'BUF');
        statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
        source.fail = true;
        final matchup = _matchup(
          starters: const ['p1'],
          scoring: const {'rush_yd': 1},
          actual: const {'p1': 7},
          actualTotal: 7,
        );

        await expectLater(service.refresh(matchup), completes);
        final result = await service.applyCached(matchup);
        expect(result.team.matchup.points, 7);
        expect(result.team.projectedTotalPoints, isNull);
      },
    );

    test(
      'baseline write failure is visible without breaking matchup',
      () async {
        final diagnostics = <String>[];
        store.failWrites = true;
        service = _service(
          store: store,
          source: source,
          statuses: statuses,
          metadata: metadata,
          onDiagnostic: diagnostics.add,
        );
        final matchup = _matchup(
          starters: const ['missing'],
          scoring: const {'rush_yd': 0.1},
        );

        await expectLater(service.applyCached(matchup), completes);

        expect(
          diagnostics,
          contains('Sleeper projection baseline persistence failed.'),
        );
      },
    );

    test(
      'missing fum_rec_td is an implicit zero for an offensive player',
      () async {
        _addPlayer(source, metadata, '9228', 'CAR', {
          'pass_yd': 197.34,
          'pass_td': 1.39,
          'pass_int': 0.64,
          'rush_yd': 22.55,
          'rush_td': 0.23,
        }, position: 'QB');
        statuses.values['CAR'] = SleeperNflGamePhase.upcoming;
        final matchup = _matchup(
          starters: const ['9228'],
          scoring: const {
            'pass_yd': 0.04,
            'pass_td': 4,
            'pass_int': -1,
            'rush_yd': 0.1,
            'rush_td': 6,
            'fum_rec_td': 6,
          },
        );

        final projected = (await _capture(
          service,
          matchup,
        )).team.projectedTotalPoints;

        expect(projected, closeTo(16.4486, 0.0001));
      },
    );

    test('explicit fum_rec_td is scored for an offensive player', () async {
      _addPlayer(source, metadata, 'rb', 'BUF', {
        'rush_yd': 50,
        'fum_rec_td': 0.1,
      }, position: 'RB');
      statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
      final matchup = _matchup(
        starters: const ['rb'],
        scoring: const {'rush_yd': 0.1, 'fum_rec_td': 6},
      );

      expect(
        (await _capture(service, matchup)).team.projectedTotalPoints,
        closeTo(5.6, 0.0001),
      );
    });

    test('fum_rec_td is position-irrelevant for team defense', () async {
      _addPlayer(source, metadata, 'BUF', 'BUF', {'sack': 2}, position: 'DEF');
      statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
      final matchup = _matchup(
        starters: const ['BUF'],
        scoring: const {'sack': 1, 'fum_rec_td': 6},
      );

      expect((await _capture(service, matchup)).team.projectedTotalPoints, 2);
    });

    test(
      'sparse special-teams and short missed-kick settings use feed semantics',
      () {
        const scorer = SleeperProjectionScorer();
        final defense = scorer.evaluate(
          const {'sack': 2, 'st_td': 0.1},
          const {
            'sack': 1,
            'def_st_ff': 1,
            'def_st_fum_rec': 1,
            'def_st_td': 6,
            'st_td': 6,
          },
          position: 'DEF',
        );
        final returner = scorer.evaluate(
          const {'rec_yd': 40, 'def_kr_td': 0.05, 'pr_td': 0.02},
          const {'rec_yd': 0.1, 'kr_td': 6, 'st_td': 6, 'def_st_td': 6},
          position: 'WR',
        );
        final kicker = scorer.evaluate(
          const {'fgm': 2, 'fga': 2},
          const {'fgm': 3, 'fgmiss_0_19': -2, 'fgmiss_20_29': -1},
          position: 'K',
        );

        expect(defense.points, closeTo(2.6, 0.0001));
        expect(returner.points, closeTo(4.72, 0.0001));
        expect(kicker.points, 6);
      },
    );

    test('Trey Smack scores with the verified Week 3 kicker shape', () async {
      _addPlayer(source, metadata, '13545', 'GB', {
        'fga': 2.1,
        'fgm': 1.7,
        'fgm_20_29': 0.39,
        'fgm_30_39': 0.52,
        'fgm_40_49': 0.52,
        'fgm_50p': 0.26,
        'fgm_yds': 70.62,
        'fgmiss_30_39': 0.13,
        'fgmiss_40_49': 0.13,
        'fgmiss_50p': 0.13,
        'xpa': 2.75,
        'xpm': 2.62,
        'xpmiss': 0.13,
      }, position: 'K');
      statuses.values['GB'] = SleeperNflGamePhase.upcoming;
      final matchup = _matchup(
        starters: const ['13545'],
        scoring: const {
          'fgm_0_19': 3,
          'fgm_20_29': 3,
          'fgm_30_39': 3,
          'fgm_40_49': 4,
          'fgm_50_59': 5,
          'fgm_60p': 6,
          'fgmiss': -1,
          'xpm': 1,
          'xpmiss': -1,
        },
      );

      expect(
        (await _capture(service, matchup)).team.projectedTotalPoints,
        closeTo(8.831, 0.0001),
      );
    });

    test(
      'two modern kicker leagues score one shared raw projection independently',
      () async {
        _addPlayer(source, metadata, '13545', 'GB', {
          'fgm': 1.7,
          'xpm': 2.62,
        }, position: 'K');
        statuses.values['GB'] = SleeperNflGamePhase.upcoming;
        final standard = _matchup(
          leagueId: 'standard-long-kicks',
          starters: const ['13545'],
          scoring: const {'fgm_50_59': 5, 'fgm_60p': 6, 'xpm': 1},
        );
        final flatLong = _matchup(
          leagueId: 'flat-long-kicks',
          starters: const ['13545'],
          scoring: const {'fgm_50_59': 5, 'fgm_60p': 5, 'xpm': 1},
        );

        final standardPoints = (await _capture(
          service,
          standard,
        )).team.projectedTotalPoints;
        final flatPoints = (await _capture(
          service,
          flatLong,
        )).team.projectedTotalPoints;

        expect(standardPoints, closeTo(3.266, 0.0001));
        expect(flatPoints, closeTo(3.215, 0.0001));
        expect(source.calls['13545'], 1);
      },
    );

    test('all directly projected made-FG buckets score exactly', () {
      const scorer = SleeperProjectionScorer();
      final result = scorer.evaluate(
        const {
          'fgm_0_19': 0.1,
          'fgm_20_29': 0.2,
          'fgm_30_39': 0.3,
          'fgm_40_49': 0.4,
          'fgm_50_59': 0.5,
          'fgm_50p': 0.6,
          'fgm_60p': 0.7,
        },
        const {
          'fgm_0_19': 1,
          'fgm_20_29': 1,
          'fgm_30_39': 1,
          'fgm_40_49': 1,
          'fgm_50_59': 1,
          'fgm_50p': 1,
          'fgm_60p': 1,
        },
        position: 'K',
      );

      expect(result.points, closeTo(2.8, 0.0001));
    });

    test('missing made-FG buckets use Sleeper projection ratios', () {
      const scorer = SleeperProjectionScorer();
      final result = scorer.evaluate(
        const {'fgm': 2},
        const {
          'fgm_0_19': 1,
          'fgm_20_29': 1,
          'fgm_30_39': 1,
          'fgm_40_49': 1,
          'fgm_50_59': 1,
          'fgm_60p': 1,
        },
        position: 'K',
      );

      expect(result.points, closeTo(2.06, 0.0001));
    });

    test('base FGM and configured distance scoring stack once each', () {
      const scorer = SleeperProjectionScorer();
      final result = scorer.evaluate(
        const {'fgm': 2, 'fgm_40_49': 0.5},
        const {'fgm': 3, 'fgm_40_49': 1},
        position: 'K',
      );

      expect(result.points, 6.5);
    });

    test('FG misses and PATs use exact or sparse-zero values', () {
      const scorer = SleeperProjectionScorer();
      final exact = scorer.evaluate(
        const {
          'fga': 3,
          'fgm': 2,
          'fgmiss_30_39': 0.2,
          'fgmiss_50_59': 0.1,
          'fgmiss_60p': 0.05,
          'xpm': 2.4,
          'xpmiss': 0.1,
        },
        const {
          'fgmiss': -1,
          'fgmiss_30_39': -2,
          'fgmiss_50_59': -3,
          'fgmiss_60p': -4,
          'xpm': 1,
          'xpmiss': -1,
        },
        position: 'K',
      );
      final sparse = scorer.evaluate(
        const {'fgm': 1, 'xpm': 2},
        const {
          'fgmiss_0_19': -3,
          'fgmiss_20_29': -2,
          'fgmiss_50_59': -1,
          'fgmiss_60p': -1,
          'xpmiss': -1,
          'xpm': 1,
        },
        position: 'K',
      );

      expect(exact.points, closeTo(1.2, 0.0001));
      expect(sparse.points, 2);
    });

    test('non-derivable kicker custom scoring remains unsupported', () {
      const scorer = SleeperProjectionScorer();
      final result = scorer.evaluate(
        const {'fgm': 2, 'fgm_yds': 75},
        const {'fgm_yds_over_30': 0.1},
        position: 'K',
      );

      expect(result.points, isNull);
      expect(result.unsupportedScoringKey, 'fgm_yds_over_30');
    });

    test('IDP defensive touchdowns use the verified aggregate feed alias', () {
      const scorer = SleeperProjectionScorer();
      final result = scorer.evaluate(
        const {'def_pr_td': 0.06, 'pass_int_td': 0.06, 'idp_int': 0.11},
        const {'idp_def_td': 6, 'idp_int': 6},
        position: 'DB',
      );

      expect(result.points, closeTo(1.02, 0.0001));
    });

    test('IDP defensive touchdown components are an aggregate fallback', () {
      const scorer = SleeperProjectionScorer();
      final result = scorer.evaluate(
        const {'pass_int_td': 0.05, 'def_fum_td': 0.04},
        const {'idp_def_td': 6},
        position: 'LB',
      );

      expect(result.points, closeTo(0.54, 0.0001));
    });

    test('exact IDP defensive touchdown wins without double counting', () {
      const scorer = SleeperProjectionScorer();
      final result = scorer.evaluate(
        const {'idp_def_td': 0.03, 'def_pr_td': 0.06, 'pass_int_td': 0.06},
        const {'idp_def_td': 6},
        position: 'DB',
      );

      expect(result.points, closeTo(0.18, 0.0001));
    });

    test('missing verified sparse IDP counters contribute zero', () {
      const scorer = SleeperProjectionScorer();
      final result = scorer.evaluate(
        const {'idp_tkl_solo': 3},
        const {
          'idp_tkl_solo': 2,
          'idp_def_td': 6,
          'idp_int': 6,
          'idp_fum_rec': 3,
          'idp_ff': 3,
          'idp_safe': 3,
          'idp_blk_kick': 3,
        },
        position: 'LB',
      );

      expect(result.points, 6);
    });

    test('canonical pass-defended and QB-hit names match the feed', () {
      const scorer = SleeperProjectionScorer();
      final result = scorer.evaluate(
        const {'idp_pass_def': 0.4, 'idp_qb_hit': 1.5},
        const {'idp_pass_def': 3, 'idp_qb_hit': 1},
        position: 'DE',
      );

      expect(result.points, closeTo(2.7, 0.0001));
    });

    test('unverified legacy IDP shorthand is not treated as an alias', () {
      const scorer = SleeperProjectionScorer();
      final passDefended = scorer.evaluate(
        const {'idp_pass_def': 0.4},
        const {'idp_pd': 3},
        position: 'DB',
      );
      final quarterbackHit = scorer.evaluate(
        const {'idp_qb_hit': 1.5},
        const {'idp_qbhit': 1},
        position: 'DE',
      );

      expect(passDefended.unsupportedScoringKey, 'idp_pd');
      expect(quarterbackHit.unsupportedScoringKey, 'idp_qbhit');
    });

    test('normal IDP tackle, pressure, and turnover categories score once', () {
      const scorer = SleeperProjectionScorer();
      final result = scorer.evaluate(
        const {
          'idp_tkl': 7,
          'idp_tkl_solo': 4,
          'idp_tkl_ast': 3,
          'idp_tkl_loss': 0.5,
          'idp_sack': 0.5,
          'idp_sack_yd': 3,
          'idp_int': 0.1,
          'idp_int_ret_yd': 2,
          'idp_ff': 0.2,
          'idp_fum_rec': 0.1,
          'idp_fum_ret_yd': 1,
          'idp_safe': 0.05,
          'idp_blk_kick': 0.05,
        },
        const {
          'idp_tkl': 1,
          'idp_tkl_solo': 2,
          'idp_tkl_ast': 1,
          'idp_tkl_loss': 2,
          'idp_sack': 6,
          'idp_sack_yd': 0.1,
          'idp_int': 6,
          'idp_int_ret_yd': 0.1,
          'idp_ff': 3,
          'idp_fum_rec': 3,
          'idp_fum_ret_yd': 0.1,
          'idp_safe': 3,
          'idp_blk': 3,
        },
        position: 'DL',
      );

      expect(result.points, closeTo(24.4, 0.0001));
    });

    test('unknown IDP custom key remains unsupported', () {
      const scorer = SleeperProjectionScorer();
      final result = scorer.evaluate(
        const {'idp_tkl_solo': 4},
        const {'idp_tkl_solo': 2, 'idp_custom_award': 5},
        position: 'LB',
      );

      expect(result.points, isNull);
      expect(result.unsupportedScoringKey, 'idp_custom_award');
    });

    test(
      'physical league 1312092721397133312 freezes all 24 starters',
      () async {
        final diagnostics = <String>[];
        service = _service(
          store: store,
          source: source,
          statuses: statuses,
          metadata: metadata,
          onDiagnostic: diagnostics.add,
        );
        const offensivePlayers = <(String, String, String)>[
          ('7523', 'JAX', 'QB'),
          ('4034', 'SF', 'RB'),
          ('7588', 'DAL', 'RB'),
          ('6786', 'DAL', 'WR'),
          ('11632', 'NYG', 'WR'),
          ('1466', 'KC', 'TE'),
          ('4199', 'MIN', 'RB'),
          ('11834', 'NO', 'WR'),
          ('11533', 'DAL', 'K'),
          ('5870', 'IND', 'QB'),
          ('9226', 'MIA', 'RB'),
          ('5892', 'HOU', 'RB'),
          ('8144', 'NO', 'WR'),
          ('7525', 'PHI', 'WR'),
          ('5001', 'HOU', 'TE'),
          ('12481', 'NYG', 'RB'),
          ('7594', 'CAR', 'RB'),
          ('13545', 'GB', 'K'),
        ];
        for (final player in offensivePlayers) {
          final stats = switch (player.$3) {
            'QB' => const {
              'pass_yd': 250.0,
              'pass_td': 1.5,
              'pass_int': 0.5,
              'rush_yd': 20.0,
            },
            'K' => const {'fga': 2.2, 'fgm': 2.0, 'xpm': 2.5},
            _ => const {
              'rush_yd': 50.0,
              'rush_td': 0.3,
              'rec': 4.0,
              'rec_yd': 45.0,
              'rec_td': 0.2,
            },
          };
          _addPlayer(
            source,
            metadata,
            player.$1,
            player.$2,
            stats,
            position: player.$3,
            week: 3,
          );
        }
        const idpPlayers = <(String, String, String, Map<String, double>)>[
          (
            '7627',
            'BUF',
            'DE',
            {
              'idp_ff': 0.06,
              'idp_qb_hit': 1.49,
              'idp_sack': 0.59,
              'idp_sack_yd': 2.3,
              'idp_tkl': 2.8,
              'idp_tkl_ast': 1.24,
              'idp_tkl_loss': 0.62,
              'idp_tkl_solo': 1.55,
            },
          ),
          (
            '5332',
            'JAX',
            'LB',
            {
              'idp_ff': 0.05,
              'idp_fum_rec': 0.05,
              'idp_int': 0.05,
              'idp_pass_def': 0.38,
              'idp_qb_hit': 0.05,
              'idp_sack': 0.05,
              'idp_tkl_ast': 3.86,
              'idp_tkl_loss': 0.33,
              'idp_tkl_solo': 3.97,
            },
          ),
          (
            '8330',
            'LAR',
            'DB',
            {
              'idp_int': 0.06,
              'idp_pass_def': 0.4,
              'idp_qb_hit': 0.11,
              'idp_sack': 0.06,
              'idp_tkl_ast': 0.74,
              'idp_tkl_loss': 0.06,
              'idp_tkl_solo': 2.45,
            },
          ),
          (
            '8289',
            'DET',
            'DL',
            {
              'idp_ff': 0.17,
              'idp_fum_rec': 0.11,
              'idp_int': 0.06,
              'idp_pass_def': 0.17,
              'idp_qb_hit': 1.93,
              'idp_sack': 0.74,
              'idp_safe': 0.06,
              'idp_tkl_ast': 0.97,
              'idp_tkl_loss': 0.74,
              'idp_tkl_solo': 1.99,
            },
          ),
          (
            '11687',
            'GB',
            'LB',
            {
              'idp_ff': 0.11,
              'idp_fum_rec': 0.06,
              'idp_pass_def': 0.23,
              'idp_qb_hit': 0.29,
              'idp_sack': 0.2,
              'idp_tkl_ast': 3.09,
              'idp_tkl_loss': 0.4,
              'idp_tkl_solo': 3.72,
            },
          ),
          (
            '11678',
            'PHI',
            'DB',
            {
              'def_pr_td': 0.06,
              'pass_int_td': 0.06,
              'idp_ff': 0.06,
              'idp_fum_rec': 0.06,
              'idp_int': 0.11,
              'idp_pass_def': 0.68,
              'idp_qb_hit': 0.06,
              'idp_tkl_ast': 1.69,
              'idp_tkl_loss': 0.17,
              'idp_tkl_solo': 3.77,
            },
          ),
        ];
        for (final player in idpPlayers) {
          _addPlayer(
            source,
            metadata,
            player.$1,
            player.$2,
            player.$4,
            position: player.$3,
            week: 3,
          );
        }
        statuses.values.addAll({
          for (final player in metadata.values)
            player.nflTeam!: SleeperNflGamePhase.upcoming,
        });
        final matchup = _physicalIdpMatchup();

        final projected = await _capture(service, matchup);

        expect(
          projected.team.projectedTotalPoints,
          isNotNull,
          reason: diagnostics.join('\n'),
        );
        expect(
          projected.opponent.projectedTotalPoints,
          isNotNull,
          reason: diagnostics.join('\n'),
        );
        expect(
          store.snapshot!.leagues['1312092721397133312']!.players,
          hasLength(24),
        );
        expect(source.calls.values.every((calls) => calls == 1), isTrue);
        expect(
          diagnostics,
          contains(contains('changed=true frozen=24/24 persisted=true')),
        );
        expect(
          diagnostics,
          contains(contains('stored=24 team=ready opponent=ready')),
        );
      },
    );

    test(
      'normal 2026 scoring settings freeze a complete 11-player lineup',
      () async {
        const starters = [
          '9228',
          'rb1',
          'rb2',
          'wr1',
          'wr2',
          'wr3',
          'te',
          'flex1',
          'flex2',
          'k',
          'BUF',
        ];
        _addPlayer(source, metadata, '9228', 'CAR', {
          'pass_yd': 197.34,
          'pass_td': 1.39,
          'pass_int': 0.64,
          'rush_yd': 22.55,
          'rush_td': 0.23,
          'fum_lost': 0.18,
        }, position: 'QB');
        for (final id in const ['rb1', 'rb2', 'flex1']) {
          _addPlayer(source, metadata, id, 'BUF', {
            'rush_yd': 60,
            'rush_td': 0.4,
            'rec': 3,
            'rec_yd': 20,
            'rec_td': 0.1,
          }, position: 'RB');
        }
        for (final id in const ['wr1', 'wr2', 'wr3', 'flex2']) {
          _addPlayer(source, metadata, id, 'MIA', {
            'rec': 5,
            'rec_yd': 70,
            'rec_td': 0.3,
          }, position: 'WR');
        }
        _addPlayer(source, metadata, 'te', 'KC', {
          'rec': 4,
          'rec_yd': 45,
          'rec_td': 0.25,
        }, position: 'TE');
        _addPlayer(source, metadata, 'k', 'DAL', {
          'fga': 2,
          'fgm': 2,
          'fgm_30_39': 1,
          'fgm_40_49': 1,
          'xpm': 3,
        }, position: 'K');
        _addPlayer(source, metadata, 'BUF', 'BUF', {
          'sack': 2.4,
          'int': 0.8,
          'ff': 0.6,
          'fum_rec': 0.6,
          'def_td': 0.13,
          'st_td': 0.05,
          'pts_allow': 20,
        }, position: 'DEF');
        statuses.values.addAll({
          'CAR': SleeperNflGamePhase.upcoming,
          'BUF': SleeperNflGamePhase.upcoming,
          'MIA': SleeperNflGamePhase.upcoming,
          'KC': SleeperNflGamePhase.upcoming,
          'DAL': SleeperNflGamePhase.upcoming,
        });
        final matchup = _matchup(
          starters: starters,
          scoring: _normal2026Scoring,
        );

        final projected = (await _capture(
          service,
          matchup,
        )).team.projectedTotalPoints;

        expect(projected, isNotNull);
        expect(projected!, greaterThan(0));
        expect(store.snapshot!.leagues['league']!.players, hasLength(11));
      },
    );

    test(
      'unsupported configured category makes projection unavailable',
      () async {
        final diagnostics = <String>[];
        service = _service(
          store: store,
          source: source,
          statuses: statuses,
          metadata: metadata,
          onDiagnostic: diagnostics.add,
        );
        _addPlayer(source, metadata, 'qb', 'BUF', {
          'pass_yd': 310,
        }, position: 'QB');
        statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
        final matchup = _matchup(
          starters: const ['qb'],
          scoring: const {'pass_yd': 0.04, 'bonus_pass_yd_300': 3},
        );

        expect(
          (await _capture(service, matchup)).team.projectedTotalPoints,
          isNull,
        );
        expect(
          diagnostics,
          contains(
            contains(
              'player=qb name=qb position=QB nfl_team=BUF raw=true '
              'stats=true scoring=false game_mapping=true baseline=false '
              'reason=unsupported_scoring_key key=bonus_pass_yd_300',
            ),
          ),
        );
        expect(
          diagnostics,
          contains(
            contains(
              'side=team unresolved_starters=1 first_player=qb '
              'reason=unsupported_scoring_key key=bonus_pass_yd_300',
            ),
          ),
        );
      },
    );

    test('unknown custom scoring key remains unsupported', () async {
      _addPlayer(source, metadata, 'qb', 'BUF', {
        'pass_yd': 300,
      }, position: 'QB');
      statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
      final matchup = _matchup(
        starters: const ['qb'],
        scoring: const {'pass_yd': 0.04, 'custom_trophy_bonus': 5},
      );

      expect(
        (await _capture(service, matchup)).team.projectedTotalPoints,
        isNull,
      );
    });

    test('offensive starters ignore D/ST scoring buckets', () async {
      _addPlayer(source, metadata, 'qb', 'BUF', {
        'pass_yd': 300,
      }, position: 'QB');
      statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
      final matchup = _matchup(
        starters: const ['qb'],
        scoring: const {
          'pass_yd': 0.04,
          'pts_allow_0': 10,
          'pts_allow_1_6': 7,
          'yds_allow_0_100': 5,
          'st_fum_rec': 1,
          'st_ff': 1,
        },
      );

      expect((await _capture(service, matchup)).team.projectedTotalPoints, 12);
    });

    test(
      'D/ST accepts supported zero-value special-teams categories',
      () async {
        _addPlayer(source, metadata, 'BUF', 'BUF', {
          'pts_allow': 10,
          'sack': 2,
        }, position: 'DEF');
        statuses.values['BUF'] = SleeperNflGamePhase.upcoming;
        final matchup = _matchup(
          starters: const ['BUF'],
          scoring: const {
            'sack': 1,
            'pts_allow_7_13': 4,
            'st_fum_rec': 1,
            'st_ff': 1,
          },
        );

        expect((await _capture(service, matchup)).team.projectedTotalPoints, 6);
      },
    );
  });

  test('generic scorer covers offense, kicking, defense, and fractions', () {
    const scorer = SleeperProjectionScorer();
    final result = scorer.score(
      const {
        'pass_yd': 250,
        'pass_td': 2,
        'bonus_pass_yd_300': 1,
        'pass_int': 1,
        'rush_yd': 25,
        'rush_td': 1,
        'rec': 4,
        'rec_yd': 50,
        'rec_td': 1,
        'fum_lost': 1,
        'pass_2pt': 1,
        'fgm_40_49': 2,
        'xpm': 3,
        'sack': 3,
        'int': 2,
        'def_td': 1,
        'pts_allow': 10,
      },
      const {
        'pass_yd': 0.04,
        'pass_td': 4,
        'bonus_pass_yd_300': 3,
        'pass_int': -2,
        'rush_yd': 0.1,
        'rush_td': 6,
        'rec': 0.5,
        'rec_yd': 0.1,
        'rec_td': 6,
        'fum_lost': -2,
        'pass_2pt': 2,
        'fgm_40_49': 4,
        'xpm': 1,
        'sack': 1,
        'int': 2,
        'def_td': 6,
        'pts_allow_7_13': 4,
      },
    );

    expect(result, 68.5);
  });

  test(
    'API client uses verified player projection route and raw shape',
    () async {
      late Uri requested;
      final client = SleeperApiClient(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode({
              'category': 'player',
              'company': 'sleeper',
              'date': '2026-09-20',
              'game_id': '2026092000',
              'last_modified': 1789900000000,
              'opponent': 'MIA',
              'player_id': '4881',
              'season': '2026',
              'season_type': 'regular',
              'sport': 'nfl',
              'stats': {
                'pass_yd': 251.75,
                'pass_td': 1.8,
                'rush_yd': 42.25,
                'pts_ppr': 21.4,
              },
              'status': 'active',
              'team': 'BUF',
              'updated_at': 1789900000000,
              'week': 3,
              'week_shard': 3,
            }),
            200,
          );
        }),
      );

      final result = await client.fetchNflPlayerProjection(
        playerId: '4881',
        season: '2026',
        week: 3,
        seasonType: 'regular',
      );

      expect(requested.scheme, 'https');
      expect(requested.host, 'api.sleeper.com');
      expect(requested.path, '/projections/nfl/player/4881');
      expect(requested.queryParameters, {
        'season': '2026',
        'season_type': 'regular',
        'week': '3',
      });
      expect(result?.playerId, '4881');
      expect(result?.team, 'BUF');
      expect(result?.gameDate, DateTime(2026, 9, 20));
      expect(result?.stats['pass_yd'], 251.75);
    },
  );

  test(
    'existing scoreboard status maps only explicit FINAL to final',
    () async {
      final source = _SportsSource();
      final statusSource = SportsRepositorySleeperNflGameStatusSource(
        SportsRepository(source),
        now: () => DateTime(2026, 9, 20, 12),
      );

      final first = await statusSource.statusesForDates([
        DateTime(2026, 9, 20),
      ]);
      final second = await statusSource.statusesForDates([
        DateTime(2026, 9, 20),
      ]);

      expect(first['BUF'], SleeperNflGamePhase.finalStatus);
      expect(first['MIA'], SleeperNflGamePhase.finalStatus);
      expect(first['KC'], SleeperNflGamePhase.live);
      expect(first['JAX'], SleeperNflGamePhase.live);
      expect(first['DAL'], SleeperNflGamePhase.upcoming);
      expect(first['NYG'], SleeperNflGamePhase.upcoming);
      expect(second, first);
      expect(source.calls, 1);
    },
  );
}

const _normal2026Scoring = <String, double>{
  'sack': 1,
  'fgm_40_49': 4,
  'pass_int': -1,
  'pts_allow_0': 10,
  'pass_2pt': 2,
  'st_td': 6,
  'rec_td': 6,
  'fgm_30_39': 3,
  'xpmiss': -1,
  'rush_td': 6,
  'rec_2pt': 2,
  'st_fum_rec': 1,
  'fgmiss': -1,
  'ff': 1,
  'rec': 1,
  'pts_allow_14_20': 1,
  'fgm_0_19': 3,
  'int': 2,
  'def_st_fum_rec': 1,
  'fum_lost': -2,
  'pts_allow_1_6': 7,
  'fgm_20_29': 3,
  'xpm': 1,
  'rush_2pt': 2,
  'fum_rec': 2,
  'def_st_td': 6,
  'fgm_50_59': 5,
  'fgm_60p': 6,
  'def_td': 6,
  'safe': 2,
  'pass_yd': 0.04,
  'blk_kick': 2,
  'pass_td': 4,
  'rush_yd': 0.1,
  'fum': -1,
  'pts_allow_28_34': -1,
  'pts_allow_35p': -4,
  'fum_rec_td': 6,
  'rec_yd': 0.1,
  'def_st_ff': 1,
  'pts_allow_7_13': 4,
  'st_ff': 1,
};

const _physicalIdpScoring = <String, double>{
  'sack': 1,
  'fgm_40_49': 4,
  'pass_int': -1,
  'pts_allow_0': 10,
  'pass_2pt': 2,
  'st_td': 6,
  'rec_td': 6,
  'idp_blk_kick': 3,
  'fgm_30_39': 3,
  'fgm_50_59': 5,
  'xpmiss': -1,
  'rush_td': 6,
  'rec_2pt': 2,
  'idp_tkl_loss': 2,
  'idp_tkl_solo': 2,
  'st_fum_rec': 1,
  'fgmiss': -1,
  'ff': 1,
  'idp_int': 6,
  'rec': 1,
  'idp_safe': 3,
  'pts_allow_14_20': 1,
  'fgm_0_19': 3,
  'idp_def_td': 6,
  'int': 2,
  'def_st_fum_rec': 1,
  'fum_lost': -2,
  'pts_allow_1_6': 7,
  'fgm_60p': 6,
  'idp_sack': 6,
  'fgm_20_29': 3,
  'xpm': 1,
  'rush_2pt': 2,
  'fum_rec': 2,
  'idp_pass_def': 3,
  'def_st_td': 6,
  'def_td': 6,
  'idp_fum_rec': 3,
  'safe': 2,
  'pass_yd': 0.04,
  'blk_kick': 2,
  'pass_td': 4,
  'idp_qb_hit': 1,
  'rush_yd': 0.1,
  'pts_allow_28_34': -1,
  'pts_allow_35p': -4,
  'fum_rec_td': 6,
  'rec_yd': 0.1,
  'def_st_ff': 1,
  'pts_allow_7_13': 4,
  'idp_ff': 3,
  'st_ff': 1,
  'idp_tkl_ast': 1,
};

SleeperFantasyMatchup _physicalIdpMatchup() {
  const teamStarters = [
    '7523',
    '4034',
    '7588',
    '6786',
    '11632',
    '1466',
    '4199',
    '11834',
    '11533',
    '7627',
    '5332',
    '8330',
  ];
  const opponentStarters = [
    '5870',
    '9226',
    '5892',
    '8144',
    '7525',
    '5001',
    '12481',
    '7594',
    '13545',
    '8289',
    '11687',
    '11678',
  ];
  return SleeperFantasyMatchup(
    league: const SleeperLeague(
      leagueId: '1312092721397133312',
      name: 'Physical IDP League',
      season: '2026',
      status: 'in_season',
      scoringSettings: _physicalIdpScoring,
      rosterPositions: [
        'QB',
        'RB',
        'RB',
        'WR',
        'WR',
        'TE',
        'FLEX',
        'FLEX',
        'K',
        'DL',
        'LB',
        'DB',
      ],
    ),
    week: 3,
    team: SleeperFantasyTeam(
      roster: const SleeperRoster(
        rosterId: 5,
        ownerId: 'home',
        players: teamStarters,
        starters: teamStarters,
      ),
      user: const SleeperUser(userId: 'home', displayName: 'Home'),
      matchup: const SleeperMatchup(
        rosterId: 5,
        matchupId: 2,
        points: 0,
        starters: teamStarters,
        playerPoints: {},
      ),
    ),
    opponent: SleeperFantasyTeam(
      roster: const SleeperRoster(
        rosterId: 8,
        ownerId: 'away',
        players: opponentStarters,
        starters: opponentStarters,
      ),
      user: const SleeperUser(userId: 'away', displayName: 'Away'),
      matchup: const SleeperMatchup(
        rosterId: 8,
        matchupId: 2,
        points: 0,
        starters: opponentStarters,
        playerPoints: {},
      ),
    ),
  );
}

Future<SleeperFantasyMatchup> _capture(
  SleeperSettlingProjectionService service,
  SleeperFantasyMatchup matchup,
) async {
  await service.refresh(matchup);
  return service.applyCached(matchup);
}

SleeperSettlingProjectionService _service({
  required _MemoryBaselineStore store,
  required _ProjectionSource source,
  required _StatusSource statuses,
  required Map<String, SleeperFantasyPlayer> metadata,
  void Function(String message)? onDiagnostic,
}) => SleeperSettlingProjectionService(
  projectionSource: source,
  metadataResolver: (ids) async => {
    for (final id in ids)
      if (metadata[id] != null) id: metadata[id]!,
  },
  gameStatusSource: statuses,
  baselineStore: store,
  projectionRetryInterval: Duration.zero,
  onDiagnostic: onDiagnostic,
);

void _addPlayer(
  _ProjectionSource source,
  Map<String, SleeperFantasyPlayer> metadata,
  String id,
  String team,
  Map<String, double> stats, {
  String? position,
  int week = 1,
}) {
  final resolvedPosition =
      position ??
      (stats.keys.any((key) => key.startsWith('pass_')) ? 'QB' : 'RB');
  source.projections[id] = _projection(id, team, stats, week: week);
  metadata[id] = _player(id, team, position: resolvedPosition);
}

SleeperPlayerProjection _projection(
  String id,
  String team,
  Map<String, double> stats, {
  int week = 1,
}) => SleeperPlayerProjection(
  playerId: id,
  season: '2026',
  week: week,
  seasonType: 'regular',
  team: team,
  gameId: 'game-$team',
  gameDate: DateTime(2026, 9, 20),
  stats: stats,
);

SleeperFantasyPlayer _player(
  String id,
  String team, {
  String position = 'RB',
}) => SleeperFantasyPlayer(
  sleeperPlayerId: id,
  fullName: id,
  firstName: id,
  lastName: '',
  position: position,
  nflTeam: team,
  espnPlayerId: null,
);

SleeperFantasyMatchup _matchup({
  String leagueId = 'league',
  int week = 1,
  required List<String> starters,
  List<String> bench = const [],
  required Map<String, double> scoring,
  Map<String, double> actual = const {},
  double? actualTotal,
}) => SleeperFantasyMatchup(
  league: SleeperLeague(
    leagueId: leagueId,
    name: 'League $leagueId',
    season: '2026',
    status: 'in_season',
    scoringSettings: scoring,
    rosterPositions: const [],
  ),
  week: week,
  team: SleeperFantasyTeam(
    roster: SleeperRoster(
      rosterId: 1,
      ownerId: 'home',
      players: [...starters, ...bench],
      starters: starters,
    ),
    user: const SleeperUser(userId: 'home', displayName: 'Home'),
    matchup: SleeperMatchup(
      rosterId: 1,
      matchupId: 1,
      points: actualTotal ?? actual.values.fold(0, (sum, value) => sum + value),
      starters: starters,
      playerPoints: actual,
    ),
  ),
  opponent: const SleeperFantasyTeam(
    roster: SleeperRoster(
      rosterId: 2,
      ownerId: 'away',
      players: ['opponent'],
      starters: ['opponent'],
    ),
    user: SleeperUser(userId: 'away', displayName: 'Away'),
    matchup: SleeperMatchup(
      rosterId: 2,
      matchupId: 1,
      points: 0,
      starters: ['opponent'],
      playerPoints: {'opponent': 0},
    ),
  ),
);

class _ProjectionSource implements SleeperProjectionSource {
  final projections = <String, SleeperPlayerProjection>{};
  final calls = <String, int>{};
  bool fail = false;
  Completer<void>? started;
  Completer<void>? gate;

  @override
  Future<SleeperPlayerProjection?> fetchPlayerProjection({
    required String playerId,
    required String season,
    required int week,
    required String seasonType,
  }) async {
    calls.update(playerId, (value) => value + 1, ifAbsent: () => 1);
    if (started case final completer?) {
      if (!completer.isCompleted) completer.complete();
    }
    if (gate case final completer?) await completer.future;
    if (fail) throw StateError('projection unavailable');
    return projections[playerId];
  }
}

class _StatusSource implements SleeperNflGameStatusSource {
  final values = <String, SleeperNflGamePhase>{};

  @override
  Future<Map<String, SleeperNflGamePhase>> statusesForDates(
    Iterable<DateTime> dates,
  ) async => dates.isEmpty ? const {} : Map.unmodifiable(values);
}

class _MemoryBaselineStore implements SleeperProjectionBaselineStore {
  SleeperProjectionBaselineSnapshot? snapshot;
  bool failWrites = false;

  @override
  Future<SleeperProjectionBaselineSnapshot?> read() async => snapshot;

  @override
  Future<void> write(SleeperProjectionBaselineSnapshot value) async {
    if (failWrites) throw StateError('disk unavailable');
    snapshot = SleeperProjectionBaselineSnapshot(
      season: value.season,
      seasonType: value.seasonType,
      week: value.week,
      leagues: {
        for (final league in value.leagues.entries)
          league.key: SleeperLeagueProjectionBaselines(
            scoringSignature: league.value.scoringSignature,
            players: Map.of(league.value.players),
          ),
      },
    );
  }
}

class _SportsSource implements SportsDataSource {
  int calls = 0;

  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  ) async {
    calls++;
    return const [
      SportsGame(
        league: 'NFL',
        awayTeam: 'Buffalo Bills',
        homeTeam: 'Miami Dolphins',
        awayTeamKey: 'BUF',
        homeTeamKey: 'MIA',
        awayScore: 20,
        homeScore: 17,
        status: 'FINAL',
        clock: '0:00',
      ),
      SportsGame(
        league: 'NFL',
        awayTeam: 'Kansas City Chiefs',
        homeTeam: 'Jacksonville Jaguars',
        awayTeamKey: 'KC',
        homeTeamKey: 'JAX',
        awayScore: 7,
        homeScore: 3,
        status: 'LIVE',
        clock: '8:00',
      ),
      SportsGame(
        league: 'NFL',
        awayTeam: 'Dallas Cowboys',
        homeTeam: 'New York Giants',
        awayTeamKey: 'DAL',
        homeTeamKey: 'NYG',
        awayScore: 0,
        homeScore: 0,
        status: 'DELAYED',
        clock: '',
      ),
    ];
  }
}
