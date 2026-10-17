import 'dart:convert';
import 'dart:io';

import 'package:sports_hub_mobile/fantasy_matchup_display_data.dart';
import 'package:sports_hub_mobile/fantasy_matchup_transport.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';

/// Fixed normalized provider boundary. No live network or projection calculation.
class FixtureSource implements SportsDataSource {
  FixtureSource() {
    final fixture =
        jsonDecode(File('test/virtual/fixtures/season.json').readAsStringSync())
            as Map<String, dynamic>;
    date = DateTime.parse(fixture['date'] as String);
    sports = [
      for (final value in fixture['sports'] as List)
        Map<String, dynamic>.from(value as Map),
    ];
    fantasy = [
      for (final value in fixture['fantasy'] as List)
        FantasyMatchupSlateEntry(
          identity: value['identity'] as String,
          matchup: FantasyMatchupDisplayData(
            leagueName: value['leagueName'] as String,
            userName: value['userName'] as String,
            opponentName: value['opponentName'] as String,
            userScore: (value['userScore'] as num).toDouble(),
            opponentScore: (value['opponentScore'] as num).toDouble(),
            week: 6,
            status: FantasyMatchupDisplayStatus.live,
          ),
        ),
    ];
  }
  late final DateTime date;
  late final List<Map<String, dynamic>> sports;
  late final List<FantasyMatchupSlateEntry> fantasy;
  final failures = <SportsLeague>{};
  final requests = <SportsLeague>[];

  void score(String id, int score) =>
      sports.singleWhere((g) => g['id'] == id)['awayScore'] = score;

  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime selectedDate,
  ) async {
    requests.add(league);
    if (failures.contains(league)) {
      throw StateError('Scripted provider unavailable');
    }
    if (selectedDate.year != date.year ||
        selectedDate.month != date.month ||
        selectedDate.day != date.day) {
      throw StateError('Fixture requested for unexpected date: $selectedDate');
    }
    return [
      for (final g in sports.where((g) => g['league'] == league.label))
        SportsGame(
          league: league.label,
          eventId: g['id'] as String,
          awayTeam: g['away'] as String,
          homeTeam: g['home'] as String,
          awayScore: g['awayScore'] as int,
          homeScore: g['homeScore'] as int,
          status: g['status'] as String,
          clock: g['clock'] as String,
        ),
    ];
  }
}
