import 'dart:convert';
import 'package:http/http.dart' as http;

/// HTTP client for Google Calendar via the RoadMate server proxy.
/// Mirrors the pattern used by GmailClient.
class GCalendarClient {
  final String baseUrl;
  final String? clientId;

  const GCalendarClient({required this.baseUrl, this.clientId});

  Map<String, String> _headers() {
    final h = <String, String>{'Content-Type': 'application/json'};
    if (clientId != null && clientId!.isNotEmpty) {
      h['X-Client-Id'] = clientId!;
    }
    return h;
  }

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  // ── Authorization status ─────────────────────────────────────────────────

  /// Returns true if the server holds a valid Google token for this client.
  /// Uses the shared /oauth/google/status endpoint (covers Gmail + Calendar).
  Future<bool> isAuthorized() async {
    try {
      final r = await http.get(_u('/oauth/google/status'), headers: _headers());
      if (r.statusCode != 200) return false;
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      return body['authorized'] == true;
    } catch (_) {
      return false;
    }
  }

  // ── Events ───────────────────────────────────────────────────────────────

  /// Fetch events. Matches the shape returned by CalendarStore.toolGetCalendarData.
  Future<Map<String, dynamic>> getEvents({
    String? startDate,
    String? endDate,
  }) async {
    final params = <String, String>{};
    if (startDate != null) params['start_date'] = startDate;
    if (endDate != null) params['end_date'] = endDate;

    final uri = _u('/calendar/events').replace(queryParameters: params);
    try {
      final r = await http.get(uri, headers: _headers());
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        return {'ok': false, 'error': body['error'] ?? 'HTTP ${r.statusCode}'};
      }
      return body;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ── Create ───────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> createEvent({
    required String title,
    required String start,
    String? end,
    String? description,
    String? location,
    String? calendarId,
  }) async {
    final payload = <String, dynamic>{'title': title, 'start': start};
    if (end != null) payload['end'] = end;
    if (description != null) payload['description'] = description;
    if (location != null) payload['location'] = location;
    if (calendarId != null) payload['calendar_id'] = calendarId;

    try {
      final r = await http.post(
        _u('/calendar/create'),
        headers: _headers(),
        body: jsonEncode(payload),
      );
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        return {'ok': false, 'error': body['error'] ?? 'HTTP ${r.statusCode}'};
      }
      return body;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ── Update ───────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> updateEvent({
    required String eventId,
    String? calendarId,
    String? title,
    String? start,
    String? end,
    String? description,
    String? location,
  }) async {
    final payload = <String, dynamic>{'event_id': eventId};
    if (calendarId != null) payload['calendar_id'] = calendarId;
    if (title != null) payload['title'] = title;
    if (start != null) payload['start'] = start;
    if (end != null) payload['end'] = end;
    if (description != null) payload['description'] = description;
    if (location != null) payload['location'] = location;

    try {
      final r = await http.patch(
        _u('/calendar/update'),
        headers: _headers(),
        body: jsonEncode(payload),
      );
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        return {'ok': false, 'error': body['error'] ?? 'HTTP ${r.statusCode}'};
      }
      return body;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ── Delete ───────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> deleteEvent({
    required String eventId,
    String? calendarId,
  }) async {
    final payload = <String, dynamic>{'event_id': eventId};
    if (calendarId != null) payload['calendar_id'] = calendarId;

    try {
      final r = await http.delete(
        _u('/calendar/delete'),
        headers: _headers(),
        body: jsonEncode(payload),
      );
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        return {'ok': false, 'error': body['error'] ?? 'HTTP ${r.statusCode}'};
      }
      return body;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ── Tool-compatible wrappers (same signature as CalendarStore) ────────────

  /// Tool wrapper: maps OpenAI args to getEvents().
  Future<Map<String, dynamic>> toolGetCalendarData([dynamic args]) async {
    final startDate = args is Map ? (args['start_date'] as String?) : null;
    final endDate = args is Map ? (args['end_date'] as String?) : null;
    return getEvents(startDate: startDate, endDate: endDate);
  }

  /// Tool wrapper: maps OpenAI args to createEvent().
  Future<Map<String, dynamic>> toolCreateCalendarEvent(dynamic args) async {
    if (args is! Map) return {'ok': false, 'error': 'Invalid arguments'};
    final title = args['title'] as String?;
    final start = args['start'] as String?;
    if (title == null || title.isEmpty) {
      return {'ok': false, 'error': 'title is required'};
    }
    if (start == null || start.isEmpty) {
      return {'ok': false, 'error': 'start is required'};
    }
    return createEvent(
      title: title,
      start: start,
      end: args['end'] as String?,
      description: args['description'] as String?,
      location: args['location'] as String?,
      calendarId: args['calendar_id'] as String?,
    );
  }

  /// Tool wrapper: maps OpenAI args to updateEvent().
  Future<Map<String, dynamic>> toolUpdateCalendarEvent(dynamic args) async {
    if (args is! Map) return {'ok': false, 'error': 'Invalid arguments'};
    final eventId = args['event_id'] as String?;
    if (eventId == null || eventId.isEmpty) {
      return {'ok': false, 'error': 'event_id is required'};
    }
    return updateEvent(
      eventId: eventId,
      calendarId: args['calendar_id'] as String?,
      title: args['new_title'] as String? ?? args['title'] as String?,
      start: args['start'] as String?,
      end: args['end'] as String?,
      description: args['description'] as String?,
      location: args['location'] as String?,
    );
  }

  /// Tool wrapper: maps OpenAI args to deleteEvent().
  Future<Map<String, dynamic>> toolDeleteCalendarEvent(dynamic args) async {
    if (args is! Map) return {'ok': false, 'error': 'Invalid arguments'};
    final eventId = args['event_id'] as String?;
    if (eventId == null || eventId.isEmpty) {
      return {'ok': false, 'error': 'event_id is required'};
    }
    return deleteEvent(
      eventId: eventId,
      calendarId: args['calendar_id'] as String?,
    );
  }
}
