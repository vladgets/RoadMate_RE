/// Shared utility for parsing natural language time period strings
/// into date ranges. Used by PhotoIndexService and VoiceMemoryStore.
class TimePeriodParser {
  /// Parse a time period string into a start/end DateTime pair.
  /// Returns null if the period cannot be parsed.
  static ({DateTime start, DateTime end})? parse(String timePeriod) {
    final now = DateTime.now();
    final query = timePeriod.toLowerCase();

    DateTime? startDate;
    DateTime? endDate;

    if (query.contains('today')) {
      startDate = DateTime(now.year, now.month, now.day);
      endDate = now;
    } else if (query.contains('yesterday')) {
      final yesterday = now.subtract(const Duration(days: 1));
      startDate = DateTime(yesterday.year, yesterday.month, yesterday.day);
      endDate = DateTime(yesterday.year, yesterday.month, yesterday.day, 23, 59, 59);
    } else if (query.contains('last week') || query.contains('past week')) {
      startDate = now.subtract(const Duration(days: 7));
      endDate = now;
    } else if (query.contains('last month') || query.contains('past month')) {
      startDate = now.subtract(const Duration(days: 30));
      endDate = now;
    } else if (query.contains('last year') || query.contains('past year')) {
      startDate = now.subtract(const Duration(days: 365));
      endDate = now;
    } else {
      // Try to parse specific year
      final yearMatch = RegExp(r'\b(20\d{2})\b').firstMatch(query);
      if (yearMatch != null) {
        final year = int.parse(yearMatch.group(1)!);
        startDate = DateTime(year, 1, 1);
        endDate = DateTime(year, 12, 31, 23, 59, 59);
      }
    }

    if (startDate == null || endDate == null) return null;

    return (start: startDate, end: endDate);
  }
}
