class CalendarStore {
  static Future<bool> hasPermissions() async => false;
  static Future<bool> requestPermissions() async => false;

  static Future<Map<String, dynamic>> toolGetCalendarData([dynamic args]) async =>
      {'ok': false, 'error': 'Calendar is not available on web.'};

  static Future<Map<String, dynamic>> toolCreateCalendarEvent(dynamic args) async =>
      {'ok': false, 'error': 'Calendar is not available on web.'};

  static Future<Map<String, dynamic>> toolUpdateCalendarEvent(dynamic args) async =>
      {'ok': false, 'error': 'Calendar is not available on web.'};

  static Future<Map<String, dynamic>> toolDeleteCalendarEvent(dynamic args) async =>
      {'ok': false, 'error': 'Calendar is not available on web.'};
}
