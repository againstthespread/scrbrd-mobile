import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/fantasy_matchup_display_data.dart';
import 'package:sports_hub_mobile/fantasy_matchup_packet_serializer.dart';

void main() {
  const serializer = FantasyMatchupPacketSerializer();
  const matchup = FantasyMatchupDisplayData(
    leagueName: "Peter's League",
    userName: 'PETER',
    userScore: 104.7,
    opponentName: 'MIKE',
    opponentScore: 97.25,
    week: 3,
    status: FantasyMatchupDisplayStatus.live,
  );

  test('serializes a decimal persistent fantasy matchup under 512 bytes', () {
    final bytes = serializer.serialize(matchup);
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    expect(bytes.length, lessThanOrEqualTo(512));
    expect(json, containsPair('version', 1));
    expect(json, containsPair('type', 'fantasy_matchup'));
    expect(json, containsPair('userScore', 104.7));
    expect(json, containsPair('opponentScore', 97.25));
    expect(json, containsPair('status', 'LIVE'));
  });

  test('enforces explicit string limits', () {
    expect(
      () => serializer.serialize(
        const FantasyMatchupDisplayData(
          leagueName: 'League',
          userName: '123456789012345678901',
          userScore: 1,
          opponentName: 'Opponent',
          opponentScore: 2,
          week: 1,
          status: FantasyMatchupDisplayStatus.upcoming,
        ),
      ),
      throwsFormatException,
    );
  });

  test('serializes an isolated fantasy clear command', () {
    expect(jsonDecode(utf8.decode(serializer.serializeClear())), {
      'version': 1,
      'type': 'fantasy_clear',
    });
  });
}
