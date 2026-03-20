// lib/services/reminders_service.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:workmanager/workmanager.dart';

/// Simple Reminder model.
class Reminder {
  Reminder({
    required this.id,
    required this.text,
    required this.scheduledAtLocalIso,
    required this.createdAtLocalIso,
    this.status = ReminderStatus.scheduled,
    this.recurrence,
    this.dayOfWeek,
    this.aiPrompt,
  });

  final int id;

  /// Display text / label. For AI reminders this is just a human-readable label.
  final String text;

  /// ISO8601 string in *local time* (no timezone offset baked in).
  final String scheduledAtLocalIso;

  /// ISO8601 local timestamp for bookkeeping.
  final String createdAtLocalIso;

  ReminderStatus status;

  /// Recurrence: null = one-shot, 'daily' = every day, 'weekly' = same weekday.
  final String? recurrence;

  /// Day of week for weekly recurrence: 1=Monday … 7=Sunday (matches DateTime.weekday).
  final int? dayOfWeek;

  /// If set, AI generates the notification body at fire time using this instruction.
  final String? aiPrompt;

  DateTime get scheduledAtLocal => DateTime.parse(scheduledAtLocalIso);
  DateTime get createdAtLocal => DateTime.parse(createdAtLocalIso);

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'text': text,
      'scheduledAtLocalIso': scheduledAtLocalIso,
      'createdAtLocalIso': createdAtLocalIso,
      'status': status.name,
    };
    if (recurrence != null) m['recurrence'] = recurrence;
    if (dayOfWeek != null) m['dayOfWeek'] = dayOfWeek;
    if (aiPrompt != null) m['aiPrompt'] = aiPrompt;
    return m;
  }

  static Reminder fromJson(Map<String, dynamic> json) {
    final statusStr = (json['status'] ?? 'scheduled').toString();
    final status = ReminderStatus.values.firstWhere(
      (e) => e.name == statusStr,
      orElse: () => ReminderStatus.scheduled,
    );

    return Reminder(
      id: (json['id'] as num).toInt(),
      text: (json['text'] ?? '').toString(),
      scheduledAtLocalIso: (json['scheduledAtLocalIso'] ?? '').toString(),
      createdAtLocalIso: (json['createdAtLocalIso'] ?? '').toString(),
      status: status,
      recurrence: json['recurrence'] as String?,
      dayOfWeek: (json['dayOfWeek'] as num?)?.toInt(),
      aiPrompt: json['aiPrompt'] as String?,
    );
  }
}

enum ReminderStatus { scheduled, fired, canceled }

/// Computes the next fire time for a reminder (handles recurrence).
DateTime computeNextOccurrence(Reminder r) {
  if (r.recurrence == null) return r.scheduledAtLocal;
  final now = DateTime.now();
  final h = r.scheduledAtLocal.hour;
  final m = r.scheduledAtLocal.minute;

  if (r.recurrence == 'daily') {
    var next = DateTime(now.year, now.month, now.day, h, m);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    return next;
  } else {
    // weekly
    final target = r.dayOfWeek ?? r.scheduledAtLocal.weekday;
    var next = DateTime(now.year, now.month, now.day, h, m);
    while (next.weekday != target || !next.isAfter(now)) {
      next = next.add(const Duration(days: 1));
    }
    return next;
  }
}

/// RoadMate local reminders service:
/// - Stores reminders in SharedPreferences
/// - Schedules local notifications using flutter_local_notifications
/// - Uses timezone package to schedule correctly with DST changes
/// - Supports recurring reminders (daily/weekly)
/// - Supports AI-generated notification content via WorkManager (Android only)
class RemindersService {
  RemindersService._();

  /// Register this to receive notification content when the user taps a reminder.
  /// Called with (title, body) — set by main.dart after the conversation store is ready.
  static void Function(String title, String body)? onNotificationTap;

  static const String _pendingChatKey = 'roadmate_pending_reminder_chat';

  static final RemindersService instance = RemindersService._();

  static const String _prefsKey = 'roadmate_reminders_v1';

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _tzConfigured = false;

  /// Call once early in app lifecycle (e.g., in initState after first frame).
  Future<void> init() async {
    if (_initialized) return;

    // Timezone init (safe to call once).
    tz_data.initializeTimeZones();

    // IMPORTANT: tz.local defaults to UTC unless we set it.
    if (!_tzConfigured) {
      try {
        final tzInfo = await FlutterTimezone.getLocalTimezone();
        final String tzName = tzInfo.identifier;
        tz.setLocalLocation(tz.getLocation(tzName));
        debugPrint('[Reminders] Local timezone set to $tzName');
      } catch (e) {
        debugPrint('[Reminders] Failed to set local timezone: $e');
      }
      _tzConfigured = true;
    }

    // Plugin init.
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');

    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const initSettings =
        InitializationSettings(android: androidInit, iOS: iosInit);

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (resp) {
        debugPrint('[Reminders] Notification tapped: ${resp.payload}');
        _handleNotificationTap(resp.payload);
      },
    );

    // Create Android notification channel
    const androidChannel = AndroidNotificationChannel(
      'roadmate_reminders',
      'Reminders',
      description: 'RoadMate scheduled reminders',
      importance: Importance.max,
    );

    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(androidChannel);
    }

    _initialized = true;
  }

  /// Schedule a quick test reminder 1 minute from now with the given text.
  Future<void> scheduleReminderInOneMinute(String text) async {
    await init();

    final permsOk = await requestPermissions();
    debugPrint('[Test] Permissions granted: $permsOk');

    final now = DateTime.now();
    final when = now.add(const Duration(minutes: 1));

    try {
      await createReminder(text: text, whenLocal: when);
      debugPrint('[Test] Test reminder created successfully');
    } catch (e, st) {
      debugPrint('[Test] Failed to schedule test reminder: $e\n$st');
      rethrow;
    }
  }

  /// Request notification permissions.
  Future<bool> requestPermissions() async {
    await init();

    bool ok = true;

    final ios = _notifications
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      final granted = await ios.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      ok = ok && (granted ?? false);
    }

    final androidGranted = await _notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission() ??
        true;

    ok = ok && androidGranted;

    return ok;
  }

  /// Create + schedule a reminder notification.
  ///
  /// [whenLocal] should be a DateTime in the user's local time.
  /// [recurrence]: null = one-shot, 'daily', or 'weekly'.
  /// [dayOfWeek]: 1=Mon..7=Sun for weekly recurrence.
  /// [aiPrompt]: if set, WorkManager will generate notification body at fire time (Android only).
  /// Returns the created Reminder.
  Future<Reminder> createReminder({
    required String text,
    required DateTime whenLocal,
    String? recurrence,
    int? dayOfWeek,
    String? aiPrompt,
  }) async {
    await init();

    final id = _makeId(whenLocal);
    final now = DateTime.now();

    final reminder = Reminder(
      id: id,
      text: text.trim(),
      scheduledAtLocalIso: _toLocalIso(whenLocal),
      createdAtLocalIso: _toLocalIso(now),
      status: ReminderStatus.scheduled,
      recurrence: recurrence,
      dayOfWeek: dayOfWeek,
      aiPrompt: aiPrompt,
    );

    // Persist first, but avoid duplicates for the same id.
    final all = await _loadAll();
    all.removeWhere((r) => r.id == reminder.id);
    all.add(reminder);
    await _saveAll(all);

    // Add a pending chat entry so the reminder appears in chat when it fires,
    // even if the user never taps the notification (e.g. while driving).
    // AI reminders have a placeholder body; it gets updated at fire time.
    if (aiPrompt == null) {
      await _addPendingChatEntry(
        reminderId: id,
        title: 'Reminder',
        body: reminder.text,
        fireTime: whenLocal,
      );
    }

    // Schedule notification. If scheduling fails, roll back.
    try {
      if (aiPrompt != null && Platform.isAndroid) {
        // AI reminders on Android: use WorkManager to generate content at fire time.
        await _scheduleAiReminder(reminder);
      } else {
        // Regular or iOS AI reminder: use flutter_local_notifications.
        await _scheduleNotification(reminder);
      }
    } catch (e) {
      debugPrint('[Reminders] Failed to schedule notification: $e');
      final rollback = await _loadAll();
      rollback.removeWhere((r) => r.id == reminder.id);
      await _saveAll(rollback);
      rethrow;
    }

    return reminder;
  }

  /// Cancel a reminder (also cancels the underlying scheduled notification/task).
  Future<void> cancelReminder(int id) async {
    await init();

    // Remove from pending chat queue so it won't appear in chat.
    await _removePendingChatEntry(id);

    // Cancel flutter_local_notifications (covers regular + iOS AI reminders)
    await _notifications.cancel(id);

    // Cancel WorkManager task (covers Android AI reminders)
    if (Platform.isAndroid) {
      try {
        await Workmanager().cancelByUniqueName('ai_reminder_$id');
      } catch (_) {
        // WorkManager may not have a task for this id; ignore.
      }
    }

    final all = await _loadAll();
    for (final r in all) {
      if (r.id == id) {
        r.status = ReminderStatus.canceled;
      }
    }
    await _saveAll(all);
  }

  /// Returns upcoming reminders (status == scheduled, in the future or recurring).
  Future<List<Reminder>> listUpcoming() async {
    final all = await _loadAll();
    final now = DateTime.now();

    final upcoming = all
        .where((r) =>
            r.status == ReminderStatus.scheduled &&
            (r.recurrence != null || r.scheduledAtLocal.isAfter(now)))
        .toList();

    upcoming.sort(
        (a, b) => computeNextOccurrence(a).compareTo(computeNextOccurrence(b)));
    return upcoming;
  }

  /// Update the AI prompt of an AI-generated reminder.
  /// Re-schedules the WorkManager task so the next notification uses the new prompt.
  Future<void> updateAiPrompt(int id, String newAiPrompt) async {
    await init();
    final all = await _loadAll();
    final idx = all.indexWhere((r) => r.id == id);
    if (idx < 0) return;

    final old = all[idx];
    final updated = Reminder(
      id: old.id,
      text: newAiPrompt.trim(), // keep label in sync with prompt
      scheduledAtLocalIso: old.scheduledAtLocalIso,
      createdAtLocalIso: old.createdAtLocalIso,
      status: old.status,
      recurrence: old.recurrence,
      dayOfWeek: old.dayOfWeek,
      aiPrompt: newAiPrompt.trim(),
    );
    all[idx] = updated;
    await _saveAll(all);

    if (Platform.isAndroid) {
      await _scheduleAiReminder(updated);
    }
  }

  /// Update only the display text/label of a reminder.
  /// Re-schedules the notification so the new text appears in the notification.
  Future<void> updateReminderText(int id, String newText) async {
    await init();
    final all = await _loadAll();
    final idx = all.indexWhere((r) => r.id == id);
    if (idx < 0) return;

    final old = all[idx];
    final updated = Reminder(
      id: old.id,
      text: newText.trim(),
      scheduledAtLocalIso: old.scheduledAtLocalIso,
      createdAtLocalIso: old.createdAtLocalIso,
      status: old.status,
      recurrence: old.recurrence,
      dayOfWeek: old.dayOfWeek,
      aiPrompt: old.aiPrompt,
    );
    all[idx] = updated;
    await _saveAll(all);

    // Re-schedule so the updated label takes effect.
    if (old.aiPrompt != null && Platform.isAndroid) {
      await _scheduleAiReminder(updated);
    } else {
      await _notifications.cancel(id);
      await _scheduleNotification(updated);
    }
  }

  /// Returns all reminders including canceled/fired.
  Future<List<Reminder>> listAll() async {
    final all = await _loadAll();
    all.sort((a, b) => a.scheduledAtLocal.compareTo(b.scheduledAtLocal));
    return all;
  }

  /// Optional cleanup: remove reminders that are canceled or long past.
  Future<void> prune({Duration olderThan = const Duration(days: 7)}) async {
    final all = await _loadAll();
    final cutoff = DateTime.now().subtract(olderThan);

    final kept = all.where((r) {
      if (r.status == ReminderStatus.scheduled) return true;
      return r.scheduledAtLocal.isAfter(cutoff);
    }).toList();

    await _saveAll(kept);
  }

  // -----------------------
  // Internal implementation
  // -----------------------

  int _makeId(DateTime whenLocal) {
    final ms = whenLocal.millisecondsSinceEpoch;
    final id = ms % 2147483647;
    return id == 0 ? 1 : id;
  }

  String _toLocalIso(DateTime dt) {
    final local = dt.toLocal();
    return DateTime(
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
      local.second,
      local.millisecond,
      local.microsecond,
    ).toIso8601String();
  }

  Future<void> _scheduleNotification(Reminder r) async {
    final localLocation = tz.local;
    final scheduledLocal = r.scheduledAtLocal;

    var tzWhen = tz.TZDateTime(
      localLocation,
      scheduledLocal.year,
      scheduledLocal.month,
      scheduledLocal.day,
      scheduledLocal.hour,
      scheduledLocal.minute,
      scheduledLocal.second,
      scheduledLocal.millisecond,
      scheduledLocal.microsecond,
    );

    // Guard: some platforms reject scheduling at or before "now".
    final nowTz = tz.TZDateTime.now(localLocation);
    if (!tzWhen.isAfter(nowTz)) {
      tzWhen = nowTz.add(const Duration(seconds: 5));
    }

    const androidDetails = AndroidNotificationDetails(
      'roadmate_reminders',
      'Reminders',
      channelDescription: 'RoadMate scheduled reminders',
      importance: Importance.max,
      priority: Priority.high,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Determine repeat component for recurring reminders.
    DateTimeComponents? matchComponents;
    if (r.recurrence == 'daily') {
      matchComponents = DateTimeComponents.time;
    } else if (r.recurrence == 'weekly') {
      matchComponents = DateTimeComponents.dayOfWeekAndTime;
    }

    await _notifications.zonedSchedule(
      r.id,
      'Reminder',
      r.text,
      tzWhen,
      details,
      payload: jsonEncode({'reminder_id': r.id, 'title': 'Reminder', 'body': r.text}),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: matchComponents,
    );

    final pending = await _notifications.pendingNotificationRequests();
    debugPrint('[Reminders] Pending notifications count: ${pending.length}');
    debugPrint('[Reminders] Scheduled id=${r.id} at ${r.scheduledAtLocalIso}'
        '${r.recurrence != null ? " (${r.recurrence})" : ""}');
  }

  /// Schedule an AI-generated reminder via WorkManager (Android only).
  Future<void> _scheduleAiReminder(Reminder r) async {
    final delay = computeNextOccurrence(r).difference(DateTime.now());

    await Workmanager().registerOneOffTask(
      'ai_reminder_${r.id}',
      'ai_reminder',
      initialDelay: delay.isNegative ? Duration.zero : delay,
      inputData: {
        'reminder_id': r.id,
        'recurrence': r.recurrence ?? '',
        'day_of_week': r.dayOfWeek ?? 0,
        'scheduled_iso': r.scheduledAtLocalIso,
        'text': r.text,
        'ai_prompt': r.aiPrompt ?? '',
      },
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );

    debugPrint('[Reminders] AI reminder WorkManager task scheduled: id=${r.id}'
        ' delay=${delay.inMinutes}m');
  }

  // ── Pending chat queue ──────────────────────────────────────────────────────
  // Written at schedule time; drained on app start so reminders appear in chat
  // even when the user never taps the notification (e.g. while driving).

  Future<void> _addPendingChatEntry({
    required int reminderId,
    required String title,
    required String body,
    required DateTime fireTime,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingChatKey);
      final list = raw != null ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
      list.removeWhere((e) => (e['id'] as num?)?.toInt() == reminderId);
      list.add({'id': reminderId, 'title': title, 'body': body, 'fireTime': fireTime.toIso8601String()});
      await prefs.setString(_pendingChatKey, jsonEncode(list));
    } catch (_) {}
  }

  Future<void> _removePendingChatEntry(int reminderId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingChatKey);
      if (raw == null) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      list.removeWhere((e) => (e['id'] as num?)?.toInt() == reminderId);
      await prefs.setString(_pendingChatKey, jsonEncode(list));
    } catch (_) {}
  }

  /// Returns all pending reminder chat entries whose fire time has passed,
  /// and removes them from the queue. Call on app start to add them to chat.
  Future<List<({String title, String body})>> drainFiredReminders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingChatKey);
      if (raw == null) return [];

      final now = DateTime.now();
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final fired = <Map<String, dynamic>>[];
      final remaining = <Map<String, dynamic>>[];

      for (final entry in list) {
        final fireTime = DateTime.tryParse(entry['fireTime'] as String? ?? '');
        if (fireTime != null && fireTime.isBefore(now)) {
          fired.add(entry);
        } else {
          remaining.add(entry);
        }
      }

      if (fired.isEmpty) return [];

      await prefs.setString(_pendingChatKey, jsonEncode(remaining));
      return fired.map((e) => (
        title: (e['title'] as String?) ?? 'Reminder',
        body: (e['body'] as String?) ?? '',
      )).toList();
    } catch (_) {
      return [];
    }
  }

  // ── Notification tap handling ────────────────────────────────────────────────

  /// Parse payload and fire [onNotificationTap] if registered.
  static void _handleNotificationTap(String? payload) {
    if (payload == null || onNotificationTap == null) return;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final title = (data['title'] as String?)?.trim() ?? 'Reminder';
      final body = (data['body'] as String?)?.trim() ?? '';
      if (body.isNotEmpty) onNotificationTap!(title, body);
    } catch (_) {}
  }

  /// Returns the payload of the notification that launched the app (if any).
  /// Call this on startup to handle the case where the app was terminated
  /// when the user tapped a notification.
  Future<Map<String, dynamic>?> getLaunchNotificationPayload() async {
    await init();
    try {
      final details = await _notifications.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp == true) {
        final payload = details!.notificationResponse?.payload;
        if (payload != null) {
          return jsonDecode(payload) as Map<String, dynamic>;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<List<Reminder>> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.trim().isEmpty) return <Reminder>[];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Reminder>[];

      return decoded
          .whereType<Map>()
          .map((m) => Reminder.fromJson(m.cast<String, dynamic>()))
          .toList();
    } catch (e) {
      debugPrint('[Reminders] Failed to decode reminders: $e');
      return <Reminder>[];
    }
  }

  Future<void> _saveAll(List<Reminder> reminders) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(reminders.map((r) => r.toJson()).toList());
    await prefs.setString(_prefsKey, encoded);
  }

  // -----------------------
  // Tool handlers (for Realtime function calls)
  // -----------------------

  /// Tool: reminder_create
  /// Required args: when_iso (local ISO8601)
  /// Optional args: text, recurrence, day_of_week, ai_prompt, request_permissions
  Future<Map<String, dynamic>> toolCreate(dynamic args) async {
    await init();

    Map<String, dynamic> a;
    if (args == null) {
      a = <String, dynamic>{};
    } else if (args is Map<String, dynamic>) {
      a = args;
    } else if (args is Map) {
      a = args.cast<String, dynamic>();
    } else if (args is String && args.trim().isNotEmpty) {
      a = jsonDecode(args) as Map<String, dynamic>;
    } else {
      a = <String, dynamic>{};
    }

    final text = (a['text'] ?? a['message'] ?? '').toString().trim();
    final whenIso = (a['when_iso'] ?? a['when'] ?? '').toString().trim();
    final recurrence = (a['recurrence'] as String?)?.trim();
    final dayOfWeek = (a['day_of_week'] as num?)?.toInt();
    final aiPrompt = (a['ai_prompt'] as String?)?.trim();
    final requestPerms = a['request_permissions'] == null
        ? true
        : (a['request_permissions'] == true);

    if (whenIso.isEmpty) {
      throw Exception('reminder_create: missing "when_iso"');
    }

    // text is the label; for AI reminders it can be auto-generated
    final label = text.isNotEmpty
        ? text
        : (aiPrompt != null ? 'AI Reminder' : 'Reminder');

    // Ask for notification permission if needed (best-effort).
    if (requestPerms) {
      final ok = await requestPermissions();
      if (!ok) {
        return {
          'ok': false,
          'error': 'Notifications permission not granted.',
        };
      }
    }

    final whenLocal = DateTime.parse(whenIso).toLocal();

    // For one-shot reminders, must be in the future.
    // For recurring, the next occurrence will be computed automatically.
    if (recurrence == null && !whenLocal.isAfter(DateTime.now())) {
      return {
        'ok': false,
        'error': 'Reminder time must be in the future.',
      };
    }

    final r = await createReminder(
      text: label,
      whenLocal: whenLocal,
      recurrence: recurrence,
      dayOfWeek: dayOfWeek,
      aiPrompt: aiPrompt,
    );

    return {
      'ok': true,
      'reminder': r.toJson(),
    };
  }

  /// Tool: reminder_list
  /// Returns { "reminders": [...] }
  Future<Map<String, dynamic>> toolList() async {
    final upcoming = await listUpcoming();
    return {
      'ok': true,
      'reminders': upcoming.map((r) => r.toJson()).toList(),
    };
  }

  /// Tool: reminder_cancel
  /// Expected args: { "id": 123 }
  Future<Map<String, dynamic>> toolCancel(dynamic args) async {
    await init();

    Map<String, dynamic> a;
    if (args == null) {
      a = <String, dynamic>{};
    } else if (args is Map<String, dynamic>) {
      a = args;
    } else if (args is Map) {
      a = args.cast<String, dynamic>();
    } else if (args is String && args.trim().isNotEmpty) {
      a = jsonDecode(args) as Map<String, dynamic>;
    } else {
      a = <String, dynamic>{};
    }

    final idVal = a['id'];
    if (idVal == null) {
      throw Exception('reminder_cancel: missing "id"');
    }

    final id = (idVal is num) ? idVal.toInt() : int.parse(idVal.toString());
    await cancelReminder(id);

    return {
      'ok': true,
      'id': id,
    };
  }
}
