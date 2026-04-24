import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'reminders.dart';

/// Pool of "Tip of the Day" command examples shown to the user each morning.
/// Index is chosen by (next7am.day - 1) % tips.length — deterministic per calendar day.
const List<String> kTipPool = [
  // General
  "Try: 'What's on my calendar today?'",
  "Try: 'Read my latest emails'",
  "Try: 'How long to get to work?'",
  "Try: 'Navigate to the nearest gas station'",
  "Try: 'Call John'",
  "Try: 'Set a reminder for 3pm to call mom'",
  "Try: 'What's the weather like today?'",
  "Try: 'Remember that I prefer highway routes'",
  "Try: 'What did you remember about me?'",
  "Try: 'Search for coffee shops near me'",
  "Try: 'What time is it in New York?'",
  "Try: 'Read me the email from Sarah'",
  "Try: 'Add a reminder for tomorrow at 9am'",
  "Try: 'What's my next meeting?'",
  "Try: 'Open YouTube and play jazz music'",
  "Try: 'What's the traffic like on my route?'",
  "Try: 'Search the web for latest mortgage rates'",
  "Try: 'Navigate home'",
  "Try: 'What are my upcoming reminders?'",
  "Try: 'Find emails from my boss this week'",
  // Follow Up Boss
  "Try: 'Show me my hot leads in Follow Up Boss'",
  "Try: 'What leads came in today?'",
  "Try: 'Add a note to John Smith's contact in FUB'",
  "Try: 'Who are my leads with no activity this week?'",
  "Try: 'Show me leads from Zillow'",
  "Try: 'What's the status of my pipeline?'",
  "Try: 'Find leads tagged as buyer in FUB'",
  "Try: 'Show me leads assigned to me today'",
  "Try: 'Search for lead Maria Garcia in FUB'",
  "Try: 'What appointments do I have with leads this week?'",
];

/// Manages the daily "Tip of the Day" reminder.
///
/// Call [ensureScheduled] on every app open (mobile only).
/// It schedules a one-shot reminder for the next 7am using the existing
/// RemindersService, replacing the previous tip. Users can see it (and delete
/// it) in the Reminders screen like any other reminder.
class TipOfDayService {
  static const String _idKey = 'tip_of_day_reminder_id';
  static const String _scheduledDateKey = 'tip_of_day_scheduled_date';

  /// Returns the DateTime of the next 7:00 AM.
  static DateTime _next7am() {
    final now = DateTime.now();
    final todayAt7 = DateTime(now.year, now.month, now.day, 7, 0);
    return todayAt7.isAfter(now)
        ? todayAt7
        : todayAt7.add(const Duration(days: 1));
  }

  /// Call once per app open on mobile. Schedules tomorrow's (or today's) 7am
  /// tip notification if not already done for that date.
  /// Does nothing if the user has disabled the feature.
  static Future<void> ensureScheduled() async {
    if (kIsWeb) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('tip_of_day_enabled') ?? true;
      if (!enabled) return;

      final next7am = _next7am();
      final targetDate = next7am.toIso8601String().substring(0, 10); // YYYY-MM-DD

      final lastScheduled = prefs.getString(_scheduledDateKey);

      // Already scheduled for this date — nothing to do.
      if (lastScheduled == targetDate) return;

      // Ensure notification permission is granted (best-effort, non-blocking).
      await RemindersService.instance.requestPermissions();

      // Cancel previous tip reminder if any.
      final oldId = prefs.getInt(_idKey);
      if (oldId != null) {
        try {
          await RemindersService.instance.cancelReminder(oldId);
        } catch (_) {
          // Ignore — may have already fired or been deleted by the user.
        }
      }

      // Pick tip by calendar day (deterministic).
      final tipIndex = (next7am.day - 1) % kTipPool.length;
      final tipText = kTipPool[tipIndex];

      // Schedule a one-shot reminder at next 7am using the existing service.
      final reminder = await RemindersService.instance.createReminder(
        text: tipText,
        whenLocal: next7am,
      );

      await prefs.setInt(_idKey, reminder.id);
      await prefs.setString(_scheduledDateKey, targetDate);

      debugPrint('[TipOfDay] Scheduled tip for $targetDate: $tipText');
    } catch (e) {
      debugPrint('[TipOfDay] Failed to schedule tip: $e');
    }
  }
}
