import 'fantasy_matchup_display_data.dart';

abstract interface class FantasyMatchupTransport {
  Future<void> sendFantasyMatchup(FantasyMatchupDisplayData matchup);
  Future<void> clearFantasyMatchup();
}
