import 'dart:convert';

/// Trims display text to an owned device buffer without splitting UTF-8.
String truncateUtf8DisplayText(String value, int maximumBytes) {
  final normalized = value.trim();
  final bytes = utf8.encode(normalized);
  if (bytes.length <= maximumBytes) return normalized;
  var end = maximumBytes;
  while (end > 0) {
    try {
      return utf8.decode(bytes.sublist(0, end));
    } on FormatException {
      end--;
    }
  }
  return '';
}
