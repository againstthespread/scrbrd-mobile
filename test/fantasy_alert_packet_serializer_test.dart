import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/fantasy_alert_packet_serializer.dart';
import 'package:sports_hub_mobile/console_device_transport.dart';
import 'package:sports_hub_mobile/fantasy_point_delta_tracker.dart';
import 'package:sports_hub_mobile/fantasy_scoring_correlation.dart';
import 'package:sports_hub_mobile/sleeper_models.dart';
import 'package:sports_hub_mobile/sports_league.dart';

void main() {
  const serializer = FantasyAlertPacketSerializer();

  test('serializes a dedicated version-1 fantasy alert', () {
    final json = _decode(
      serializer.serialize(
        _event(),
        userName: 'Peter',
        userScore: 104.7,
        opponentName: 'Mike',
        opponentScore: 97.2,
      ),
    );
    expect(json['version'], 1);
    expect(json['type'], 'fantasy_alert');
    expect(json['player'], "Ja'Marr Chase");
    expect(json['headline'], '50 YD REC TD');
    expect(json['points'], 12.0);
    expect(json['confidence'], 'high');
  });

  test('unmatched event has no fabricated headline', () {
    final json = _decode(
      serializer.serialize(
        _event(
          explanation: null,
          confidence: FantasyCorrelationConfidence.none,
        ),
        userName: 'Peter',
        userScore: 1,
        opponentName: 'Mike',
        opponentScore: 2,
      ),
    );
    expect(json['headline'], '');
    expect(json['confidence'], 'none');
  });

  test('formats positive, negative, and meaningful fractional points', () {
    expect(formatFantasyAlertPoints(12), '+12.0');
    expect(formatFantasyAlertPoints(0.5), '+0.5');
    expect(formatFantasyAlertPoints(-2), '-2.0');
    expect(formatFantasyAlertPoints(-0.1), '-0.1');
    expect(formatFantasyAlertPoints(1.25), '+1.25');
  });

  test('UTF-8 string limits are enforced without splitting characters', () {
    final json = _decode(
      serializer.serialize(
        _event(
          playerName: List.filled(20, 'é').join(),
          explanation: List.filled(40, 'X').join(),
        ),
        userName: List.filled(30, 'U').join(),
        userScore: 1,
        opponentName: List.filled(30, 'O').join(),
        opponentScore: 2,
      ),
    );
    expect(utf8.encode(json['player'] as String).length, lessThanOrEqualTo(32));
    expect(utf8.encode(json['headline'] as String).length, 32);
    expect(utf8.encode(json['userName'] as String).length, 20);
    expect(utf8.encode(json['opponentName'] as String).length, 20);
  });

  test('maximum fields remain below the safe BLE packet size', () {
    final packet = serializer.serialize(
      _event(
        playerName: List.filled(32, 'P').join(),
        explanation: List.filled(32, 'H').join(),
      ),
      userName: List.filled(20, 'U').join(),
      userScore: 999.99,
      opponentName: List.filled(20, 'O').join(),
      opponentScore: 999.99,
    );
    expect(packet.length, lessThanOrEqualTo(512));
  });

  test('fantasy alerts are not sports leagues', () {
    expect(
      SportsLeague.values.map((league) => league.label),
      isNot(contains('FANTASY')),
    );
  });

  test('ConsoleDeviceTransport supports fantasy alerts', () async {
    final output = <String>[];
    await runZoned(
      () => const ConsoleDeviceTransport().sendFantasyAlert(
        _event(),
        userName: 'Peter',
        userScore: 104.7,
        opponentName: 'Mike',
        opponentScore: 97.2,
      ),
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, message) => output.add(message),
      ),
    );
    expect(output.single, contains('"type":"fantasy_alert"'));
  });
}

Map<String, dynamic> _decode(List<int> bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

FantasyScoringEvent _event({
  String playerName = "Ja'Marr Chase",
  String? explanation = '50 YD REC TD',
  FantasyCorrelationConfidence confidence = FantasyCorrelationConfidence.high,
}) {
  final player = SleeperFantasyPlayer(
    sleeperPlayerId: '1',
    fullName: playerName,
    firstName: "Ja'Marr",
    lastName: 'Chase',
    position: 'WR',
    nflTeam: 'CIN',
    espnPlayerId: null,
  );
  const delta = FantasyPointDelta(
    playerId: '1',
    side: FantasyMatchupSide.user,
    previousPoints: 0,
    currentPoints: 12,
    delta: 12,
  );
  return FantasyScoringEvent(
    delta: delta,
    player: player,
    matchedPlay: null,
    confidence: confidence,
    explanation: explanation,
    predictedPoints: 12,
    diagnostic: 'test',
  );
}
