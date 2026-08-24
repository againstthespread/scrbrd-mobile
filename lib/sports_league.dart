enum SportsLeague {
  nfl('NFL', 'nfl'),
  ncaaf('NCAAF', 'cfb'),
  nba('NBA', 'nba'),
  mlb('MLB', 'mlb'),
  pga('PGA', 'golf');

  const SportsLeague(this.label, this.pathSegment);

  final String label;
  final String pathSegment;

  bool get isFootball => this == nfl || this == ncaaf;
}
