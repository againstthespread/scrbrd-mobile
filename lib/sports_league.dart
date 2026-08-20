enum SportsLeague {
  nfl('NFL', 'nfl'),
  nba('NBA', 'nba'),
  mlb('MLB', 'mlb'),
  pga('PGA', 'golf');

  const SportsLeague(this.label, this.pathSegment);

  final String label;
  final String pathSegment;
}
