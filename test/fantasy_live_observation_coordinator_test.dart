import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/device_transport.dart';
import 'package:sports_hub_mobile/fantasy_live_observation_coordinator.dart';
import 'package:sports_hub_mobile/fantasy_nfl_play.dart';
import 'package:sports_hub_mobile/fantasy_point_delta_tracker.dart';
import 'package:sports_hub_mobile/fantasy_scoring_correlation.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/pending_fantasy_alert_store.dart';
import 'package:sports_hub_mobile/sleeper_fantasy_repository.dart';
import 'package:sports_hub_mobile/sleeper_league_id_store.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';
import 'package:sports_hub_mobile/sleeper_roster_id_store.dart';

void main() {
  test('missing league configuration skips without fetching', () async {
    final harness = _Harness(leagueId: null, rosterId: 1);
    final result = await harness.coordinator.observe();
    expect(result.configured, isFalse);
    expect(harness.loads, 0);
  });

  test('missing selected roster skips without fetching', () async {
    final harness = _Harness(leagueId: 'league', rosterId: null);
    expect((await harness.coordinator.observe()).configured, isFalse);
    expect(harness.loads, 0);
  });

  test(
    'first observation baselines fourth-quarter points without alert',
    () async {
      final harness = _Harness();
      harness.snapshots.add(_snapshot(userPoints: 150));
      final result = await harness.coordinator.observe();
      expect(result.events, isEmpty);
      expect(result.baselineReady, isTrue);
      expect(harness.transport.sent, isEmpty);
    },
  );

  test('subsequent starter delta queues and delivers once', () async {
    final harness = _Harness();
    harness.snapshots.addAll([_snapshot(), _snapshot(userPoints: 12)]);
    await harness.coordinator.observe();
    final result = await harness.coordinator.observe();
    expect(result.events.single.delta.delta, 12);
    expect(harness.transport.sent, hasLength(1));
    expect(harness.coordinator.pendingStore.length, 0);
  });

  test('matching ESPN play produces high-confidence event', () async {
    final harness = _Harness(
      metadata: {'u1': _player},
      plays: [
        const [],
        [_touchdown],
      ],
    );
    harness.snapshots.addAll([_snapshot(), _snapshot(userPoints: 12)]);
    await harness.coordinator.observe();
    final result = await harness.coordinator.observe();
    expect(result.events.single.confidence, FantasyCorrelationConfidence.high);
  });

  test('ESPN failure still delivers authoritative unmatched delta', () async {
    final harness = _Harness(failPlayRefreshAfter: 1);
    harness.snapshots.addAll([_snapshot(), _snapshot(userPoints: 12)]);
    await harness.coordinator.observe();
    final result = await harness.coordinator.observe();
    expect(result.events.single.confidence, FantasyCorrelationConfidence.none);
    expect(harness.transport.sent.single.event.delta.delta, 12);
  });

  test('recent ESPN play can explain a delayed Sleeper delta', () async {
    final harness = _Harness(
      metadata: {'u1': _player},
      plays: [
        [_touchdown],
        const [],
      ],
    );
    harness.snapshots.addAll([_snapshot(), _snapshot(userPoints: 12)]);
    await harness.coordinator.observe();
    final result = await harness.coordinator.observe();
    expect(result.newPlays, isEmpty);
    expect(result.events.single.confidence, FantasyCorrelationConfidence.high);
  });

  test('unchanged observation creates no event or duplicate send', () async {
    final harness = _Harness();
    harness.snapshots.addAll([_snapshot(), _snapshot(), _snapshot()]);
    await harness.coordinator.observe();
    await harness.coordinator.observe();
    await harness.coordinator.observe();
    expect(harness.transport.sent, isEmpty);
  });

  test(
    'manual and automatic observations share one tracker baseline',
    () async {
      final harness = _Harness();
      harness.snapshots.addAll([
        _snapshot(),
        _snapshot(userPoints: 12),
        _snapshot(userPoints: 12),
      ]);
      await harness.coordinator.observe(sendOneAlert: false);
      final manual = await harness.coordinator.observe(sendOneAlert: false);
      final automatic = await harness.coordinator.observe();
      expect(manual.events, hasLength(1));
      expect(automatic.events, isEmpty);
      expect(harness.transport.sent, hasLength(1));
    },
  );

  test('BLE failure retains pending and later wake retries it', () async {
    final harness = _Harness()..transport.fail = true;
    harness.snapshots.addAll([
      _snapshot(),
      _snapshot(userPoints: 12),
      _snapshot(userPoints: 12),
    ]);
    await harness.coordinator.observe();
    await harness.coordinator.observe();
    expect(harness.coordinator.pendingStore.length, 1);
    harness.transport.fail = false;
    await harness.coordinator.observe();
    expect(harness.coordinator.pendingStore.length, 0);
    expect(harness.transport.sent, hasLength(1));
  });

  test('disconnect retains pending until same-context reconnect', () async {
    final harness = _Harness()..connected = false;
    harness.snapshots.addAll([
      _snapshot(),
      _snapshot(userPoints: 12),
      _snapshot(userPoints: 12),
    ]);
    await harness.coordinator.observe();
    await harness.coordinator.observe();
    expect(harness.coordinator.pendingStore.length, 1);
    harness.connected = true;
    await harness.coordinator.observe();
    expect(harness.transport.sent, hasLength(1));
  });

  test('week, matchup, and league context changes discard stale pending', () {
    final store = PendingFantasyAlertStore();
    final contexts = [
      _context(),
      _context(week: 2),
      _context(matchup: 8),
      _context(league: 'other'),
    ];
    for (final context in contexts) {
      store.useContext(context);
      expect(store.length, 0);
      store.add(_pending(context, '${context.hashCode}'));
      expect(store.length, 1);
    }
  });

  test('identical transition is deduped despite revised explanation', () {
    final store = PendingFantasyAlertStore();
    final context = _context();
    expect(store.add(_pending(context, 'same')), isTrue);
    expect(store.add(_pending(context, 'same')), isFalse);
    expect(store.length, 1);
  });

  test(
    'priority is user, magnitude, confidence with one send per wake',
    () async {
      final harness = _Harness();
      harness.snapshots.addAll([
        _snapshot(),
        _snapshot(userPoints: 3, opponentPoints: 20),
      ]);
      await harness.coordinator.observe();
      await harness.coordinator.observe();
      expect(harness.transport.sent, hasLength(1));
      expect(harness.transport.sent.single.event.delta.playerId, 'u1');
      expect(harness.coordinator.pendingStore.length, 1);
    },
  );

  test('bounded queue deterministically keeps highest-priority events', () {
    final store = PendingFantasyAlertStore(capacity: 2);
    final context = _context();
    store.add(_pending(context, 'opponent', opponent: true, delta: 30));
    store.add(_pending(context, 'user-small', delta: 1));
    store.add(_pending(context, 'user-large', delta: 12));
    expect(store.pending.map((item) => item.id), ['user-large', 'user-small']);
  });

  test('negative delta is queued and delivered', () async {
    final harness = _Harness();
    harness.snapshots.addAll([_snapshot(userPoints: 2), _snapshot()]);
    await harness.coordinator.observe();
    await harness.coordinator.observe();
    expect(harness.transport.sent.single.event.delta.delta, -2);
  });

  test('automatic runtime performs no full metadata download or timer', () {
    final source = File(
      'lib/fantasy_live_observation_coordinator.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('fetchNflPlayers')));
    expect(source, isNot(contains('Timer.periodic')));
  });

  test('fantasy failure never prevents the sports domain', () async {
    var sportsRan = false;
    await runIsolatedWakeDomains(
      refreshSports: () async => sportsRan = true,
      observeFantasy: () async => throw StateError('Sleeper failed'),
    );
    expect(sportsRan, isTrue);
  });

  test('sports failure does not prevent fantasy observation', () async {
    var fantasyRan = false;
    await runIsolatedWakeDomains(
      refreshSports: () async => throw StateError('sports failed'),
      observeFantasy: () async => fantasyRan = true,
    );
    expect(fantasyRan, isTrue);
  });
}

class _Harness {
  _Harness({
    this.leagueId = 'league',
    this.rosterId = 1,
    this.metadata = const {},
    this.plays = const [],
    this.failPlayRefreshAfter,
  }) {
    coordinator = FantasyLiveObservationCoordinator(
      leagueIdStore: _LeagueStore(leagueId),
      rosterIdStore: _RosterStore(rosterId),
      loadLeague: (id) async {
        loads++;
        if (snapshots.isEmpty) throw StateError('No snapshot');
        return snapshots.removeAt(0);
      },
      refreshPlays: (_) async {
        playRefreshes++;
        if (failPlayRefreshAfter != null &&
            playRefreshes > failPlayRefreshAfter!) {
          throw StateError('ESPN unavailable');
        }
        return plays.length >= playRefreshes
            ? plays[playRefreshes - 1]
            : const [];
      },
      resolveCachedMetadata: (_) async => metadata,
      transport: transport,
      isBleConnected: () => connected,
      clock: () => DateTime(2026, 9, 1),
    );
  }
  final String? leagueId;
  final int? rosterId;
  final Map<String, SleeperFantasyPlayer> metadata;
  final List<List<FantasyNflPlay>> plays;
  final int? failPlayRefreshAfter;
  final snapshots = <SleeperLeagueSnapshot>[];
  final transport = _Transport();
  late final FantasyLiveObservationCoordinator coordinator;
  bool connected = true;
  int loads = 0;
  int playRefreshes = 0;
}

class _LeagueStore implements SleeperLeagueIdStore {
  _LeagueStore(this.value);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> save(String leagueId) async => value = leagueId;
}

class _RosterStore implements SleeperRosterIdStore {
  _RosterStore(this.value);
  int? value;
  @override
  Future<int?> read() async => value;
  @override
  Future<void> save(int rosterId) async => value = rosterId;
}

class _Transport extends DeviceTransport {
  bool fail = false;
  final sent = <PendingFantasyAlert>[];
  @override
  Future<void> sendFantasyAlert(
    FantasyScoringEvent event, {
    required String userName,
    required double userScore,
    required String opponentName,
    required double opponentScore,
  }) async {
    if (fail) throw StateError('BLE failed');
    sent.add(
      PendingFantasyAlert(
        id: 'sent',
        context: _context(),
        event: event,
        userName: userName,
        userScore: userScore,
        opponentName: opponentName,
        opponentScore: opponentScore,
      ),
    );
  }

  @override
  Future<void> sendGameData(GameData gameData) async {}
  @override
  Future<void> sendGameSlate(List<GameData> games) async {}
}

SleeperLeagueSnapshot _snapshot({
  double userPoints = 0,
  double opponentPoints = 0,
  int week = 1,
}) {
  const users = [
    SleeperUser(userId: 'user', displayName: 'Peter'),
    SleeperUser(userId: 'opponent', displayName: 'Mike'),
  ];
  const rosters = [
    SleeperRoster(
      rosterId: 1,
      ownerId: 'user',
      players: ['u1'],
      starters: ['u1'],
    ),
    SleeperRoster(
      rosterId: 2,
      ownerId: 'opponent',
      players: ['o1'],
      starters: ['o1'],
    ),
  ];
  return SleeperLeagueSnapshot(
    league: const SleeperLeague(
      leagueId: 'league',
      name: 'League',
      season: '2026',
      status: 'in_season',
      scoringSettings: {'rec': 1, 'rec_yd': 0.1, 'rec_td': 6},
      rosterPositions: [],
    ),
    week: week,
    users: users,
    rosters: rosters,
    matchups: [
      SleeperMatchup(
        rosterId: 1,
        matchupId: 7,
        points: userPoints,
        starters: const ['u1'],
        playerPoints: {'u1': userPoints},
      ),
      SleeperMatchup(
        rosterId: 2,
        matchupId: 7,
        points: opponentPoints,
        starters: const ['o1'],
        playerPoints: {'o1': opponentPoints},
      ),
    ],
  );
}

const _player = SleeperFantasyPlayer(
  sleeperPlayerId: 'u1',
  fullName: "Ja'Marr Chase",
  firstName: "Ja'Marr",
  lastName: 'Chase',
  position: 'WR',
  nflTeam: 'CIN',
  espnPlayerId: '99',
);

const _touchdown = FantasyNflPlay(
  playId: 'play',
  gameId: 'game',
  description: 'J. Chase pass reception for 50 yards, touchdown.',
  possessionTeam: 'CIN',
  yards: 50,
  type: FantasyNflPlayType.reception,
  wallClock: null,
  quarter: 4,
  gameClock: '2:00',
  isScoringPlay: true,
  participants: [
    FantasyNflPlayParticipant(
      espnAthleteId: '99',
      displayName: "Ja'Marr Chase",
      role: 'receiver',
      team: 'CIN',
    ),
  ],
  usesFallbackIdentity: false,
);

FantasyMatchupContext _context({
  String league = 'league',
  int week = 1,
  int matchup = 7,
}) => FantasyMatchupContext(
  leagueId: league,
  week: week,
  rosterId: 1,
  opponentRosterId: 2,
  matchupId: matchup,
);

PendingFantasyAlert _pending(
  FantasyMatchupContext context,
  String id, {
  bool opponent = false,
  double delta = 1,
}) => PendingFantasyAlert(
  id: id,
  context: context,
  event: FantasyScoringEvent(
    delta: FantasyPointDelta(
      playerId: id,
      side: opponent ? FantasyMatchupSide.opponent : FantasyMatchupSide.user,
      previousPoints: 0,
      currentPoints: delta,
      delta: delta,
    ),
    player: null,
    matchedPlay: null,
    confidence: FantasyCorrelationConfidence.none,
    explanation: null,
    predictedPoints: null,
    diagnostic: 'test',
  ),
  userName: 'Peter',
  userScore: 0,
  opponentName: 'Mike',
  opponentScore: 0,
);
