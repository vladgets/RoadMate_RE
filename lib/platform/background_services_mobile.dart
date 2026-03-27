import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    if (taskName == 'ai_reminder') {
      await _handleAiReminderTask(inputData ?? {});
    }
    return true;
  });
}

Future<void> _handleAiReminderTask(Map<String, dynamic> inputData) async {
  try {
    final reminderId = (inputData['reminder_id'] as num?)?.toInt() ?? 0;
    final recurrence = (inputData['recurrence'] as String?) ?? '';
    final dayOfWeek = (inputData['day_of_week'] as num?)?.toInt() ?? 0;
    final scheduledIso = (inputData['scheduled_iso'] as String?) ?? '';
    final label = (inputData['text'] as String?) ?? 'Reminder';
    final aiPrompt = (inputData['ai_prompt'] as String?) ?? '';

    if (reminderId == 0) return;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('roadmate_reminders_v1');
    bool isCanceled = false;
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List?;
        if (decoded != null) {
          for (final item in decoded) {
            if (item is Map && (item['id'] as num?)?.toInt() == reminderId) {
              isCanceled = (item['status'] as String?) == 'canceled';
              break;
            }
          }
        }
      } catch (_) {}
    }
    if (isCanceled) return;

    String notificationBody = label;
    if (aiPrompt.isNotEmpty) {
      try {
        final response = await http.post(
          Uri.parse('https://roadmate-flutter.onrender.com/generate'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'prompt': aiPrompt}),
        ).timeout(const Duration(seconds: 20));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final content = (data['content'] as String?)?.trim() ?? '';
          if (content.isNotEmpty) notificationBody = content;
        }
      } catch (e) {
        debugPrint('[AiReminder] Failed to generate content: $e');
      }
    }

    try {
      final raw2 = prefs.getString('roadmate_pending_reminder_chat');
      final list = raw2 != null
          ? (jsonDecode(raw2) as List).cast<Map<String, dynamic>>()
          : <Map<String, dynamic>>[];
      list.removeWhere((e) => (e['id'] as num?)?.toInt() == reminderId);
      list.add({
        'id': reminderId,
        'title': label,
        'body': notificationBody,
        'fireTime': DateTime.now().toIso8601String(),
      });
      await prefs.setString('roadmate_pending_reminder_chat', jsonEncode(list));
    } catch (_) {}

    final notifications = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(const InitializationSettings(android: androidInit));

    await notifications.show(
      reminderId, label, notificationBody,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'roadmate_reminders', 'Reminders',
          channelDescription: 'RoadMate scheduled reminders',
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
      payload: jsonEncode({'reminder_id': reminderId, 'title': label, 'body': notificationBody}),
    );

    if (recurrence.isNotEmpty && scheduledIso.isNotEmpty) {
      try {
        final scheduledLocal = DateTime.parse(scheduledIso);
        final h = scheduledLocal.hour;
        final m = scheduledLocal.minute;
        final now = DateTime.now();
        DateTime nextOccurrence;
        if (recurrence == 'daily') {
          var next = DateTime(now.year, now.month, now.day, h, m);
          if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
          nextOccurrence = next;
        } else {
          final target = dayOfWeek > 0 ? dayOfWeek : scheduledLocal.weekday;
          var next = DateTime(now.year, now.month, now.day, h, m);
          while (next.weekday != target || !next.isAfter(now)) {
            next = next.add(const Duration(days: 1));
          }
          nextOccurrence = next;
        }
        final delay = nextOccurrence.difference(now);
        await Workmanager().registerOneOffTask(
          'ai_reminder_$reminderId', 'ai_reminder',
          initialDelay: delay.isNegative ? Duration.zero : delay,
          inputData: inputData,
          constraints: Constraints(networkType: NetworkType.connected),
          existingWorkPolicy: ExistingWorkPolicy.replace,
        );
      } catch (e) {
        debugPrint('[AiReminder] Failed to reschedule: $e');
      }
    }
  } catch (e) {
    debugPrint('[AiReminder] Task error: $e');
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(VoiceForegroundTaskHandler());
}

class VoiceForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') FlutterForegroundTask.sendDataToMain({'action': 'stopVoice'});
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp('/');

  @override
  void onNotificationDismissed() {}
}

Future<void> initBackgroundServices() async {
  if (Platform.isAndroid) {
    await Workmanager().initialize(callbackDispatcher);
  }
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'roadmate_voice_channel',
      channelName: 'RoadMate Voice Assistant',
      channelDescription: 'Keeps voice assistant active when screen is locked',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,
      allowWifiLock: false,
    ),
  );
}

void addForegroundCallback(void Function(Object) callback) {
  FlutterForegroundTask.addTaskDataCallback(callback);
}

Future<void> startForegroundService() async {
  if (await FlutterForegroundTask.isRunningService) return;
  await FlutterForegroundTask.startService(
    serviceId: 256,
    notificationTitle: 'RoadMate Voice Assistant',
    notificationText: 'Voice mode is active',
    notificationButtons: [const NotificationButton(id: 'stop', text: 'Stop')],
    callback: startCallback,
  );
}

Future<void> stopForegroundService() async {
  if (await FlutterForegroundTask.isRunningService) {
    await FlutterForegroundTask.stopService();
  }
}
