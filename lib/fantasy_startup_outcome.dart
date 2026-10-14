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
    this.failures = const [],
  });

  final bool hasContent;
  final List<String> failures;
  final Future<FantasyStartupOutcome> Function() commit;
}
