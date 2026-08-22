import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/game_packet_serializer.dart';
import 'package:sports_hub_mobile/sports_game.dart';

void main() {
  const serializer = GamePacketSerializer();

  test('NFL slate includes optional football state', () {
    final transfer = serializer.buildChunkedSlateTransfer([
      _nfl(),
    ], slateId: 'football');
    final chunk = jsonDecode(utf8.decode(transfer.chunkPackets.single));
    final game = chunk['games'][0] as Map<String, dynamic>;
    expect(game['possession'], 'away');
    expect(game['down'], 4);
    expect(game['distance'], 0);
    expect(game['goalToGo'], true);
  });

  test('legacy packet and non-NFL game omit football state', () {
    final legacy = jsonDecode(serializer.serializeToString(_nfl(state: null)));
    expect(legacy, isNot(contains('possession')));
    final mlb = jsonDecode(
      serializer.serializeToString(
        GameData(
          league: 'MLB',
          awayTeam: 'A',
          homeTeam: 'H',
          awayScore: 0,
          homeScore: 0,
          status: 'LIVE',
          clock: 'Top 1st',
        ),
      ),
    );
    expect(mlb, isNot(contains('possession')));
  });
}

GameData _nfl({
  FootballGameState? state = const FootballGameState(
    possession: FootballPossession.away,
    down: 4,
    distance: 0,
    isGoalToGo: true,
  ),
}) => GameData(
  eventId: 'nfl-1',
  league: 'NFL',
  awayTeam: 'A',
  homeTeam: 'H',
  awayScore: 0,
  homeScore: 0,
  status: 'LIVE',
  clock: 'Q4 1:00',
  footballState: state,
);
