enum FantasyMatchupDisplayStatus {
  upcoming('UPCOMING'),
  live('LIVE'),
  finalStatus('FINAL');

  const FantasyMatchupDisplayStatus(this.wireValue);
  final String wireValue;
}
