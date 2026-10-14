import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/fantasy_matchup_display_data.dart';
import 'package:sports_hub_mobile/fantasy_matchup_packet_serializer.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/game_packet_serializer.dart';
import 'package:sports_hub_mobile/golf_leaderboard.dart';
import 'package:sports_hub_mobile/golf_packet_serializer.dart';
import 'package:sports_hub_mobile/sports_game.dart';
import 'package:sports_hub_mobile/sports_hub_ble_protocol.dart';

void main() {
  test(
    'F34 export production serializers for native firmware compatibility',
    () {
      const game = GamePacketSerializer();
      const golf = GolfPacketSerializer();
      const fantasy = FantasyMatchupPacketSerializer();
      final steps = <Map<String, Object>>[];
      List<GameData> games(String league, int count, {int score = 1}) => [
        for (var i = 0; i < count; i++)
          GameData(
            league: league,
            eventId: '$league-$i',
            awayTeam: 'Away',
            homeTeam: 'Home',
            awayScore: score,
            homeScore: 2,
            status: 'LIVE',
            clock: 'Q1',
            baseballState: league == 'MLB'
                ? const BaseballGameState(
                    runnerOnFirst: true,
                    runnerOnSecond: false,
                    runnerOnThird: true,
                    outs: 2,
                  )
                : null,
            footballState: league == 'NFL' || league == 'NCAAF'
                ? const FootballGameState(
                    possession: FootballPossession.home,
                    down: 3,
                    distance: 7,
                    isGoalToGo: false,
                  )
                : null,
          ),
      ];
      List<List<int>> teamPackets(
        String league,
        int count, {
        int score = 1,
        bool reorder = false,
      }) {
        var slate = games(league, count, score: score);
        if (reorder) slate = [slate[2], slate[0], slate[1]];
        return game
            .buildChunkedSlateTransfer(slate, slateId: '$league-$score')
            .packets;
      }

      List<List<int>> fantasyPackets(List<int> ids) => [
        fantasy.serializeSlateStart(),
        for (final id in ids)
          fantasy.serialize(
            FantasyMatchupDisplayData(
              leagueName: 'Ligue é$id',
              userName: 'User',
              userScore: 10 + id.toDouble(),
              opponentName: 'Other',
              opponentScore: 5,
              week: 7,
              status: FantasyMatchupDisplayStatus.live,
              userProjectedScore: 22.5,
            ),
            identity: 'league-$id',
          ),
        fantasy.serializeSlateEnd(),
      ];
      var leagues = 0;
      for (final league in ['NFL', 'NCAAF', 'NBA', 'NHL', 'MLB']) {
        final count = league == 'NCAAF' ? 72 : 3;
        steps.add({
          'packets': [
            if (leagues == 0) utf8.encode('SYNC_START'),
            ...teamPackets(league, count),
          ],
          'select': league,
          'gameCount': count,
          'eventId': '$league-0',
          'leagueCount': ++leagues,
          if (league == 'MLB') 'baseball': true,
          if (league == 'NFL' || league == 'NCAAF') 'football': true,
        });
      }
      final board = GolfLeaderboard(
        tournamentId: 'open',
        tournamentName: 'Test Open',
        golfers: [
          for (var i = 0; i < 50; i++)
            GolfLeaderboardRow(
              playerId: 'p-$i',
              name: 'Golfer $i',
              rank: '${i + 1}',
              score: '-2',
              detail: 'THRU 7',
            ),
        ],
        isInProgress: true,
        isOver: false,
      );
      final golfTransfer = golf.buildTransfer(board, transferId: 'golf-1');
      steps.add({
        'packets': [
          golfTransfer.startPacket,
          ...golfTransfer.chunkPackets,
          golfTransfer.endPacket,
        ],
        'select': 'PGA',
        'gameCount': 10,
        'leagueCount': ++leagues,
      });
      steps.add({
        'packets': fantasyPackets(List.generate(8, (i) => i)),
        'select': 'FANTASY',
        'gameCount': 8,
        'leagueCount': ++leagues,
        'fantasyIdentity': 'league-0',
      });
      steps.add({
        'packets': [utf8.encode('SYNC_COMPLETE')],
        'select': 'NBA',
        'nextGames': 2,
        'eventId': 'NBA-2',
        'gameCount': 3,
        'leagueCount': leagues,
      });
      steps.add({
        'packets': teamPackets('NBA', 3, score: 99, reorder: true),
        'preserveSelection': true,
        'eventId': 'NBA-2',
        'score': 99,
        'gameCount': 3,
        'leagueCount': leagues,
      });
      final incomplete = game.buildChunkedSlateTransfer(
        games('NBA', 3, score: 100),
        slateId: 'interrupted',
      );
      steps.add({
        'packets': [incomplete.startPacket, incomplete.endPacket],
        'preserveSelection': true,
        'eventId': 'NBA-2',
        'score': 99,
        'gameCount': 3,
        'leagueCount': leagues,
      });
      steps.add({
        'packets': teamPackets('NBA', 3, score: 101, reorder: true),
        'standby': true,
        'preserveSelection': true,
        'eventId': 'NBA-2',
        'score': 101,
        'gameCount': 3,
        'leagueCount': leagues,
      });
      steps.add({
        'packets': <List<int>>[],
        'select': 'FANTASY',
        'nextGames': 3,
        'fantasyIdentity': 'league-3',
        'gameCount': 8,
        'leagueCount': leagues,
      });
      steps.add({
        'packets': fantasyPackets([0, 3, 1, 2, 4, 5, 6, 7]),
        'fantasyIdentity': 'league-3',
        'gameCount': 8,
        'leagueCount': leagues,
      });
      steps.add({
        'packets': fantasyPackets([4, 0, 1, 2, 3, 5, 6, 7]),
        'fantasyIdentity': 'league-4',
        'gameCount': 8,
        'leagueCount': leagues,
      });
      steps.add({
        'packets': [
          fantasy.serializeSlateStart(),
          fantasyPackets([1])[1],
          utf8.encode('{"version":99,"type":"fantasy_slate_end"}'),
          fantasy.serializeSlateEnd(),
        ],
        'fantasyIdentity': 'league-4',
        'gameCount': 8,
        'leagueCount': leagues,
      });
      steps.add({
        'packets': <List<int>>[],
        'select': 'NBA',
        'nextGames': 2,
        'eventId': 'NBA-1',
        'gameCount': 3,
        'leagueCount': leagues,
      });
      steps.add({
        'packets': fantasyPackets([]),
        'preserveSelection': true,
        'eventId': 'NBA-1',
        'gameCount': 3,
        'leagueCount': --leagues,
      });
      steps.add({
        'packets': [golfTransfer.startPacket, golfTransfer.chunkPackets.first],
        'timeout': true,
        'select': 'PGA',
        'gameCount': 10,
        'leagueCount': leagues,
      });
      for (final step in steps) {
        for (final packet in step['packets']! as List<List<int>>) {
          expect(packet.length, lessThanOrEqualTo(512));
          expect(() => utf8.decode(packet), returnsNormally);
        }
      }
      final fixture = {
        'advertisingName': SportsHubBleProtocol.advertisingName,
        'service': SportsHubBleProtocol.serviceUuidText,
        'write': SportsHubBleProtocol.writableCharacteristicUuidText,
        'wake': SportsHubBleProtocol.wakeCharacteristicUuidText,
        'steps': steps,
      };
      final output = Platform.environment['SCRBRD_PROTOCOL_FIXTURE'];
      if (output != null) File(output).writeAsStringSync(jsonEncode(fixture));
      expect(steps, hasLength(18));
    },
  );
}
