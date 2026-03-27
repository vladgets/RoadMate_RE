enum ReminderStatus { scheduled, fired, canceled }

class Reminder {
  final int id;
  final String text;
  final String scheduledAtLocalIso;
  final String createdAtLocalIso;
  ReminderStatus status;
  final String? recurrence;
  final int? dayOfWeek;
  final String? aiPrompt;

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

  DateTime get scheduledAtLocal => DateTime.parse(scheduledAtLocalIso);
  DateTime get createdAtLocal => DateTime.parse(createdAtLocalIso);
}

DateTime computeNextOccurrence(Reminder r) => r.scheduledAtLocal;

class RemindersService {
  RemindersService._();
  static final RemindersService instance = RemindersService._();
  static void Function(String title, String body)? onNotificationTap;

  Future<void> init() async {}

  Future<List<({String title, String body})>> drainFiredReminders() async => [];

  Future<Map<String, dynamic>> toolCreate(dynamic args) async =>
      {'ok': false, 'error': 'Reminders are not available on web.'};

  Future<Map<String, dynamic>> toolList() async =>
      {'ok': false, 'error': 'Reminders are not available on web.'};

  Future<Map<String, dynamic>> toolCancel(dynamic args) async =>
      {'ok': false, 'error': 'Reminders are not available on web.'};

  Future<List<Reminder>> listUpcoming() async => [];
  Future<void> cancelReminder(int id) async {}
  Future<void> updateAiPrompt(int id, String newAiPrompt) async {}
  Future<void> updateReminderText(int id, String newText) async {}
}
