import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/fantasy_league_config.dart';
import 'package:sports_hub_mobile/fantasy_matchup_display_data.dart';
import 'package:sports_hub_mobile/fantasy_matchup_packet_serializer.dart';
import 'package:sports_hub_mobile/fantasy_provider_models.dart';

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

  test('serializes optional projected-final scores', () {
    final bytes = serializer.serialize(
      const FantasyMatchupDisplayData(
        leagueName: "Peter's League",
        userName: 'PETER',
        userScore: 71.4,
        opponentName: 'MIKE',
        opponentScore: 83.2,
        userProjectedScore: 126.7,
        opponentProjectedScore: 119.4,
        week: 3,
        status: FantasyMatchupDisplayStatus.live,
      ),
    );
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

    expect(json['userProjectedScore'], 126.7);
    expect(json['opponentProjectedScore'], 119.4);
    expect(bytes.length, lessThanOrEqualTo(512));
  });

  test('omits unavailable projected-final scores', () {
    final json =
        jsonDecode(utf8.decode(serializer.serialize(matchup)))
            as Map<String, dynamic>;

    expect(json, isNot(contains('userProjectedScore')));
    expect(json, isNot(contains('opponentProjectedScore')));
  });

  test('normalized display data preserves provider projections', () {
    final display = FantasyMatchupDisplayData.fromNormalized(
      const FantasyMatchupSnapshot(
        league: FantasyLeagueDetails(
          provider: FantasyProvider.espn,
          leagueId: '123',
          season: 2026,
          name: 'League',
          scoringPeriod: 3,
          matchupPeriod: 3,
          teams: [],
        ),
        team: FantasyScoringTeam(
          team: FantasyTeamDetails(id: '1', name: 'Peter'),
          totalPoints: 71.4,
          projectedTotalPoints: 126.7,
          starters: [],
        ),
        opponent: FantasyScoringTeam(
          team: FantasyTeamDetails(id: '2', name: 'Mike'),
          totalPoints: 83.2,
          projectedTotalPoints: 119.4,
          starters: [],
        ),
      ),
    );

    expect(display.userScore, 71.4);
    expect(display.opponentScore, 83.2);
    expect(display.userProjectedScore, 126.7);
    expect(display.opponentProjectedScore, 119.4);
  });

  test('serializes identified fantasy slate packets', () {
    final entry =
        jsonDecode(
              utf8.decode(serializer.serialize(matchup, identity: 'espn:123')),
            )
            as Map<String, dynamic>;
    expect(entry['identity'], 'espn:123');
    expect(
      jsonDecode(utf8.decode(serializer.serializeSlateStart()))['type'],
      'fantasy_slate_start',
    );
    expect(
      jsonDecode(utf8.decode(serializer.serializeSlateEnd()))['type'],
      'fantasy_slate_end',
    );
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

  test('maximum projected slate packet remains under 512 bytes', () {
    final bytes = serializer.serialize(
      FantasyMatchupDisplayData(
        leagueName: List.filled(48, r'\').join(),
        userName: List.filled(20, r'\').join(),
        userScore: -9999.999999999998,
        opponentName: List.filled(20, r'\').join(),
        opponentScore: -9999.999999999998,
        userProjectedScore: -9999.999999999998,
        opponentProjectedScore: -9999.999999999998,
        week: 30,
        status: FantasyMatchupDisplayStatus.upcoming,
      ),
      identity: List.filled(48, 'e').join(),
    );

    expect(bytes, hasLength(504));
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
          userScore: 0,
          opponentName: 'Mike',
          opponentScore: 0,
          userProjectedScore: double.infinity,
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
