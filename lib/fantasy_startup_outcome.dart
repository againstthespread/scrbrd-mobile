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
