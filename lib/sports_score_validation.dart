/// An incomplete score observation must fail the fetch, not become an empty or
/// shortened slate. Existing provider-failure handling retains committed content.
/// Deliberately not a FormatException: provider row-skipping must not hide it.
class SportsScoreValidationException implements Exception {
  const SportsScoreValidationException();

  @override
  String toString() => 'Sports scores are incomplete or invalid. Please retry.';
}

int validatedSportsScore(Object? value, {required bool allowMissing}) {
  if (value == null || (value is String && value.trim().isEmpty)) {
    if (allowMissing) return 0;
    throw const SportsScoreValidationException();
  }
  if (value is int && value >= 0) return value;
  if (value is num && value.isFinite && value >= 0 && value % 1 == 0) {
    final score = value.toInt();
    if (score == value) return score;
  }
  if (value is String && RegExp(r'^\d+$').hasMatch(value.trim())) {
    final parsed = int.tryParse(value.trim());
    if (parsed != null && parsed >= 0) return parsed;
  }
  throw const SportsScoreValidationException();
}
