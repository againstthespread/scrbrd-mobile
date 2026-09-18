import 'fantasy_matchup_display_data.dart';

abstract interface class FantasyMatchupTransport {
  Future<void> sendFantasyMatchup(FantasyMatchupDisplayData matchup);
  Future<void> clearFantasyMatchup();
}

class FantasyMatchupSlateEntry {
  const FantasyMatchupSlateEntry({
    required this.identity,
    required this.matchup,
  });
  final String identity;
  final FantasyMatchupDisplayData matchup;
}

abstract interface class FantasySlateTransport {
  Future<void> sendFantasySlate(List<FantasyMatchupSlateEntry> entries);
}
