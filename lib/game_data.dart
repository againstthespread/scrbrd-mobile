import 'sports_game.dart';

class GameData {
  const GameData({
    this.protocolVersion = 1,
    required this.league,
    required this.awayTeam,
    required this.homeTeam,
    required this.awayScore,
    required this.homeScore,
    required this.status,
    required this.clock,
    this.statusDetail,
    this.scheduledStartTime,
    this.eventId,
    this.baseballState,
  });

  final int protocolVersion;
  final String league;
  final String awayTeam;
  final String homeTeam;
  final int awayScore;
  final int homeScore;
  final String status;
  final String clock;
  final String? statusDetail;
  final DateTime? scheduledStartTime;
  final String? eventId;
  final BaseballGameState? baseballState;

  Map<String, Object> toJson() {
    final json = <String, Object>{
      'version': protocolVersion,
      'league': league,
      'away': awayTeam,
      'home': homeTeam,
      'awayScore': awayScore,
      'homeScore': homeScore,
      'status': status,
      'clock': clock,
    };
    final state = baseballState;
    if (state != null) {
      json.addAll({
        'onFirst': state.runnerOnFirst,
        'onSecond': state.runnerOnSecond,
        'onThird': state.runnerOnThird,
        'outs': state.outs,
      });
    }
    return json;
  }
}
