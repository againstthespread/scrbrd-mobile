import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sports_hub_mobile/espn_data_source.dart';
import 'package:sports_hub_mobile/sports_data_io_data_source.dart';
import 'package:sports_hub_mobile/sports_data_source.dart';
import 'package:sports_hub_mobile/golf_data_source.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_league.dart';
import 'package:sports_hub_mobile/sports_repository.dart';

void main() {
  test(
    'F29 repository closes shared owned sports/golf source exactly once',
    () {
      final source = _Source();
      final repository = SportsRepository(source, ownsSources: true);
      repository.dispose();
      repository.dispose();
      expect(source.closes, 1);
    },
  );
  test('F29 borrowed sources remain caller owned', () {
    final source = _Source();
    SportsRepository(source).dispose();
    expect(source.closes, 0);
  });
  test('F29 provider sources do not close borrowed HTTP clients', () {
    final client = _Client();
    EspnDataSource(client: client).close();
    SportsDataIODataSource(client: client).close();
    expect(client.closes, 0);
    client.close();
    expect(client.closes, 1);
  });
}

class _Source
    implements SportsDataSource, GolfDataSource, DisposableSportsDataSource {
  int closes = 0;
  @override
  void close() => closes++;
  @override
  Future<List<SportsGame>> fetchGamesForDate(
    SportsLeague league,
    DateTime date,
  ) async => [];
  @override
  Future<GolfLeaderboard?> fetchGolfLeaderboardForDate(DateTime date) async =>
      null;
  @override
  Future<GolfLeaderboard> fetchGolfLeaderboardByTournamentId(String id) async =>
      throw UnimplementedError();
}

class _Client extends http.BaseClient {
  int closes = 0;
  @override
  void close() => closes++;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      throw UnimplementedError();
}
