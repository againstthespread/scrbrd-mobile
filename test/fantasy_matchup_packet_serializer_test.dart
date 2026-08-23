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

  test('long external names are safely truncated to protocol limits', () {
    final bytes = serializer.serialize(
      const FantasyMatchupDisplayData(
        leagueName: '1234567890123456789012345678901234567890123456789',
        userName: '123456789012345678901',
        userScore: 1,
        opponentName: 'abcdefghijklmnopqrstu',
        opponentScore: 2,
        week: 1,
        status: FantasyMatchupDisplayStatus.upcoming,
      ),
    );
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    expect(utf8.encode(json['leagueName'] as String), hasLength(48));
    expect(utf8.encode(json['userName'] as String), hasLength(20));
    expect(utf8.encode(json['opponentName'] as String), hasLength(20));
    expect(bytes.length, lessThanOrEqualTo(512));
  });

  test('multibyte truncation preserves valid UTF-8', () {
    final bytes = serializer.serialize(
      const FantasyMatchupDisplayData(
        leagueName: '🏈🏈🏈🏈🏈🏈🏈🏈🏈🏈🏈🏈🏈',
        userName: 'José José José José José',
        userScore: 0,
        opponentName: '東京東京東京東京東京東京東京',
        opponentScore: 0,
        week: 1,
        status: FantasyMatchupDisplayStatus.upcoming,
      ),
    );
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    expect(
      utf8.encode(json['leagueName'] as String).length,
      lessThanOrEqualTo(48),
    );
    expect(
      utf8.encode(json['userName'] as String).length,
      lessThanOrEqualTo(20),
    );
    expect(
      utf8.encode(json['opponentName'] as String).length,
      lessThanOrEqualTo(20),
    );
  });

  test('0-0 preseason matchup still serializes as upcoming Week 1', () {
    final json =
        jsonDecode(
              utf8.decode(
                serializer.serialize(
                  const FantasyMatchupDisplayData(
                    leagueName: 'League',
                    userName: 'Peter',
                    userScore: 0,
                    opponentName: 'Mike',
                    opponentScore: 0,
                    week: 1,
                    status: FantasyMatchupDisplayStatus.upcoming,
                  ),
                ),
              ),
            )
            as Map<String, dynamic>;
    expect(json, containsPair('week', 1));
    expect(json, containsPair('status', 'UPCOMING'));
  });

  test('invalid numeric and required display data still fail', () {
    expect(
      () => serializer.serialize(
        const FantasyMatchupDisplayData(
          leagueName: 'League',
          userName: 'Peter',
          userScore: double.nan,
          opponentName: 'Mike',
          opponentScore: 0,
          week: 1,
          status: FantasyMatchupDisplayStatus.live,
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => serializer.serialize(
        const FantasyMatchupDisplayData(
          leagueName: 'League',
          userName: 'Peter',
          userScore: 0,
          opponentName: 'Mike',
          opponentScore: 0,
          week: 0,
          status: FantasyMatchupDisplayStatus.live,
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
