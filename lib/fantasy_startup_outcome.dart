/// Content loaded and provider errors are independent startup facts.
class FantasyStartupOutcome {
  const FantasyStartupOutcome({
    this.hasContent = false,
    this.failures = const [],
  });

  final bool hasContent;
  final List<String> failures;
  bool get isEmpty => !hasContent && failures.isEmpty;
}

/// Fetched and validated content, with no device writes until commit is called.
class PreparedFantasyStartup {
  const PreparedFantasyStartup({
    required this.hasContent,
    required this.commit,
    this.commitAfterReset,
    this.commitWrites,
    this.finishObservation,
    this.failures = const [],
  });

  final bool hasContent;
  final List<String> failures;
  final Future<FantasyStartupOutcome> Function() commit;

  /// Optional split for catalog ownership: prepared writes inside the Bluetooth
  /// transaction, provider baseline observation after releasing that ownership.
  final Future<FantasyStartupOutcome> Function(bool reset)? commitWrites;
  final Future<FantasyStartupOutcome> Function(bool delivered)?
  finishObservation;

  /// Restores unchanged content after the existing destructive SYNC_START.
  final Future<FantasyStartupOutcome> Function()? commitAfterReset;
}
