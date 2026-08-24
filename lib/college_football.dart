enum NcaafConference {
  acc('ACC'),
  bigTen('Big Ten'),
  big12('Big 12'),
  sec('SEC');

  const NcaafConference(this.displayName);
  final String displayName;
}

class CollegeFootballPreferences {
  CollegeFootballPreferences(Iterable<NcaafConference> conferences)
    : conferences = Set.unmodifiable(conferences) {
    if (this.conferences.isEmpty) {
      throw ArgumentError(
        'At least one college football conference is required.',
      );
    }
  }

  factory CollegeFootballPreferences.defaults() =>
      CollegeFootballPreferences(NcaafConference.values);

  final Set<NcaafConference> conferences;
  bool contains(NcaafConference conference) => conferences.contains(conference);

  CollegeFootballPreferences toggled(
    NcaafConference conference,
    bool selected,
  ) {
    final next = Set<NcaafConference>.of(conferences);
    selected ? next.add(conference) : next.remove(conference);
    return CollegeFootballPreferences(next);
  }
}
