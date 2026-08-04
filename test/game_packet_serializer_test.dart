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
  });
}
