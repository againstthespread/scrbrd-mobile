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
import 'package:sports_hub_mobile/sports_operation_gate.dart';
import 'package:sports_hub_mobile/sports_repository.dart';
import 'package:sports_hub_mobile/tracked_device_session.dart';

void main() {
  for (final league in [SportsLeague.nfl, SportsLeague.nba, SportsLeague.mlb]) {
    test('${league.label} shrink requires two matching observations', () async {
      final tracked = [
        _game(league.label, 'A', 1),
        _game(league.label, 'B', 1),
      ];
      final fresh = [_game(league.label, 'A', 2)];
      final source = _Source({league: fresh});
      final session = TrackedDeviceSession()
        ..recordTeamSlate(league: league, selectedDate: _date, games: tracked);
      final transport = _Transport();
      final diagnostics = <String>[];
      final coordinator = _coordinator(
        source,
        _GolfSource(_golf('-1')),
        session,
        transport,
        diagnostics: diagnostics.add,
      );

      await coordinator.refreshTrackedSessionOnce();
      expect(transport.slates, isEmpty);
      expect((session[league] as TrackedTeamSlate).games, hasLength(2));

      await coordinator.refreshTrackedSessionOnce();
      expect(transport.slates.single, hasLength(1));
      expect((session[league] as TrackedTeamSlate).games, hasLength(1));
      expect(
        diagnostics,
        contains(contains('missingEventIds=[B]; confirmation required')),
      );
      expect(
        diagnostics,
        contains(contains('missingEventIds=[B]; transfer permitted')),
      );
    });
  }

  test('added event sends immediately without confirmation', () async {
    final source = _Source({
      SportsLeague.mlb: [_game('MLB', 'A', 1), _game('MLB', 'B', 1)],
    });
    final transport = _Transport();

    await _coordinator(
      source,
      _GolfSource(_golf('-1')),
      _teamSession(SportsLeague.mlb, [_game('MLB', 'A', 1)]),
      transport,
    ).refreshTrackedSessionOnce();

    expect(transport.slates.single, hasLength(2));
  });

  test('returned missing event clears shrink candidate', () async {
    final full = [
      _game('MLB', 'A', 1),
      _game('MLB', 'B', 1),
      _game('MLB', 'C', 1),
    ];
    final source = _Source({SportsLeague.mlb: full.take(2).toList()});
    final transport = _Transport();
    final coordinator = _coordinator(
      source,
      _GolfSource(_golf('-1')),
      _teamSession(SportsLeague.mlb, full),
      transport,
    );

    await coordinator.refreshTrackedSessionOnce();
    source.responses[SportsLeague.mlb] = full;
    await coordinator.refreshTrackedSessionOnce();
    source.responses[SportsLeague.mlb] = full.take(2).toList();
    await coordinator.refreshTrackedSessionOnce();

    expect(transport.slates, isEmpty);
  });

  test('changed missing set requires a new confirmation', () async {
    final full = ['A', 'B', 'C', 'D'].map((id) => _game('MLB', id, 1)).toList();
    final source = _Source({SportsLeague.mlb: full.take(3).toList()});
    final transport = _Transport();
    final coordinator = _coordinator(
      source,
      _GolfSource(_golf('-1')),
      _teamSession(SportsLeague.mlb, full),
      transport,
    );

    await coordinator.refreshTrackedSessionOnce(); // Missing D.
    source.responses[SportsLeague.mlb] = [full[0], full[1], full[3]];
    await coordinator.refreshTrackedSessionOnce(); // Missing C.
    expect(transport.slates, isEmpty);
    await coordinator.refreshTrackedSessionOnce(); // Missing C again.

    expect(transport.slates, hasLength(1));
  });

  test('multiple missing IDs compare as an order-independent set', () async {
    final full = [
      'A',
      'B',
      'C',
      'D',
      'E',
    ].map((id) => _game('MLB', id, 1)).toList();
    final source = _Source({
      SportsLeague.mlb: [full[0], full[1], full[2]],
    });
    final transport = _Transport();
    final coordinator = _coordinator(
      source,
      _GolfSource(_golf('-1')),
      _teamSession(SportsLeague.mlb, full),
      transport,
    );

    await coordinator.refreshTrackedSessionOnce();
    source.responses[SportsLeague.mlb] = [full[2], full[0], full[1]];
    await coordinator.refreshTrackedSessionOnce();

    expect(transport.slates.single, hasLength(3));
  });

  test(
    'fetch exception and empty response are not confirmation evidence',
    () async {
      final full = [_game('MLB', 'A', 1), _game('MLB', 'B', 1)];
      final source = _Source({
        SportsLeague.mlb: [full.first],
      });
      final transport = _Transport();
      final coordinator = _coordinator(
        source,
        _GolfSource(_golf('-1')),
        _teamSession(SportsLeague.mlb, full),
        transport,
      );

      await coordinator.refreshTrackedSessionOnce();
      source.failures.add(SportsLeague.mlb);
      await coordinator.refreshTrackedSessionOnce();
      source.failures.clear();
      source.responses[SportsLeague.mlb] = const [];
      await coordinator.refreshTrackedSessionOnce();
      expect(transport.slates, isEmpty);

      source.responses[SportsLeague.mlb] = [full.first];
      await coordinator.refreshTrackedSessionOnce();
      expect(transport.slates, hasLength(1));
    },
  );

  test(
    'failed confirmed shrink retains baseline and retries next WAKE',
    () async {
      final full = [_game('MLB', 'A', 1), _game('MLB', 'B', 1)];
      final source = _Source({
        SportsLeague.mlb: [full.first],
      });
      final session = _teamSession(SportsLeague.mlb, full);
      final transport = _Transport();
      final coordinator = _coordinator(
        source,
        _GolfSource(_golf('-1')),
        session,
        transport,
      );

      await coordinator.refreshTrackedSessionOnce();
      transport.failNextSlate = true;
      await coordinator.refreshTrackedSessionOnce();
      expect(
        (session[SportsLeague.mlb] as TrackedTeamSlate).games,
        hasLength(2),
      );
      await coordinator.refreshTrackedSessionOnce();

      expect(transport.slates, hasLength(1));
      expect(
        (session[SportsLeague.mlb] as TrackedTeamSlate).games,
        hasLength(1),
      );
    },
  );

  test('shrink candidates are isolated per team league', () async {
    final nfl = [_game('NFL', 'N1', 1), _game('NFL', 'N2', 1)];
    final mlb = [_game('MLB', 'M1', 1), _game('MLB', 'M2', 1)];
    final session = TrackedDeviceSession()
      ..recordTeamSlate(
        league: SportsLeague.nfl,
        selectedDate: _date,
        games: nfl,
      )
      ..recordTeamSlate(
        league: SportsLeague.mlb,
        selectedDate: _date,
        games: mlb,
      );
    final source = _Source({
      SportsLeague.nfl: [nfl.first],
      SportsLeague.mlb: [mlb.first],
    });
    final transport = _Transport();
    final coordinator = _coordinator(
      source,
      _GolfSource(_golf('-1')),
      session,
      transport,
    );

    await coordinator.refreshTrackedSessionOnce();
    source.responses[SportsLeague.nfl] = nfl;
    await coordinator.refreshTrackedSessionOnce();

    expect(transport.slates.single.single.league, 'MLB');
    expect((session[SportsLeague.nfl] as TrackedTeamSlate).games, hasLength(2));
    expect((session[SportsLeague.mlb] as TrackedTeamSlate).games, hasLength(1));
  });

  test('PGA membership change remains immediate', () async {
    final tracked = GolfLeaderboard(
      tournamentId: 'pga-1',
      tournamentName: 'Open',
      golfers: [_golfer('1'), _golfer('2')],
      isInProgress: true,
      isOver: false,
    );
    final fresh = GolfLeaderboard(
      tournamentId: 'pga-1',
      tournamentName: 'Open',
      golfers: [_golfer('1')],
      isInProgress: true,
      isOver: false,
    );
    final session = TrackedDeviceSession()..recordGolf(tracked);
    final transport = _Transport();

    await _coordinator(
      _Source(const {}),
      _GolfSource(fresh),
      session,
      transport,
    ).refreshTrackedSessionOnce();

    expect(transport.golf, hasLength(1));
  });

  test('coalesced WAKE can provide the second shrink confirmation', () async {
    final pending = Completer<List<GameData>>();
    final source = _Source({})..pending = pending;
    final transport = _Transport();
    final coordinator = _coordinator(
      source,
      _GolfSource(_golf('-1')),
      _teamSession(SportsLeague.mlb, [
        _game('MLB', 'A', 1),
        _game('MLB', 'B', 1),
      ]),
      transport,
    );
    final gate = SportsOperationGate();

    final drain = gate.requestLiveRefresh(
      coordinator.refreshTrackedSessionOnce,
    );
    await Future<void>.delayed(Duration.zero);
    await gate.requestLiveRefresh(coordinator.refreshTrackedSessionOnce);
    pending.complete([_game('MLB', 'A', 1)]);
    await drain;

    expect(source.requested, [SportsLeague.mlb, SportsLeague.mlb]);
    expect(transport.slates, hasLength(1));
  });

  test(
    'cancellation and a new coordinator start without stale candidate',
    () async {
      final full = [_game('MLB', 'A', 1), _game('MLB', 'B', 1)];
      final source = _Source({
        SportsLeague.mlb: [full.first],
      });
      final session = _teamSession(SportsLeague.mlb, full);
      final transport = _Transport();
      final firstCoordinator = _coordinator(
        source,
        _GolfSource(_golf('-1')),
        session,
        transport,
      );

      await firstCoordinator.refreshTrackedSessionOnce();
      firstCoordinator.cancelCurrentRefresh('BLE disconnected');
      await firstCoordinator.refreshTrackedSessionOnce();
      expect(transport.slates, isEmpty);

      final newCoordinator = _coordinator(
        source,
        _GolfSource(_golf('-1')),
        session,
        transport,
      );
      await newCoordinator.refreshTrackedSessionOnce();
      expect(transport.slates, isEmpty);
    },
  );

  test(
    'unusable stable identity cannot authorize destructive shrinkage',
    () async {
      final trackedWithoutId = GameData(
        league: 'MLB',
        awayTeam: 'A',
        homeTeam: 'H',
        awayScore: 1,
        homeScore: 0,
        status: 'LIVE',
        clock: 'Top 5th',
        scheduledStartTime: _date,
      );
      final source = _Source({
        SportsLeague.mlb: [_game('MLB', 'A', 1)],
      });
      final transport = _Transport();
      final coordinator = _coordinator(
        source,
        _GolfSource(_golf('-1')),
        _teamSession(SportsLeague.mlb, [
          trackedWithoutId,
          _game('MLB', 'A', 1),
        ]),
        transport,
      );

      await coordinator.refreshTrackedSessionOnce();
      await coordinator.refreshTrackedSessionOnce();

      expect(transport.slates, isEmpty);
    },
  );

  test('all tracked league fetches start concurrently', () async {
    final teamCompleters = {
      for (final league in [
        SportsLeague.nfl,
        SportsLeague.nba,
        SportsLeague.mlb,
      ])
        league: Completer<List<SportsGame>>(),
    };
    final golfCompleter = Completer<GolfLeaderboard>();
    final source = _ConcurrentSource({
      for (final entry in teamCompleters.entries) entry.key: entry.value.future,
    });
    final golf = _ConcurrentGolfSource(golfCompleter.future);
    final session = _allLeagueSession();

    final refresh = LiveRefreshCoordinator(
      repository: SportsRepository(source, golfDataSource: golf),
      transport: _Transport(),
      session: session,
      isBleConnected: () => true,
    ).refreshTrackedSessionOnce();
    await Future<void>.delayed(Duration.zero);

    expect(source.started, [
      SportsLeague.nfl,
      SportsLeague.nba,
      SportsLeague.mlb,
    ]);
    expect(golf.started, isTrue);

    for (final entry in teamCompleters.entries) {
      entry.value.complete([_sportsGameFrom(_game(entry.key.label, '1', 1))]);
    }
    golfCompleter.complete(_golf('-1'));
    await refresh;
  });

  test('one failed fetch does not prevent changed MLB and PGA sends', () async {
    final source = _ConcurrentSource({
      SportsLeague.nfl: Future<List<SportsGame>>.error(
        StateError('NFL unavailable'),
      ),
      SportsLeague.mlb: Future.value([_sportsGameFrom(_game('MLB', '1', 2))]),
    });
    final transport = _Transport();
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
      )
      ..recordGolf(_golf('-1'));

    await LiveRefreshCoordinator(
      repository: SportsRepository(
        source,
        golfDataSource: _ConcurrentGolfSource(Future.value(_golf('-2'))),
      ),
      transport: transport,
      session: session,
      isBleConnected: () => true,
    ).refreshTrackedSessionOnce();

    expect(transport.slates.single.single.league, 'MLB');
    expect(transport.golf, hasLength(1));
    expect(
      (session[SportsLeague.nfl] as TrackedTeamSlate).games.single.awayScore,
      1,
    );
  });

  test('MLB fetch failure does not prevent changed PGA send', () async {
    final transport = _Transport();
    final session = TrackedDeviceSession()
      ..recordTeamSlate(
        league: SportsLeague.mlb,
        selectedDate: _date,
        games: [_game('MLB', '1', 1)],
      )
      ..recordGolf(_golf('-1'));

    await LiveRefreshCoordinator(
      repository: SportsRepository(
        _ConcurrentSource({
          SportsLeague.mlb: Future<List<SportsGame>>.error(
            StateError('MLB unavailable'),
          ),
        }),
        golfDataSource: _ConcurrentGolfSource(Future.value(_golf('-2'))),
      ),
      transport: transport,
      session: session,
      isBleConnected: () => true,
    ).refreshTrackedSessionOnce();

    expect(transport.slates, isEmpty);
    expect(transport.golf, hasLength(1));
    expect(
      (session[SportsLeague.mlb] as TrackedTeamSlate).games.single.awayScore,
      1,
    );
  });

  test('changed league BLE sends are sequential and ordered', () async {
    final source = _ConcurrentSource({
      for (final league in [
        SportsLeague.nfl,
        SportsLeague.nba,
        SportsLeague.mlb,
      ])
        league: Future.value([_sportsGameFrom(_game(league.label, '1', 2))]),
    });
    final transport = _BlockingTransport();
    final refresh = LiveRefreshCoordinator(
      repository: SportsRepository(
        source,
        golfDataSource: _ConcurrentGolfSource(Future.value(_golf('-2'))),
      ),
      transport: transport,
      session: _allLeagueSession(),
      isBleConnected: () => true,
    ).refreshTrackedSessionOnce();

    await Future<void>.delayed(Duration.zero);
    expect(transport.started, ['NFL']);
    transport.releaseNext();
    await Future<void>.delayed(Duration.zero);
    expect(transport.started, ['NFL', 'NBA']);
    transport.releaseNext();
    await Future<void>.delayed(Duration.zero);
    expect(transport.started, ['NFL', 'NBA', 'MLB']);
    transport.releaseNext();
    await Future<void>.delayed(Duration.zero);
    expect(transport.started, ['NFL', 'NBA', 'MLB', 'PGA']);
    transport.releaseNext();
    await refresh;

    expect(transport.maximumConcurrentSends, 1);
  });

  test(
    'failed send retains that baseline and later league still advances',
    () async {
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
      final transport = _FailingTransport('NFL');
      await LiveRefreshCoordinator(
        repository: SportsRepository(
          _ConcurrentSource({
            SportsLeague.nfl: Future.value([
              _sportsGameFrom(_game('NFL', '1', 2)),
            ]),
            SportsLeague.mlb: Future.value([
              _sportsGameFrom(_game('MLB', '1', 2)),
            ]),
          }),
        ),
        transport: transport,
        session: session,
        isBleConnected: () => true,
      ).refreshTrackedSessionOnce();

      expect(
        (session[SportsLeague.nfl] as TrackedTeamSlate).games.single.awayScore,
        1,
      );
      expect(
        (session[SportsLeague.mlb] as TrackedTeamSlate).games.single.awayScore,
        2,
      );
      expect(transport.attempted, ['NFL', 'MLB']);
    },
  );

  test('later league comparison uses the original stable snapshot', () async {
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
    final transport = _MutatingTransport(session);

    await LiveRefreshCoordinator(
      repository: SportsRepository(
        _ConcurrentSource({
          SportsLeague.nfl: Future.value([
            _sportsGameFrom(_game('NFL', '1', 2)),
          ]),
          SportsLeague.mlb: Future.value([
            _sportsGameFrom(_game('MLB', '1', 2)),
          ]),
        }),
      ),
      transport: transport,
      session: session,
      isBleConnected: () => true,
    ).refreshTrackedSessionOnce();

    expect(transport.attempted, ['NFL', 'MLB']);
  });

  test('disconnect after first send suppresses remaining sends', () async {
    var connected = true;
    final transport = _DisconnectingTransport(() => connected = false);
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
    await LiveRefreshCoordinator(
      repository: SportsRepository(
        _ConcurrentSource({
          SportsLeague.nfl: Future.value([
            _sportsGameFrom(_game('NFL', '1', 2)),
          ]),
          SportsLeague.mlb: Future.value([
            _sportsGameFrom(_game('MLB', '1', 2)),
          ]),
        }),
      ),
      transport: transport,
      session: session,
      isBleConnected: () => connected,
    ).refreshTrackedSessionOnce();

    expect(transport.attempted, ['NFL']);
    expect(
      (session[SportsLeague.nfl] as TrackedTeamSlate).games.single.awayScore,
      2,
    );
    expect(
      (session[SportsLeague.mlb] as TrackedTeamSlate).games.single.awayScore,
      1,
    );
  });

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

  for (final scenario in [
    'foreground with BLE connected',
    'background with BLE connected and no Live Activity',
    'background with BLE connected and Live Activity active',
  ]) {
    test('$scenario permits refresh', () async {
      final source = _Source({
        SportsLeague.mlb: [_game('MLB', '1', 2)],
      });
      final transport = _Transport();

      await _coordinator(
        source,
        _GolfSource(_golf('-1')),
        _session(teamScore: 1, golfScore: null),
        transport,
      ).refreshTrackedSessionOnce();

      expect(transport.slates, hasLength(1));
    });
  }

  test('BLE disconnected denies refresh', () async {
    final source = _Source({
      SportsLeague.mlb: [_game('MLB', '1', 2)],
    });
    final transport = _Transport();

    await _coordinator(
      source,
      _GolfSource(_golf('-1')),
      _session(teamScore: 1, golfScore: null),
      transport,
      isConnected: () => false,
    ).refreshTrackedSessionOnce();

    expect(source.requested, isEmpty);
    expect(transport.slates, isEmpty);
  });

  test('BLE disconnect during refresh cancels subsequent work', () async {
    final pending = Completer<List<GameData>>();
    final source = _Source({})..pending = pending;
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
    var connected = true;
    final transport = _Transport();
    final refresh = _coordinator(
      source,
      _GolfSource(_golf('-1')),
      session,
      transport,
      isConnected: () => connected,
    ).refreshTrackedSessionOnce();
    await Future<void>.delayed(Duration.zero);
    connected = false;
    pending.complete([_game('NFL', '1', 2)]);
    await refresh;

    expect(source.requested, [SportsLeague.nfl, SportsLeague.mlb]);
    expect(transport.slates, isEmpty);
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

  test('NFL football state change sends one complete slate', () async {
    final old = _nfl(down: 1, distance: 10);
    final fresh = _nfl(down: 2, distance: 7);
    final session = TrackedDeviceSession()
      ..recordTeamSlate(
        league: SportsLeague.nfl,
        selectedDate: _date,
        games: [old],
      )
      ..recordGolf(_golf('-1'));
    final transport = _Transport();
    await _coordinator(
      _Source({
        SportsLeague.nfl: [fresh],
      }),
      _GolfSource(_golf('-1')),
      session,
      transport,
    ).refreshTrackedSessionOnce();
    expect(transport.slates, hasLength(1));
    expect(transport.slates.single.single.footballState?.down, 2);
    expect(session[SportsLeague.pga], isA<TrackedGolfLeaderboard>());
  });

  test('unchanged NFL football state sends no slate', () async {
    final game = _nfl(down: 3, distance: 1);
    final session = TrackedDeviceSession()
      ..recordTeamSlate(
        league: SportsLeague.nfl,
        selectedDate: _date,
        games: [game],
      );
    final transport = _Transport();
    await _coordinator(
      _Source({
        SportsLeague.nfl: [game],
      }),
      _GolfSource(_golf('-1')),
      session,
      transport,
    ).refreshTrackedSessionOnce();
    expect(transport.slates, isEmpty);
  });

  for (final change in [
    ('inning', _mlb(clock: 'Top 5th'), _mlb(clock: 'Bot 5th')),
    ('bases', _mlb(onFirst: false), _mlb(onFirst: true)),
    ('outs', _mlb(outs: 0), _mlb(outs: 1)),
  ]) {
    test('first WAKE detects MLB ${change.$1} change', () async {
      final session = TrackedDeviceSession()
        ..recordTeamSlate(
          league: SportsLeague.mlb,
          selectedDate: _date,
          games: [change.$2],
        );
      final transport = _Transport();

      await _coordinator(
        _Source({
          SportsLeague.mlb: [change.$3],
        }),
        _GolfSource(_golf('-1')),
        session,
        transport,
      ).refreshTrackedSessionOnce();

      expect(transport.slates, hasLength(1));
    });
  }

  test('first WAKE detects PGA THRU detail change', () async {
    final session = TrackedDeviceSession()
      ..recordGolf(_golf('-3', detail: 'THRU 7'));
    final transport = _Transport();

    await _coordinator(
      _Source(const {}),
      _GolfSource(_golf('-3', detail: 'THRU 8')),
      session,
      transport,
    ).refreshTrackedSessionOnce();

    expect(transport.golf, hasLength(1));
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

TrackedDeviceSession _allLeagueSession() {
  final session = TrackedDeviceSession();
  for (final league in [SportsLeague.nfl, SportsLeague.nba, SportsLeague.mlb]) {
    session.recordTeamSlate(
      league: league,
      selectedDate: _date,
      games: [_game(league.label, '1', 1)],
    );
  }
  session.recordGolf(_golf('-1'));
  return session;
}

TrackedDeviceSession _teamSession(SportsLeague league, List<GameData> games) =>
    TrackedDeviceSession()
      ..recordTeamSlate(league: league, selectedDate: _date, games: games);

LiveRefreshCoordinator _coordinator(
  _Source source,
  _GolfSource golf,
  TrackedDeviceSession session,
  _Transport transport, {
  bool Function()? isConnected,
  void Function(String)? diagnostics,
}) => LiveRefreshCoordinator(
  repository: SportsRepository(source, golfDataSource: golf),
  transport: transport,
  session: session,
  isBleConnected: isConnected ?? () => true,
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

SportsGame _sportsGameFrom(GameData game) => SportsGame(
  eventId: game.eventId,
  league: game.league,
  awayTeam: game.awayTeam,
  homeTeam: game.homeTeam,
  awayScore: game.awayScore,
  homeScore: game.homeScore,
  status: game.status,
  clock: game.clock,
  scheduledStartTime: game.scheduledStartTime,
  baseballState: game.baseballState,
  footballState: game.footballState,
);

GameData _nfl({required int down, required int distance}) => GameData(
  eventId: 'nfl-1',
  league: 'NFL',
  awayTeam: 'A',
  homeTeam: 'H',
  awayScore: 0,
  homeScore: 0,
  status: 'LIVE',
  clock: 'Q2 5:00',
  scheduledStartTime: _date,
  footballState: FootballGameState(
    possession: FootballPossession.away,
    down: down,
    distance: distance,
    isGoalToGo: distance == 0,
  ),
);

GameData _mlb({String clock = 'Top 5th', bool onFirst = false, int outs = 0}) =>
    GameData(
      eventId: 'mlb-state-1',
      league: 'MLB',
      awayTeam: 'A',
      homeTeam: 'H',
      awayScore: 1,
      homeScore: 0,
      status: 'LIVE',
      clock: clock,
      scheduledStartTime: _date,
      baseballState: BaseballGameState(
        runnerOnFirst: onFirst,
        runnerOnSecond: false,
        runnerOnThird: false,
        outs: outs,
      ),
    );

GolfLeaderboard _golf(String score, {String? detail}) => GolfLeaderboard(
  tournamentId: 'pga-1',
  tournamentName: 'Open',
  golfers: [
    GolfLeaderboardRow(
      playerId: '1',
      name: 'Player',
      rank: '1',
      score: score,
      detail: detail,
    ),
  ],
  isInProgress: true,
  isOver: false,
);

GolfLeaderboardRow _golfer(String id) => GolfLeaderboardRow(
  playerId: id,
  name: 'Player $id',
  rank: id,
  score: '-1',
  detail: 'THRU 5',
);

class _Source implements SportsDataSource {
  _Source(this.responses);
  final Map<SportsLeague, List<GameData>> responses;
  final requested = <SportsLeague>[];
  final failures = <SportsLeague>{};
  Completer<List<GameData>>? pending;
  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime date,
  ) async {
    requested.add(league);
    if (failures.contains(league)) throw StateError('${league.label} failed');
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
            footballState: g.footballState,
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

class _ConcurrentSource implements SportsDataSource {
  _ConcurrentSource(this.responses);

  final Map<SportsLeague, Future<List<SportsGame>>> responses;
  final started = <SportsLeague>[];

  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime date,
  ) {
    started.add(league);
    return responses[league] ?? Future.value(const []);
  }
}

class _ConcurrentGolfSource implements GolfDataSource {
  _ConcurrentGolfSource(this.response);

  final Future<GolfLeaderboard> response;
  bool started = false;

  @override
  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(String id) {
    started = true;
    return response;
  }

  @override
  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(DateTime date) async =>
      response;
}

class _Transport implements DeviceTransport {
  final slates = <List<GameData>>[];
  final golf = <GolfLeaderboard>[];
  bool failNextSlate = false;
  @override
  Future<void> sendControlCommand(String command) async {}
  @override
  Future<void> sendGameData(GameData gameData) async {}
  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    if (failNextSlate) {
      failNextSlate = false;
      throw StateError('slate failed');
    }
    slates.add(games);
  }

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async =>
      golf.add(leaderboard);
}

class _BlockingTransport implements DeviceTransport {
  final started = <String>[];
  Completer<void>? _release;
  var _activeSends = 0;
  var maximumConcurrentSends = 0;

  void releaseNext() => _release!.complete();

  Future<void> _send(String label) async {
    started.add(label);
    _activeSends++;
    if (_activeSends > maximumConcurrentSends) {
      maximumConcurrentSends = _activeSends;
    }
    final release = _release = Completer<void>();
    await release.future;
    _activeSends--;
  }

  @override
  Future<void> sendControlCommand(String command) async {}

  @override
  Future<void> sendGameData(GameData gameData) => _send(gameData.league);

  @override
  Future<void> sendGameSlate(List<GameData> games) => _send(games.first.league);

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) => _send('PGA');
}

class _FailingTransport implements DeviceTransport {
  _FailingTransport(this.failLeague);

  final String failLeague;
  final attempted = <String>[];

  @override
  Future<void> sendControlCommand(String command) async {}

  @override
  Future<void> sendGameData(GameData gameData) async {}

  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    final league = games.first.league;
    attempted.add(league);
    if (league == failLeague) throw StateError('$league transfer failed');
  }

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {}
}

class _DisconnectingTransport implements DeviceTransport {
  _DisconnectingTransport(this.onFirstSend);

  final void Function() onFirstSend;
  final attempted = <String>[];

  @override
  Future<void> sendControlCommand(String command) async {}

  @override
  Future<void> sendGameData(GameData gameData) async {}

  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    attempted.add(games.first.league);
    if (attempted.length == 1) onFirstSend();
  }

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {}
}

class _MutatingTransport implements DeviceTransport {
  _MutatingTransport(this.session);

  final TrackedDeviceSession session;
  final attempted = <String>[];

  @override
  Future<void> sendControlCommand(String command) async {}

  @override
  Future<void> sendGameData(GameData gameData) async {}

  @override
  Future<void> sendGameSlate(List<GameData> games) async {
    final league = games.first.league;
    attempted.add(league);
    if (league == 'NFL') {
      session.recordTeamSlate(
        league: SportsLeague.mlb,
        selectedDate: _date,
        games: [_game('MLB', '1', 2)],
      );
    }
  }

  @override
  Future<void> sendGolfLeaderboard(GolfLeaderboard leaderboard) async {}
}
