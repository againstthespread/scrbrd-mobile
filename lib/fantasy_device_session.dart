import 'fantasy_matchup_display_data.dart';

class FantasyDeviceSession {
  FantasyMatchupDisplayData? _baseline;
  String? _context;

  FantasyMatchupDisplayData? get baseline => _baseline;
  String? get context => _context;

  bool matches(FantasyMatchupDisplayData data, String context) =>
      _context == context && _baseline == data;

  void record(FantasyMatchupDisplayData data, String context) {
    _baseline = data;
    _context = context;
  }

  void reset() {
    _baseline = null;
    _context = null;
  }
}
