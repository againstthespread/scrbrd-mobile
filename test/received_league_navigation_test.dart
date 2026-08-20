import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stores two and three leagues and appends new leagues', () {
    final store = _ReceivedLeagueStore();
    store.upsert('NFL', ['n1', 'n2']);
    store.upsert('NBA', ['b1', 'b2']);
    expect(store.leagues, ['NFL', 'NBA']);

    store.upsert('MLB', ['m1', 'm2']);
    expect(store.leagues, ['NFL', 'NBA', 'MLB']);
    expect(store.currentLeague, 'NFL');
  });

  test('supports eight leagues and rejects a ninth without data loss', () {
    final store = _ReceivedLeagueStore();
    for (var index = 0; index < 8; index++) {
      expect(store.upsert('L$index', ['g$index']), isTrue);
    }

    expect(store.upsert('L8', const ['overflow']), isFalse);
    expect(store.leagues, hasLength(8));
    expect(store.gamesFor('L0'), ['g0']);
  });

  test('replacing one league does not affect other leagues', () {
    final store = _ReceivedLeagueStore()
      ..upsert('NFL', ['n1', 'n2'])
      ..upsert('MLB', ['m1', 'm2']);

    store.upsert('MLB', ['new-m1']);

    expect(store.gamesFor('NFL'), ['n1', 'n2']);
    expect(store.gamesFor('MLB'), ['new-m1']);
    expect(store.currentLeague, 'NFL');
  });

  test('single click cycles games and wraps within active league', () {
    final store = _ReceivedLeagueStore()..upsert('NFL', ['n1', 'n2']);

    expect(store.currentGame, 'n1');
    store.nextGame();
    expect(store.currentGame, 'n2');
    store.nextGame();
    expect(store.currentGame, 'n1');
  });

  test('double click cycles leagues, wraps, and resets game index', () {
    final store = _ReceivedLeagueStore()
      ..upsert('NFL', ['n1', 'n2'])
      ..upsert('NBA', ['b1', 'b2'])
      ..upsert('MLB', ['m1', 'm2']);
    store.nextGame();
    expect(store.currentGame, 'n2');

    store.nextLeague();
    expect(store.currentLeague, 'NBA');
    expect(store.currentGame, 'b1');
    store.nextGame();
    store.nextLeague();
    expect(store.currentLeague, 'MLB');
    expect(store.currentGame, 'm1');
    store.nextLeague();
    expect(store.currentLeague, 'NFL');
    expect(store.currentGame, 'n1');
  });
}

// Mirrors the firmware's owned received-league navigation contract. Firmware
// compilation remains the authoritative implementation check.
class _ReceivedLeagueStore {
  final Map<String, List<String>> _games = {};
  var _leagueIndex = 0;
  var _gameIndex = 0;

  List<String> get leagues => _games.keys.toList();
  String get currentLeague => leagues[_leagueIndex];
  String get currentGame => _games[currentLeague]![_gameIndex];

  List<String>? gamesFor(String league) => _games[league];

  bool upsert(String league, List<String> games) {
    if (!_games.containsKey(league) && _games.length >= 8) return false;
    final replacingActive =
        _games.containsKey(league) && leagues.indexOf(league) == _leagueIndex;
    _games[league] = List.of(games);
    if (_games.length == 1 || replacingActive) _gameIndex = 0;
    return true;
  }

  void nextGame() {
    _gameIndex = (_gameIndex + 1) % _games[currentLeague]!.length;
  }

  void nextLeague() {
    _leagueIndex = (_leagueIndex + 1) % _games.length;
    _gameIndex = 0;
  }
}
