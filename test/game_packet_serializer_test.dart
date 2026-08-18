import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/game_data.dart';
import 'package:sports_hub_mobile/game_packet_serializer.dart';

void main() {
  const serializer = GamePacketSerializer();

  group('GamePacketSerializer', () {
    test('serializes a valid packet as compact UTF-8 JSON', () {
      const gameData = GameData(
        league: 'NFL',
        awayTeam: 'BUF',
        homeTeam: 'NE',
        awayScore: 17,
        homeScore: 24,
        status: 'LIVE',
        clock: 'Q4 8:31',
      );

      final packet = serializer.serializeToString(gameData);
      final bytes = serializer.serialize(gameData);

      expect(
        packet,
        '{"version":1,"type":"game","league":"NFL","away":"BUF","home":"NE","awayScore":17,"homeScore":24,"status":"LIVE","clock":"Q4 8:31"}',
      );
      expect(utf8.decode(bytes), packet);
    });

    test('validates required fields', () {
      const gameData = GameData(
        league: '',
        awayTeam: 'BUF',
        homeTeam: 'NE',
        awayScore: 17,
        homeScore: 24,
        status: 'LIVE',
        clock: 'Q4 8:31',
      );

      expect(
        () => serializer.serializeToString(gameData),
        throwsA(isA<GamePacketValidationException>()),
      );
    });

    test('validates maximum field lengths', () {
      const gameData = GameData(
        league: 'NFL',
        awayTeam: 'A_VERY_LONG_TEAM_NAME_OVER_32_BYTES',
        homeTeam: 'NE',
        awayScore: 17,
        homeScore: 24,
        status: 'LIVE',
        clock: 'Q4 8:31',
      );

      expect(
        () => serializer.serializeToString(gameData),
        throwsA(isA<GamePacketValidationException>()),
      );
    });

    test('validates UTF-8 byte length instead of Dart character count', () {
      const gameData = GameData(
        league: 'NFL',
        awayTeam: '😀😀😀😀😀😀😀😀😀',
        homeTeam: 'NE',
        awayScore: 17,
        homeScore: 24,
        status: 'LIVE',
        clock: 'Q4 8:31',
      );

      expect(
        () => serializer.serializeToString(gameData),
        throwsA(isA<GamePacketValidationException>()),
      );
    });

    test('validates score range', () {
      const gameData = GameData(
        league: 'NFL',
        awayTeam: 'BUF',
        homeTeam: 'NE',
        awayScore: 256,
        homeScore: 24,
        status: 'LIVE',
        clock: 'Q4 8:31',
      );

      expect(
        () => serializer.serializeToString(gameData),
        throwsA(isA<GamePacketValidationException>()),
      );
    });

    test('allows maximum protocol score', () {
      const gameData = GameData(
        league: 'NFL',
        awayTeam: 'BUF',
        homeTeam: 'NE',
        awayScore: 255,
        homeScore: 0,
        status: 'FINAL',
        clock: 'FINAL',
      );

      expect(
        serializer.serializeToString(gameData),
        '{"version":1,"type":"game","league":"NFL","away":"BUF","home":"NE","awayScore":255,"homeScore":0,"status":"FINAL","clock":"FINAL"}',
      );
    });

    test('validates canonical status', () {
      const gameData = GameData(
        league: 'NFL',
        awayTeam: 'BUF',
        homeTeam: 'NE',
        awayScore: 17,
        homeScore: 24,
        status: 'DELAYED',
        clock: 'Q4 8:31',
      );

      expect(
        () => serializer.serializeToString(gameData),
        throwsA(isA<GamePacketValidationException>()),
      );
    });

    test('serializes a two-game slate with stable event identifiers', () {
      final packet =
          jsonDecode(
                serializer.serializeSlateToString(const [
                  GameData(
                    league: 'MLB',
                    awayTeam: 'NYY',
                    homeTeam: 'BOS',
                    awayScore: 4,
                    homeScore: 3,
                    status: 'LIVE',
                    clock: 'BOT 7',
                    eventId: 'game-101',
                  ),
                  GameData(
                    league: 'MLB',
                    awayTeam: 'LAD',
                    homeTeam: 'SF',
                    awayScore: 2,
                    homeScore: 2,
                    status: 'FINAL',
                    clock: 'FINAL',
                    eventId: 'game-102',
                  ),
                ]),
              )
              as Map<String, dynamic>;

      expect(packet['version'], 1);
      expect(packet['type'], 'slate');
      expect(packet['league'], 'MLB');
      expect(packet['games'], hasLength(2));
      expect((packet['games'] as List).first['id'], 'game-101');
      expect((packet['games'] as List).last['status'], 'FINAL');
    });

    test('accepts a maximum-size slate', () {
      final games = List.generate(
        GamePacketSerializer.maxLegacySlateGames,
        (index) => GameData(
          league: 'NBA',
          awayTeam: 'A$index',
          homeTeam: 'H$index',
          awayScore: index,
          homeScore: index + 1,
          status: 'LIVE',
          clock: 'Q1',
          eventId: 'id-$index',
        ),
      );

      expect(serializer.serializeSlate(games), isNotEmpty);
    });

    test('rejects invalid slate sizes and mixed leagues', () {
      const validGame = GameData(
        league: 'NFL',
        awayTeam: 'BUF',
        homeTeam: 'NE',
        awayScore: 17,
        homeScore: 24,
        status: 'LIVE',
        clock: 'Q4 8:31',
      );

      expect(
        () => serializer.serializeSlate(const []),
        throwsA(isA<GamePacketValidationException>()),
      );
      expect(
        () => serializer.serializeSlate(
          List.filled(GamePacketSerializer.maxLegacySlateGames + 1, validGame),
        ),
        throwsA(isA<GamePacketValidationException>()),
      );
      expect(
        () => serializer.serializeSlate(const [
          validGame,
          GameData(
            league: 'NBA',
            awayTeam: 'BOS',
            homeTeam: 'NYK',
            awayScore: 1,
            homeScore: 2,
            status: 'LIVE',
            clock: 'Q1',
          ),
        ]),
        throwsA(isA<GamePacketValidationException>()),
      );
    });

    test('rejects a slate that exceeds the BLE packet limit', () {
      const longTeam = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ123456';
      const longClock = '123456789012345678901234';
      final games = List.generate(
        GamePacketSerializer.maxLegacySlateGames,
        (index) => GameData(
          league: 'LONGLEAGUE12',
          awayTeam: longTeam,
          homeTeam: longTeam,
          awayScore: 255,
          homeScore: 255,
          status: 'UPCOMING',
          clock: longClock,
          eventId: '123456789012345678901234567890123456789012345678',
        ),
      );

      expect(
        () => serializer.serializeSlate(games),
        throwsA(isA<GamePacketValidationException>()),
      );
    });

    for (final entry in const {
      'one-game': 1,
      'four-game': 4,
      '15-game MLB': 15,
      '16-game NFL': 16,
      '20-game maximum': 20,
    }.entries) {
      test('builds a ${entry.key} chunked slate', () {
        final league = entry.key.contains('NFL') ? 'NFL' : 'MLB';
        final games = _games(entry.value, league: league);
        final transfer = serializer.buildChunkedSlateTransfer(
          games,
          slateId: 'slate-${entry.value}',
        );

        final start = jsonDecode(utf8.decode(transfer.startPacket)) as Map;
        expect(start['type'], 'slate_start');
        expect(start['totalGames'], entry.value);
        expect(start['totalChunks'], transfer.chunkPackets.length);
        expect(
          transfer.packets.every(
            (packet) =>
                packet.length <= GamePacketSerializer.maxSlatePacketBytes,
          ),
          isTrue,
        );

        final receivedGames = transfer.chunkPackets.expand((packet) {
          final chunk = jsonDecode(utf8.decode(packet)) as Map;
          return chunk['games'] as List;
        }).toList();
        expect(receivedGames, hasLength(entry.value));
        expect(
          jsonDecode(utf8.decode(transfer.endPacket))['type'],
          'slate_end',
        );
      });
    }

    test('rejects chunked slates above the 20-game logical limit', () {
      expect(
        () => serializer.buildChunkedSlateTransfer(
          _games(GamePacketSerializer.maxSlateGames + 1),
          slateId: 'too-many',
        ),
        throwsA(isA<GamePacketValidationException>()),
      );
    });

    test('rejects a malformed game before building transfer packets', () {
      final games = _games(2).toList();
      games[1] = const GameData(
        league: 'MLB',
        awayTeam: 'A1',
        homeTeam: 'H1',
        awayScore: 1,
        homeScore: 2,
        status: 'DELAYED',
        clock: 'TBD',
      );

      expect(
        () => serializer.buildChunkedSlateTransfer(games, slateId: 'malformed'),
        throwsA(isA<GamePacketValidationException>()),
      );
    });
  });
}

List<GameData> _games(int count, {String league = 'MLB'}) {
  return List.generate(
    count,
    (index) => GameData(
      league: league,
      awayTeam: 'AWAY$index',
      homeTeam: 'HOME$index',
      awayScore: index,
      homeScore: index + 1,
      status: index.isEven ? 'LIVE' : 'FINAL',
      clock: index.isEven ? 'BOT 7' : 'FINAL',
      eventId: '$league-event-$index',
    ),
  );
}
