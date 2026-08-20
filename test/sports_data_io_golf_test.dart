import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/sports_data_io_golf.dart';

void main() {
  test('discovers covered tournament by date and prefers in progress', () {
    final selected = selectGolfTournamentForDate([
      _tournament('1', covered: true),
      _tournament('2', covered: true, isInProgress: true),
      _tournament('3', covered: false, isInProgress: true),
    ], DateTime(2026, 8, 20));

    expect(selected?.tournamentId, '2');
  });

  test('no covered tournament in selected date window is unavailable', () {
    expect(
      selectGolfTournamentForDate([
        _tournament('1', covered: false),
        _tournament(
          '2',
          covered: true,
          start: DateTime(2026, 8, 25),
          end: DateTime(2026, 8, 28),
        ),
      ], DateTime(2026, 8, 20)),
      isNull,
    );
  });

  test('formats golf scores', () {
    expect(formatGolfScore(-8), '-8');
    expect(formatGolfScore(2), '+2');
    expect(formatGolfScore(0), 'E');
    expect(formatGolfScore(-1, specialStatus: 'CUT'), 'CUT');
  });

  test('preserves tied ranks and selects official top 50', () {
    final players = List.generate(55, (index) {
      final rank = index < 2 ? 1 : index;
      return {
        'PlayerID': 400 + index,
        'Name': 'Golfer $index',
        'Rank': rank,
        'TotalScore': -8 + index,
        'TotalThrough': 18,
        'IsWithdrawn': false,
        'MadeCut': 1,
      };
    }).reversed.toList();
    final leaderboard = parseSportsDataIOGolfLeaderboard({
      'Tournament': _tournamentJson('99'),
      'Players': players,
    });

    expect(leaderboard.tournamentId, '99');
    expect(leaderboard.golfers, hasLength(50));
    expect(leaderboard.golfers[0].rank, '1');
    expect(leaderboard.golfers[1].rank, '1');
  });

  test('pre-tee golfer displays E and tee time, not CUT', () {
    final row = _parseRow({
      'TotalScore': null,
      'TotalThrough': null,
      'TeeTime': '2026-08-20T08:15:00',
      'MadeCut': 0,
    });

    expect(row.score, 'E');
    expect(row.detail, '8:15 AM');
  });

  test('live golfer displays relative score and current thru value', () {
    final row = _parseRow({'TotalScore': -4, 'TotalThrough': 11, 'MadeCut': 1});

    expect(row.score, '-4');
    expect(row.detail, 'THRU 11');
  });

  test('finished golfer displays relative score and F', () {
    final row = _parseRow({'TotalScore': 2, 'TotalThrough': 18, 'MadeCut': 1});

    expect(row.score, '+2');
    expect(row.detail, 'F');
  });

  test('true CUT is preserved', () {
    final row = _parseRow({
      'TotalScore': 6,
      'TotalThrough': 18,
      'MadeCut': 0,
      'TournamentStatus': 'Cut',
    });
    expect(row.score, 'CUT');
  });

  test('WD is preserved', () {
    final row = _parseRow({
      'IsWithdrawn': true,
      'TournamentStatus': 'Withdrawn',
    });
    expect(row.score, 'WD');
  });

  test('DQ is preserved', () {
    final row = _parseRow({'TournamentStatus': 'Disqualified'});
    expect(row.score, 'DQ');
  });
}

GolfLeaderboardRow _parseRow(Map<String, dynamic> fields) {
  final leaderboard = parseSportsDataIOGolfLeaderboard({
    'Tournament': _tournamentJson('99'),
    'Players': [
      {'PlayerID': 400, 'Name': 'Test Golfer', 'Rank': 1, ...fields},
    ],
  });
  return leaderboard.golfers.single;
}

SportsDataIOGolfTournament _tournament(
  String id, {
  bool? covered,
  bool isInProgress = false,
  DateTime? start,
  DateTime? end,
}) {
  return SportsDataIOGolfTournament(
    tournamentId: id,
    name: 'Tournament $id',
    startDate: start ?? DateTime(2026, 8, 18),
    endDate: end ?? DateTime(2026, 8, 23),
    covered: covered,
    isInProgress: isInProgress,
    isOver: false,
  );
}

Map<String, dynamic> _tournamentJson(String id) => {
  'TournamentID': int.parse(id),
  'Name': 'BMW Championship',
  'StartDate': '2026-08-18T00:00:00',
  'EndDate': '2026-08-23T00:00:00',
  'Covered': true,
  'IsInProgress': true,
  'IsOver': false,
};
