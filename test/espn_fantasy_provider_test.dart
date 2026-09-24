import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports_hub_mobile/espn_fantasy_client.dart';
import 'package:sports_hub_mobile/espn_fantasy_credentials.dart';
import 'package:sports_hub_mobile/espn_fantasy_repository.dart';
import 'package:sports_hub_mobile/fantasy_league_config.dart';
import 'package:sports_hub_mobile/fantasy_live_observation_coordinator.dart';
import 'package:sports_hub_mobile/fantasy_primary_league_store.dart';

const _credentials = EspnFantasyCredentials(
  swid: '{FAKE-SWID}',
  espnS2: 'fake-espn-s2',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('account-level secure credentials', () {
    late _SecureMemoryStorage secure;
    late SecureEspnFantasyCredentialsStore store;
    setUp(() {
      secure = _SecureMemoryStorage();
      store = SecureEspnFantasyCredentialsStore(storage: secure);
    });

    test('empty, save, read, update and clear', () async {
      expect(await store.read(), isNull);
      expect(await store.hasCredentials(), isFalse);
      await store.save(_credentials);
      expect((await store.read())!.swid, _credentials.swid);
      expect((await store.read())!.espnS2, _credentials.espnS2);
      expect(await store.hasCredentials(), isTrue);
      await store.save(
        const EspnFantasyCredentials(
          swid: '{NEW-FAKE-SWID}',
          espnS2: 'new-fake-s2',
        ),
      );
      expect((await store.read())!.swid, '{NEW-FAKE-SWID}');
      expect(secure.values.length, 1);
      await store.clear();
      expect(await store.read(), isNull);
      expect(await store.hasCredentials(), isFalse);
    });

    test('secrets never enter SharedPreferences', () async {
      await store.save(_credentials);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getKeys(), isEmpty);
      expect(secure.values.values.single, contains('fake-espn-s2'));
    });

    test('invalid cookies and storage errors never expose secrets', () async {
      final bad = const EspnFantasyCredentials(
        swid: 'secret;leak',
        espnS2: 'another-secret',
      );
      expect(bad.toString(), isNot(contains('secret')));
      await expectLater(
        store.save(bad),
        throwsA(isA<EspnCredentialsException>()),
      );
      secure.fail = true;
      try {
        await store.save(_credentials);
        fail('Expected save error');
      } on EspnCredentialsException catch (error) {
        expect(error.toString(), isNot(contains(_credentials.swid)));
        expect(error.toString(), isNot(contains(_credentials.espnS2)));
      }
      try {
        await store.read();
        fail('Expected read error');
      } on EspnCredentialsException catch (error) {
        expect(error.toString(), isNot(contains(_credentials.swid)));
      }
    });

    test(
      'malformed secure value fails safely without leaking content',
      () async {
        secure.values['espn_fantasy_credentials_v1'] = 'fake-espn-s2 {bad';
        await expectLater(
          store.read(),
          throwsA(
            predicate(
              (error) =>
                  error is EspnCredentialsException &&
                  !error.toString().contains('fake-espn-s2'),
            ),
          ),
        );
      },
    );
  });

  group('authenticated ESPN HTTP client', () {
    test('sends both cookies and period-specific box score request', () async {
      final seen = <http.Request>[];
      final client = _client((request) async {
        seen.add(request);
        return http.Response(jsonEncode(_leagueFixture()), 200);
      });
      await client.loadBoxScore(
        season: 2030,
        leagueId: '12345',
        scoringPeriod: 4,
        matchupPeriod: 3,
      );
      expect(seen.single.url.host, 'lm-api-reads.fantasy.espn.com');
      expect(
        seen.single.url.path,
        '/apis/v3/games/ffl/seasons/2030/segments/0/leagues/12345',
      );
      expect(seen.single.url.queryParametersAll['view'], [
        'mMatchupScore',
        'mScoreboard',
        'mLiveScoring',
      ]);
      expect(seen.single.url.queryParameters['scoringPeriodId'], '4');
      expect(
        seen.single.headers['cookie'],
        'SWID={FAKE-SWID}; espn_s2=fake-espn-s2',
      );
      expect(
        jsonDecode(
          seen.single.headers['x-fantasy-filter']!,
        )['schedule']['filterMatchupPeriodIds']['value'],
        [3],
      );
      client.close();
    });

    test('missing credentials prevent any HTTP request', () async {
      var calls = 0;
      final client = EspnFantasyClient(
        credentialsStore: _FakeCredentialsStore(),
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await _expectFailure(
        client.loadLeague(season: 2030, leagueId: '12345'),
        EspnFantasyFailure.missingCredentials,
      );
      expect(calls, 0);
    });

    for (final (code, failure) in [
      (401, EspnFantasyFailure.unauthorized),
      (403, EspnFantasyFailure.unauthorized),
      (404, EspnFantasyFailure.leagueUnavailable),
      (500, EspnFantasyFailure.network),
      (429, EspnFantasyFailure.network),
    ]) {
      test(
        'HTTP $code maps to $failure without response/cookie leakage',
        () async {
          final client = _client(
            (_) async => http.Response('fake-espn-s2 {FAKE-SWID}', code),
          );
          await _expectFailure(
            client.loadLeague(season: 2030, leagueId: '12345'),
            failure,
          );
        },
      );
    }

    test(
      'network exception and malformed JSON map to safe typed failures',
      () async {
        final broken = _client((_) async => throw StateError('fake-espn-s2'));
        await _expectFailure(
          broken.loadLeague(season: 2030, leagueId: '12345'),
          EspnFantasyFailure.network,
        );
        final malformed = _client(
          (_) async => http.Response('fake-espn-s2', 200),
        );
        await _expectFailure(
          malformed.loadLeague(season: 2030, leagueId: '12345'),
          EspnFantasyFailure.invalidResponse,
        );
      },
    );

    test('invalid league and season never reach the network', () async {
      var calls = 0;
      final client = _client((_) async {
        calls++;
        return http.Response('{}', 200);
      });
      await _expectFailure(
        client.loadLeague(season: 0, leagueId: '12345'),
        EspnFantasyFailure.invalidRequest,
      );
      await _expectFailure(
        client.loadLeague(season: 2030, leagueId: '../12345'),
        EspnFantasyFailure.invalidRequest,
      );
      await _expectFailure(
        client.loadLeague(season: 2030, leagueId: '-12345'),
        EspnFantasyFailure.invalidRequest,
      );
      expect(calls, 0);
    });
  });

  group('league and normalized current matchup', () {
    late Map<String, dynamic> league;
    late Map<String, dynamic> box;
    late EspnFantasyRepository repository;
    setUp(() {
      league = _leagueFixture();
      box = _boxFixture();
      repository = EspnFantasyRepository(
        _client((request) async {
          final views = request.url.queryParametersAll['view']!;
          return http.Response(
            jsonEncode(views.contains('mTeam') ? league : box),
            200,
          );
        }),
      );
    });

    test(
      'league exposes ID, name, season, scoring period and multiple named teams',
      () async {
        final result = await repository.loadLeague(
          season: 2030,
          leagueId: '12345',
        );
        expect(result.id, 'espn:12345');
        expect(result.name, 'Synthetic League');
        expect(result.season, 2030);
        expect(result.scoringPeriod, 4);
        expect(result.matchupPeriod, 3);
        expect(result.teams.map((t) => t.id), ['7', '8', '9']);
        expect(result.teams.map((t) => t.name), [
          'Alpha',
          'East Beta',
          'Team 9',
        ]);
      },
    );

    test('configured team and opponent resolve from current matchup', () async {
      final result = await repository.loadCurrentMatchup(
        season: 2030,
        leagueId: '12345',
        teamId: '7',
      );
      expect(result.id, 'espn:12345');
      expect(result.team.team.id, '7');
      expect(result.opponent!.team.id, '8');
      expect(result.team.totalPoints, 102.375);
      expect(result.opponent!.totalPoints, 97.125);
      expect(result.team.projectedTotalPoints, 126.7);
      expect(result.opponent!.projectedTotalPoints, 119.4);
      expect(result.scoringPeriod, 4);
      expect(result.matchupPeriod, 3);
    });

    test('missing ESPN projections remain unavailable', () async {
      final current = (box['schedule'] as List)[1] as Map<String, dynamic>;
      (current['home'] as Map).remove('totalProjectedPointsLive');
      (current['away'] as Map).remove('totalProjectedPointsLive');

      final result = await repository.loadCurrentMatchup(
        season: 2030,
        leagueId: '12345',
        teamId: '7',
      );

      expect(result.team.projectedTotalPoints, isNull);
      expect(result.opponent!.projectedTotalPoints, isNull);
      expect(result.team.totalPoints, 102.375);
      expect(result.opponent!.totalPoints, 97.125);
    });

    test('invalid ESPN projection metadata becomes unavailable', () async {
      final current = (box['schedule'] as List)[1] as Map<String, dynamic>;
      (current['home'] as Map)['totalProjectedPointsLive'] = 'not-a-number';

      final result = await repository.loadCurrentMatchup(
        season: 2030,
        leagueId: '12345',
        teamId: '7',
      );

      expect(result.team.projectedTotalPoints, isNull);
      expect(result.opponent!.projectedTotalPoints, 119.4);
      expect(result.team.totalPoints, 102.375);
    });

    test(
      'starters use athlete IDs and exact decimal current-period actual points',
      () async {
        final result = await repository.loadCurrentMatchup(
          season: 2030,
          leagueId: '12345',
          teamId: '7',
        );
        expect(result.team.starters.map((p) => p.id), ['101', '104']);
        expect(result.team.starters.first.name, 'Synthetic Quarterback');
        expect(result.team.starters.first.points, 12.345);
        expect(result.team.starters.last.points, 0);
        expect(result.opponent!.starters.single.id, '201');
        expect(result.opponent!.starters.single.points, 7.125);
      },
    );

    test('bench, IR and unassigned slots are excluded', () async {
      final result = await repository.loadCurrentMatchup(
        season: 2030,
        leagueId: '12345',
        teamId: '7',
      );
      expect(result.team.starters.map((p) => p.id), isNot(contains('102')));
      expect(result.team.starters.map((p) => p.id), isNot(contains('103')));
      expect(result.team.starters.map((p) => p.id), isNot(contains('105')));
    });

    test(
      'active negative D/ST ID remains signed with name and decimal points',
      () async {
        final entries = _homeEntries(box);
        entries.add(_entry(-16001, 16, 8.375, name: 'Synthetic Defense'));
        final result = await repository.loadCurrentMatchup(
          season: 2030,
          leagueId: '12345',
          teamId: '7',
        );
        expect(result.team.starters.map((p) => p.id), ['101', '104', '-16001']);
        final defense = result.team.starters.last;
        expect(defense.id, '-16001');
        expect(defense.name, 'Synthetic Defense');
        expect(defense.points, 8.375);
      },
    );

    test('bench negative D/ST ID is excluded by slot', () async {
      _homeEntries(box).add(_entry(-16001, 20, 8.375, name: 'Benched Defense'));
      final result = await repository.loadCurrentMatchup(
        season: 2030,
        leagueId: '12345',
        teamId: '7',
      );
      expect(result.team.starters.map((p) => p.id), isNot(contains('-16001')));
    });

    test(
      'duplicate negative starter IDs are rejected as one identity',
      () async {
        _homeEntries(box)
          ..add(_entry(-16001, 16, 8.375))
          ..add(_entry(-16001, 17, 8.375));
        try {
          await repository.loadCurrentMatchup(
            season: 2030,
            leagueId: '12345',
            teamId: '7',
          );
          fail('Expected a duplicate ID failure');
        } on EspnFantasyException catch (error) {
          expect(error.failure, EspnFantasyFailure.invalidResponse);
          expect(error.diagnostic, contains('duplicatePlayerId'));
          expect(error.diagnostic, contains('playerId=negative'));
        }
      },
    );

    for (final invalid in <(String, Object?)>[
      ('zero', 0),
      ('non-numeric', 'not-an-id'),
      ('malformed', '12.3'),
      ('null', null),
    ]) {
      test('${invalid.$1} ESPN player ID is rejected', () async {
        final entry = _homeEntries(box).first as Map<String, dynamic>;
        entry['playerId'] = invalid.$2;
        await _expectFailure(
          repository.loadCurrentMatchup(
            season: 2030,
            leagueId: '12345',
            teamId: '7',
          ),
          EspnFantasyFailure.invalidResponse,
        );
      });
    }

    test('missing ESPN player ID is rejected', () async {
      (_homeEntries(box).first as Map).remove('playerId');
      await _expectFailure(
        repository.loadCurrentMatchup(
          season: 2030,
          leagueId: '12345',
          teamId: '7',
        ),
        EspnFantasyFailure.invalidResponse,
      );
    });

    test('league and fantasy-team IDs remain positive-only', () async {
      league['id'] = -12345;
      await _expectFailure(
        repository.loadLeague(season: 2030, leagueId: '12345'),
        EspnFantasyFailure.invalidResponse,
      );
      league = _leagueFixture();
      (league['teams'] as List).first['id'] = -7;
      await _expectFailure(
        repository.loadLeague(season: 2030, leagueId: '12345'),
        EspnFantasyFailure.invalidResponse,
      );
    });

    test(
      'opponent side can be selected and bye can have no opponent',
      () async {
        final away = await repository.loadCurrentMatchup(
          season: 2030,
          leagueId: '12345',
          teamId: '8',
        );
        expect(away.team.team.id, '8');
        expect(away.opponent!.team.id, '7');
        ((box['schedule'] as List)[1] as Map).remove('away');
        final bye = await repository.loadCurrentMatchup(
          season: 2030,
          leagueId: '12345',
          teamId: '7',
        );
        expect(bye.opponent, isNull);
      },
    );

    test('unknown team and missing matchup are typed failures', () async {
      await _expectFailure(
        repository.loadCurrentMatchup(
          season: 2030,
          leagueId: '12345',
          teamId: '77',
        ),
        EspnFantasyFailure.teamUnavailable,
      );
      box['schedule'] = [];
      await _expectFailure(
        repository.loadCurrentMatchup(
          season: 2030,
          leagueId: '12345',
          teamId: '7',
        ),
        EspnFantasyFailure.matchupUnavailable,
      );
    });

    test('invalid league and scoring data fail safely', () async {
      league['scoringPeriodId'] = null;
      await _expectFailure(
        repository.loadLeague(season: 2030, leagueId: '12345'),
        EspnFantasyFailure.invalidResponse,
      );
      league = _leagueFixture();
      final home = (box['schedule'] as List)[1]['home'] as Map<String, dynamic>;
      final entries =
          (home['rosterForCurrentScoringPeriod'] as Map)['entries'] as List;
      final player = (entries.first['playerPoolEntry'] as Map)['player'] as Map;
      player['stats'] = <Map<String, dynamic>>[
        {
          'scoringPeriodId': 4,
          'statSourceId': 0,
          'appliedTotal': 'not-a-score',
        },
      ];
      await _expectFailure(
        repository.loadCurrentMatchup(
          season: 2030,
          leagueId: '12345',
          teamId: '7',
        ),
        EspnFantasyFailure.invalidResponse,
      );
    });

    test('league schema failure reports only structural diagnostics', () async {
      league
        ..remove('scoringPeriodId')
        ..remove('name')
        ..['settings'] = {'name': 'Private League Name'};
      try {
        await repository.loadLeague(season: 2030, leagueId: '12345');
        fail('Expected an invalid response');
      } on EspnFantasyException catch (error) {
        expect(error.failure, EspnFantasyFailure.invalidResponse);
        expect(error.diagnostic, contains('league.scoringPeriodId'));
        expect(error.diagnostic, contains('settings.name=string'));
        expect(error.diagnostic, contains('teams=list(3)'));
        expect(error.diagnostic, isNot(contains('Private League Name')));
        expect(error.diagnostic, isNot(contains(_credentials.swid)));
        expect(error.diagnostic, isNot(contains(_credentials.espnS2)));
        expect(error.toString(), isNot(contains(error.diagnostic!)));
      }
    });

    test(
      'matchup roster failure identifies the section without private data',
      () async {
        final current = (box['schedule'] as List)[1] as Map<String, dynamic>;
        final home = current['home'] as Map<String, dynamic>;
        home.remove('rosterForCurrentScoringPeriod');
        try {
          await repository.loadCurrentMatchup(
            season: 2030,
            leagueId: '12345',
            teamId: '7',
          );
          fail('Expected an invalid response');
        } on EspnFantasyException catch (error) {
          expect(error.failure, EspnFantasyFailure.invalidResponse);
          expect(
            error.diagnostic,
            contains('matchup.side.rosterForCurrentScoringPeriod.entries'),
          );
          expect(error.diagnostic, contains('roster=null'));
          expect(error.diagnostic, isNot(contains(_credentials.swid)));
          expect(error.diagnostic, isNot(contains(_credentials.espnS2)));
          expect(error.toString(), isNot(contains(error.diagnostic!)));
        }
      },
    );

    test(
      'entry and nested player IDs must match exactly, including sign',
      () async {
        final entry = _homeEntries(box)[3] as Map<String, dynamic>;
        entry['playerId'] = -104;
        await _expectFailure(
          repository.loadCurrentMatchup(
            season: 2030,
            leagueId: '12345',
            teamId: '7',
          ),
          EspnFantasyFailure.invalidResponse,
        );
      },
    );

    test(
      'matchup schedule failure reports period and selected-team counts',
      () async {
        box['schedule'] = [
          {'matchupPeriodId': 3, 'home': _side(9, 0, [])},
        ];
        try {
          await repository.loadCurrentMatchup(
            season: 2030,
            leagueId: '12345',
            teamId: '7',
          );
          fail('Expected a missing matchup');
        } on EspnFantasyException catch (error) {
          expect(error.failure, EspnFantasyFailure.matchupUnavailable);
          expect(error.diagnostic, contains('currentPeriodEntries=1'));
          expect(error.diagnostic, contains('selectedTeamEntries=0'));
        }
      },
    );

    test('missing optional names use useful fallbacks', () async {
      league.remove('name');
      final result = await repository.loadLeague(
        season: 2030,
        leagueId: '12345',
      );
      expect(result.name, 'ESPN league 12345');
      expect(result.teams.last.name, 'Team 9');
    });
  });

  test(
    'ESPN and Sleeper configs coexist and provider-qualified IDs do not collide',
    () async {
      final store = SharedPreferencesFantasyLeagueConfigStore();
      await store.upsert(
        const FantasyLeagueConfig(
          provider: FantasyProvider.sleeper,
          leagueId: '12345',
          teamId: '7',
        ),
      );
      await store.upsert(
        const FantasyLeagueConfig(
          provider: FantasyProvider.espn,
          leagueId: '12345',
          teamId: '7',
          displayName: 'Synthetic League',
        ),
      );
      final configs = await store.readAll();
      expect(configs.map((c) => c.id).toSet(), {'sleeper:12345', 'espn:12345'});
      expect(
        configs.every(FantasyLiveObservationCoordinator.isEligiblePrimary),
        isTrue,
      );
      expect(
        FantasyLiveObservationCoordinator.isEligiblePrimary(
          const FantasyLeagueConfig(
            provider: FantasyProvider.espn,
            leagueId: '12345',
            teamId: 'team-7',
          ),
        ),
        isTrue,
      );
      expect(
        FantasyLiveObservationCoordinator.isEligiblePrimary(
          const FantasyLeagueConfig(
            provider: FantasyProvider.espn,
            leagueId: '12345',
            teamId: '   ',
          ),
        ),
        isFalse,
      );
      final primary = SharedPreferencesFantasyPrimaryLeagueStore();
      await primary.save('espn:12345');
      expect(await primary.resolve(configs.map((c) => c.id)), 'espn:12345');
    },
  );
}

EspnFantasyClient _client(
  Future<http.Response> Function(http.Request) handler,
) => EspnFantasyClient(
  credentialsStore: _FakeCredentialsStore(_credentials),
  client: MockClient(handler),
);

Future<void> _expectFailure(
  Future<Object?> future,
  EspnFantasyFailure failure,
) async {
  try {
    await future;
    fail('Expected $failure');
  } on EspnFantasyException catch (error) {
    expect(error.failure, failure);
    expect(error.toString(), isNot(contains(_credentials.swid)));
    expect(error.toString(), isNot(contains(_credentials.espnS2)));
  }
}

class _FakeCredentialsStore implements EspnFantasyCredentialsStore {
  _FakeCredentialsStore([this.value]);
  EspnFantasyCredentials? value;
  @override
  Future<EspnFantasyCredentials?> read() async => value;
  @override
  Future<void> save(EspnFantasyCredentials credentials) async =>
      value = credentials;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<bool> hasCredentials() async => value != null;
}

class _SecureMemoryStorage implements SecureStringStorage {
  final values = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read(String key) async {
    if (fail) throw StateError('fake-espn-s2');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (fail) throw StateError('fake-espn-s2');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (fail) throw StateError('fake-espn-s2');
    values.remove(key);
  }
}

Map<String, dynamic> _leagueFixture() => {
  'id': 12345,
  'name': 'Synthetic League',
  'seasonId': 2030,
  'scoringPeriodId': 4,
  'status': {'currentMatchupPeriod': 3},
  'teams': [
    {'id': 7, 'name': 'Alpha'},
    {'id': 8, 'location': 'East', 'nickname': 'Beta'},
    {'id': 9},
  ],
};

Map<String, dynamic> _boxFixture() => {
  'schedule': [
    {'matchupPeriodId': 2, 'home': _side(9, 0, []), 'away': _side(8, 0, [])},
    {
      'matchupPeriodId': 3,
      'home': _side(7, 102.375, [
        _entry(101, 0, 12.345, name: 'Synthetic Quarterback'),
        _entry(102, 20, 9.875),
        _entry(103, 21, 5),
        _entry(104, 23, null),
        _entry(105, 22, 3),
      ], projection: 126.7),
      'away': _side(8, 97.125, [_entry(201, 2, 7.125)], projection: 119.4),
    },
  ],
};

List<dynamic> _homeEntries(Map<String, dynamic> box) {
  final current = (box['schedule'] as List)[1] as Map<String, dynamic>;
  final home = current['home'] as Map<String, dynamic>;
  return (home['rosterForCurrentScoringPeriod'] as Map)['entries'] as List;
}

Map<String, dynamic> _side(
  int teamId,
  num score,
  List<Map<String, dynamic>> entries, {
  num? projection,
}) => {
  'teamId': teamId,
  'totalPointsLive': score,
  'totalProjectedPointsLive': ?projection,
  'rosterForCurrentScoringPeriod': {'entries': entries},
};
Map<String, dynamic> _entry(int id, int slot, num? actual, {String? name}) => {
  'playerId': id,
  'lineupSlotId': slot,
  'playerPoolEntry': {
    'player': {
      'id': id,
      'fullName': name ?? 'Player $id',
      'stats': actual == null
          ? []
          : [
              {'scoringPeriodId': 3, 'statSourceId': 0, 'appliedTotal': 999},
              {'scoringPeriodId': 4, 'statSourceId': 1, 'appliedTotal': 999},
              {'scoringPeriodId': 4, 'statSourceId': 0, 'appliedTotal': actual},
            ],
    },
  },
};
