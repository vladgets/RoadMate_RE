import 'package:device_calendar/device_calendar.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter/foundation.dart';

class CalendarStore {
  static final DeviceCalendarPlugin _deviceCalendarPlugin = DeviceCalendarPlugin();

  static bool _tzInitialized = false;

  static void _ensureTzInitialized() {
    if (_tzInitialized) return;
    // Initializes the time zone database. Note: without explicitly setting the
    // local location (via a native timezone plugin), tz.local defaults to UTC.
    tzdata.initializeTimeZones();
    _tzInitialized = true;
  }

  static tz.TZDateTime _toTz(DateTime dt) {
    _ensureTzInitialized();
    // Use epoch milliseconds with UTC zone so the absolute time is always
    // correct regardless of tz.local defaulting to UTC on some devices.
    return tz.TZDateTime.fromMillisecondsSinceEpoch(tz.UTC, dt.millisecondsSinceEpoch);
  }

  /// Convert a TZDateTime (or any DateTime) to a local ISO 8601 string with no
  /// timezone offset, so the AI always sees times in the user's local timezone.
  static String _toLocalIso(DateTime dt) {
    final local = DateTime.fromMillisecondsSinceEpoch(dt.millisecondsSinceEpoch);
    return local.toIso8601String();
  }

  /// Safely convert a value to String, handling null
  static String _safeString(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    return value.toString();
  }

  /// Check if calendar permissions are granted
  static Future<bool> hasPermissions() async {
    final permissions = await _deviceCalendarPlugin.hasPermissions();
    return permissions.data ?? false;
  }

  /// Request calendar permissions
  static Future<bool> requestPermissions() async {
    final result = await _deviceCalendarPlugin.requestPermissions();
    return result.data ?? false;
  }

  /// Tool-compatible wrapper: get calendar events
  /// Accepts optional start_date / end_date (ISO 8601). Defaults to ±7 days.
  static Future<Map<String, dynamic>> toolGetCalendarData([dynamic args]) async {
    try {
      // Check permissions
      bool hasPermission = await hasPermissions();
      if (!hasPermission) {
        hasPermission = await requestPermissions();
      }

      if (!hasPermission) {
        return {
          'ok': false,
          'error': 'Calendar permission denied',
        };
      }

      // Get list of calendars
      final calendarsResult = await _deviceCalendarPlugin.retrieveCalendars();
      if (!calendarsResult.isSuccess) {
        final errorMsg = calendarsResult.errors.isNotEmpty 
            ? calendarsResult.errors.join(", ")
            : "Unknown error";
        return {
          'ok': false,
          'error': 'Failed to retrieve calendars: $errorMsg',
        };
      }

      if (calendarsResult.data == null) {
        return {
          'ok': false,
          'error': 'No calendars data returned',
        };
      }

      final calendars = calendarsResult.data!;
      if (calendars.isEmpty) {
        return {
          'ok': true,
          'events': [],
          'count': 0,
          'message': 'No calendars found on device',
        };
      }

      // Log all found calendars
      debugPrint('>>> Found ${calendars.length} calendars:');
      for (final cal in calendars) {
        debugPrint('  - ${cal.name ?? "Unknown"} (id: ${cal.id ?? "null"}, readOnly: ${cal.isReadOnly}, color: ${cal.color})');
      }

      // Calculate date range from args or default to ±7 days
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      DateTime startDate;
      DateTime endDate;

      final startStr = args is Map ? (args['start_date'] as String?) : null;
      final endStr = args is Map ? (args['end_date'] as String?) : null;

      if (startStr != null && startStr.isNotEmpty) {
        try {
          final parsed = DateTime.parse(startStr);
          startDate = DateTime(parsed.year, parsed.month, parsed.day);
        } catch (_) {
          startDate = today.subtract(const Duration(days: 7));
        }
      } else {
        startDate = today.subtract(const Duration(days: 7));
      }

      if (endStr != null && endStr.isNotEmpty) {
        try {
          final parsed = DateTime.parse(endStr);
          endDate = DateTime(parsed.year, parsed.month, parsed.day, 23, 59, 59);
        } catch (_) {
          endDate = today.add(const Duration(days: 7));
        }
      } else {
        endDate = today.add(const Duration(days: 7));
      }

      // Retrieve events from all calendars
      final List<Map<String, dynamic>> allEvents = [];
      final Map<String, int> calendarEventCounts = {};

      for (final calendar in calendars) {
        // Process all calendars, including read-only ones (they can still have events)
        if (calendar.id == null || calendar.id!.isEmpty) {
          debugPrint('>>> Skipping calendar ${calendar.name}: no valid ID');
          continue; // Skip calendars without valid ID
        }

        final calendarName = calendar.name ?? 'Unknown';
        try {
          debugPrint('>>> Retrieving events from calendar: $calendarName (id: ${calendar.id})');
          
          final eventsResult = await _deviceCalendarPlugin.retrieveEvents(
            calendar.id!,
            RetrieveEventsParams(
              startDate: startDate,
              endDate: endDate,
            ),
          );

          if (!eventsResult.isSuccess) {
            // Log but continue - some calendars may not be accessible
            debugPrint('>>> Failed to retrieve events from calendar $calendarName: ${eventsResult.errors.join(", ")}');
            calendarEventCounts[calendarName] = 0;
            continue;
          }

          if (eventsResult.data == null) {
            debugPrint('>>> Calendar $calendarName: data is null');
            calendarEventCounts[calendarName] = 0;
            continue; // No events or data is null
          }

          // Get events list - this may throw if there are parsing errors
          List<Event>? events;
          try {
            events = eventsResult.data;
            if (events == null) {
              debugPrint('>>> Calendar $calendarName: data is null');
              calendarEventCounts[calendarName] = 0;
              continue;
            }
            debugPrint('>>> Calendar $calendarName: found ${events.length} events');
          } catch (e) {
            debugPrint('>>> Calendar $calendarName: error accessing events list: $e');
            calendarEventCounts[calendarName] = 0;
            continue;
          }
          
          if (events.isEmpty) {
            calendarEventCounts[calendarName] = 0;
            continue; // No events in this calendar
          }

          int processedCount = 0;
          int failedCount = 0;
          // Process events by index to handle parsing errors in device_calendar
          // Some events may fail to parse when accessed, so we try each one individually
          for (int i = 0; i < events.length; i++) {
            try {
              // Access event by index - this may throw if event parsing failed during lazy evaluation
              final event = events[i];
              
              // Safely extract event data, handling all possible null values
              final eventMap = <String, dynamic>{
                'event_id': event.eventId ?? '',
                'title': _safeString(event.title),
                'start': event.start != null ? _toLocalIso(event.start!) : '',
                'end': event.end != null ? _toLocalIso(event.end!) : '',
                'description': _safeString(event.description),
                'location': _safeString(event.location),
                'calendar': calendarName,
              };
              allEvents.add(eventMap);
              processedCount++;
            } catch (e, stackTrace) {
              // Log error for individual event but continue processing
              failedCount++;
              debugPrint('>>> Error processing event #$i from calendar $calendarName: $e');
              // Only print stack trace for first few errors to reduce log spam
              if (failedCount <= 3) {
                debugPrint('Stack trace: $stackTrace');
              }
            }
          }
          calendarEventCounts[calendarName] = processedCount;
          if (failedCount > 0) {
            debugPrint('>>> Calendar $calendarName: processed $processedCount/${events.length} events successfully ($failedCount failed)');
          } else {
            debugPrint('>>> Calendar $calendarName: processed $processedCount events successfully');
          }
        } catch (e, stackTrace) {
          // Log error but continue with other calendars
          debugPrint('>>> Error retrieving events from calendar $calendarName: $e');
          debugPrint('Stack trace: $stackTrace');
          calendarEventCounts[calendarName] = 0;
        }
      }

      // Log summary
      debugPrint('>>> Calendar events summary:');
      for (final entry in calendarEventCounts.entries) {
        debugPrint('  - ${entry.key}: ${entry.value} events');
      }
      debugPrint('>>> Total events collected: ${allEvents.length}');

      // Sort events by start date (only if we have events)
      if (allEvents.isNotEmpty) {
        allEvents.sort((a, b) {
          final aStart = a['start'] as String;
          final bStart = b['start'] as String;
          if (aStart.isEmpty && bStart.isEmpty) return 0;
          if (aStart.isEmpty) return 1;
          if (bStart.isEmpty) return -1;
          return aStart.compareTo(bStart);
        });
      }

      return {
        'ok': true,
        'today': '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}',
        'events': allEvents,
        'count': allEvents.length,
        'date_range': {
          'start': startDate.toIso8601String(),
          'end': endDate.toIso8601String(),
        },
        'writable_calendars': calendars
            .where((c) => c.id != null && c.id!.isNotEmpty && c.isReadOnly != true)
            .map((c) => {
                  'id': c.id,
                  'name': c.name ?? 'Unknown',
                  'account': c.accountName ?? '',
                  'is_default': c.isDefault ?? false,
                })
            .toList(),
      };
    } catch (e) {
      return {
        'ok': false,
        'error': e.toString(),
      };
    }
  }

  /// Get default calendar for creating events.
  /// Priority: device default → Google account → first writable.
  static Future<Calendar?> _getDefaultCalendar() async {
    final calendarsResult = await _deviceCalendarPlugin.retrieveCalendars();
    if (!calendarsResult.isSuccess || calendarsResult.data == null) {
      return null;
    }

    final writable = calendarsResult.data!
        .where((c) => c.id != null && c.id!.isNotEmpty && c.isReadOnly != true)
        .toList();

    if (writable.isEmpty) return null;

    // 1. Device-default writable calendar
    final deviceDefault = writable.where((c) => c.isDefault == true).firstOrNull;
    if (deviceDefault != null) return deviceDefault;

    // 2. Any Google account calendar (accountType = "com.google")
    final google = writable
        .where((c) => (c.accountType ?? '').toLowerCase().contains('google'))
        .firstOrNull;
    if (google != null) return google;

    // 3. Fallback: first writable
    return writable.first;
  }

  /// Find event by title and approximate date
  /// Returns the event and the calendar ID where it was found
  static Future<Map<String, dynamic>?> _findEventByTitleAndDate(String title, DateTime date) async {
    debugPrint('>>> Searching for event: title="$title", date=${date.toIso8601String()}');
    
    final calendarsResult = await _deviceCalendarPlugin.retrieveCalendars();
    if (!calendarsResult.isSuccess || calendarsResult.data == null) {
      debugPrint('>>> Failed to retrieve calendars for search');
      return null;
    }

    final calendars = calendarsResult.data!;
    final searchStart = date.subtract(const Duration(days: 1));
    final searchEnd = date.add(const Duration(days: 1));
    
    debugPrint('>>> Search range: ${searchStart.toIso8601String()} to ${searchEnd.toIso8601String()}');

    final searchTitleLower = title.toLowerCase();
    int totalEventsChecked = 0;
    
    // Collect all matching events and choose the one closest to the target date
    List<Map<String, dynamic>> candidateEvents = [];

    for (final calendar in calendars) {
      if (calendar.id == null || calendar.id!.isEmpty) continue;

      try {
        final eventsResult = await _deviceCalendarPlugin.retrieveEvents(
          calendar.id!,
          RetrieveEventsParams(
            startDate: searchStart,
            endDate: searchEnd,
          ),
        );

        if (eventsResult.isSuccess && eventsResult.data != null) {
          final events = eventsResult.data!;
          debugPrint('>>> Checking ${events.length} events in calendar ${calendar.name}');
          
          for (final event in events) {
            try {
              totalEventsChecked++;
              final eventTitle = _safeString(event.title).trim();
              
              // Skip events with empty title
              if (eventTitle.isEmpty) {
                continue;
              }
              
              final eventTitleLower = eventTitle.toLowerCase();
              
              // Check if title matches - prefer exact match, then partial match
              // But never match if search title is empty or event title is empty (already checked above)
              bool titleMatches = false;
              int matchPriority = 0; // 0 = no match, 1 = partial, 2 = exact
              if (eventTitleLower == searchTitleLower) {
                // Exact match - highest priority
                titleMatches = true;
                matchPriority = 2;
              } else if (eventTitleLower.contains(searchTitleLower) && searchTitleLower.length >= 3) {
                // Partial match - event title contains search title (only if search is at least 3 chars)
                titleMatches = true;
                matchPriority = 1;
              } else if (searchTitleLower.contains(eventTitleLower) && eventTitleLower.length >= 3) {
                // Reverse partial match - search title contains event title (only if event title is at least 3 chars)
                titleMatches = true;
                matchPriority = 1;
              }
              
              if (titleMatches && event.start != null) {
                final eventDate = event.start!;
                final diff = (eventDate.difference(date)).abs();
                
                // Only consider events within 1 day
                if (diff.inDays <= 1) {
                  debugPrint('>>> Found matching title "${event.title}" at ${eventDate.toIso8601String()}, diff: ${diff.inHours} hours, priority: $matchPriority');
                  
                  candidateEvents.add({
                    'event': event,
                    'calendarId': calendar.id!,
                    'calendarName': calendar.name ?? 'Unknown',
                    'dateDiff': diff,
                    'dateDiffHours': diff.inHours,
                    'matchPriority': matchPriority,
                  });
                }
              }
            } catch (e) {
              // Skip events that fail to parse
              debugPrint('>>> Error parsing event: $e');
              continue;
            }
          }
        }
      } catch (e) {
        // Continue with next calendar
        debugPrint('>>> Error searching calendar ${calendar.name}: $e');
        continue;
      }
    }
    
    // If we found candidates, choose the best one
    if (candidateEvents.isNotEmpty) {
      // Sort candidates: first by match priority (exact > partial), then by time difference
      candidateEvents.sort((a, b) {
        final priorityDiff = (b['matchPriority'] as int) - (a['matchPriority'] as int);
        if (priorityDiff != 0) return priorityDiff;
        final timeDiff = (a['dateDiffHours'] as int) - (b['dateDiffHours'] as int);
        return timeDiff;
      });
      
      final bestMatch = candidateEvents.first;
      final event = bestMatch['event'] as Event;
      debugPrint('>>> Selected best match: ${event.title} (id: ${event.eventId}) in calendar ${bestMatch['calendarName']}, time diff: ${bestMatch['dateDiffHours']} hours');
      
      return {
        'event': event,
        'calendarId': bestMatch['calendarId'] as String,
        'calendarName': bestMatch['calendarName'] as String,
      };
    }
    
    debugPrint('>>> Event not found. Checked $totalEventsChecked events across ${calendars.length} calendars, found ${candidateEvents.length} candidates');
    return null;
  }

  /// Tool-compatible wrapper: create calendar event
  static Future<Map<String, dynamic>> toolCreateCalendarEvent(dynamic args) async {
    try {
      // Check permissions
      bool hasPermission = await hasPermissions();
      if (!hasPermission) {
        hasPermission = await requestPermissions();
      }

      if (!hasPermission) {
        return {
          'ok': false,
          'error': 'Calendar permission denied',
        };
      }

      // Parse arguments
      final title = args is Map ? (args['title'] as String?) : null;
      final startStr = args is Map ? (args['start'] as String?) : null;
      final endStr = args is Map ? (args['end'] as String?) : null;
      final description = args is Map ? (args['description'] as String?) : null;
      final location = args is Map ? (args['location'] as String?) : null;
      final calendarId = args is Map ? (args['calendar_id'] as String?) : null;

      if (title == null || title.isEmpty) {
        return {
          'ok': false,
          'error': 'Event title is required',
        };
      }

      if (startStr == null || startStr.isEmpty) {
        return {
          'ok': false,
          'error': 'Event start time is required',
        };
      }

      // Parse start date
      DateTime start;
      try {
        start = DateTime.parse(startStr);
      } catch (e) {
        return {
          'ok': false,
          'error': 'Invalid start date format: $e',
        };
      }

      // Parse end date or use start + 1 hour
      DateTime end;
      if (endStr != null && endStr.isNotEmpty) {
        try {
          end = DateTime.parse(endStr);
        } catch (e) {
          return {
            'ok': false,
            'error': 'Invalid end date format: $e',
          };
        }
      } else {
        end = start.add(const Duration(hours: 1));
      }

      // Validate dates
      if (end.isBefore(start)) {
        return {
          'ok': false,
          'error': 'End time must be after start time',
        };
      }

      // Get calendar — match by ID first, then by name/account, then default
      Calendar? calendar;
      if (calendarId != null && calendarId.isNotEmpty) {
        final calendarsResult = await _deviceCalendarPlugin.retrieveCalendars();
        if (calendarsResult.isSuccess && calendarsResult.data != null) {
          final writable = calendarsResult.data!
              .where((c) => c.id != null && c.id!.isNotEmpty && c.isReadOnly != true)
              .toList();
          // 1. Exact ID match
          calendar = writable.where((c) => c.id == calendarId).firstOrNull;
          // 2. Name or account email match
          calendar ??= writable.where((c) =>
              (c.name ?? '').toLowerCase() == calendarId.toLowerCase() ||
              (c.accountName ?? '').toLowerCase() == calendarId.toLowerCase()).firstOrNull;
          // 3. Fall back to default rather than hard-failing
          calendar ??= writable.where((c) => c.isDefault == true).firstOrNull ?? writable.firstOrNull;
        }
      }
      calendar ??= await _getDefaultCalendar();
      if (calendar == null) {
        return {
          'ok': false,
          'error': 'No writable calendar found',
        };
      }
      // Create event
      final event = Event(calendar.id!);
      event.title = title;
      event.start = _toTz(start);
      event.end = _toTz(end);
      if (description != null && description.isNotEmpty) {
        event.description = description;
      }
      if (location != null && location.isNotEmpty) {
        event.location = location;
      }

      final createResult = await _deviceCalendarPlugin.createOrUpdateEvent(event);
      
      if (createResult == null || !createResult.isSuccess) {
        final errorMsg = (createResult != null && createResult.errors.isNotEmpty)
            ? createResult.errors.join(", ")
            : "Unknown error";
        return {
          'ok': false,
          'error': 'Failed to create event: $errorMsg',
        };
      }

      return {
        'ok': true,
        'event_id': createResult.data,
        'title': title,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'calendar': calendar.name ?? 'Unknown',
      };
    } catch (e) {
      return {
        'ok': false,
        'error': e.toString(),
      };
    }
  }

  /// Tool-compatible wrapper: update calendar event
  static Future<Map<String, dynamic>> toolUpdateCalendarEvent(dynamic args) async {
    try {
      // Check permissions
      bool hasPermission = await hasPermissions();
      if (!hasPermission) {
        return {
          'ok': false,
          'error': 'Calendar permission denied',
        };
      }

      // Parse arguments
      final eventId = args is Map ? (args['event_id'] as String?) : null;
      // 'title' is used only to find the event; 'new_title' renames it
      final searchTitle = args is Map ? (args['title'] as String?) : null;
      final newTitle = args is Map ? (args['new_title'] as String?) : null;
      final startDateStr = args is Map ? (args['start_date'] as String?) : null;
      final startStr = args is Map ? (args['start'] as String?) : null;
      final endStr = args is Map ? (args['end'] as String?) : null;
      final description = args is Map ? (args['description'] as String?) : null;
      final location = args is Map ? (args['location'] as String?) : null;

      Event? event;
      String? calendarId;

      if (eventId != null && eventId.isNotEmpty) {
        // Find event by ID
        final calendarsResult = await _deviceCalendarPlugin.retrieveCalendars();
        if (!calendarsResult.isSuccess || calendarsResult.data == null) {
          return {
            'ok': false,
            'error': 'Failed to retrieve calendars',
          };
        }

        bool found = false;
        for (final calendar in calendarsResult.data!) {
          if (calendar.id == null || calendar.id!.isEmpty) continue;

          try {
            final eventsResult = await _deviceCalendarPlugin.retrieveEvents(
              calendar.id!,
              RetrieveEventsParams(
                startDate: DateTime.now().subtract(const Duration(days: 365)),
                endDate: DateTime.now().add(const Duration(days: 365)),
              ),
            );

            if (eventsResult.isSuccess && eventsResult.data != null) {
              for (final e in eventsResult.data!) {
                try {
                  if (e.eventId == eventId) {
                    event = e;
                    calendarId = calendar.id;
                    found = true;
                    break;
                  }
                } catch (_) {
                  continue;
                }
              }
            }
          } catch (_) {
            continue;
          }
          if (found) break;
        }

        if (!found) {
          return {
            'ok': false,
            'error': 'Event not found',
          };
        }
      } else if (searchTitle != null && startDateStr != null) {
        // Search by title and date
        DateTime searchDate;
        try {
          searchDate = DateTime.parse(startDateStr);
        } catch (e) {
          return {
            'ok': false,
            'error': 'Invalid start_date format: $e',
          };
        }

        final searchResult = await _findEventByTitleAndDate(searchTitle, searchDate);
        if (searchResult == null) {
          return {
            'ok': false,
            'error': 'Event not found. Searched for title "$searchTitle" around date ${searchDate.toIso8601String()}. Please check the event title and date, or use event_id if you know it.',
          };
        }
        
        event = searchResult['event'] as Event;
        calendarId = searchResult['calendarId'] as String;
        
        debugPrint('>>> Found event in calendar: ${searchResult['calendarName']}');
      } else {
        return {
          'ok': false,
          'error': 'Either event_id or (title and start_date) must be provided',
        };
      }

      if (event == null || calendarId == null) {
        return {
          'ok': false,
          'error': 'Event not found or calendar not accessible. Please verify the event exists and try again.',
        };
      }

      // Save original start and end for duration calculation
      final originalStart = event.start;
      final originalEnd = event.end;
      Duration? eventDuration;
      if (originalStart != null && originalEnd != null && originalEnd.isAfter(originalStart)) {
        eventDuration = originalEnd.difference(originalStart);
      }
      
      debugPrint('>>> Updating event: ${event.title} (id: ${event.eventId})');
      debugPrint('>>> Original: start=${originalStart?.toIso8601String()}, end=${originalEnd?.toIso8601String()}, duration=$eventDuration');

      // Update event fields
      if (newTitle != null && newTitle.isNotEmpty) {
        event.title = newTitle;
      }
      
      DateTime? newStart;
      if (startStr != null && startStr.isNotEmpty) {
        try {
          newStart = DateTime.parse(startStr);
          event.start = _toTz(newStart);
        } catch (e) {
          return {
            'ok': false,
            'error': 'Invalid start date format: $e',
          };
        }
      }
      
      if (endStr != null && endStr.isNotEmpty) {
        try {
          event.end = _toTz(DateTime.parse(endStr));
        } catch (e) {
          return {
            'ok': false,
            'error': 'Invalid end date format: $e',
          };
        }
      } else if (newStart != null && eventDuration != null) {
        // If start was updated but end wasn't, preserve the event duration
        event.end = _toTz(newStart.add(eventDuration));
      }
      
      if (description != null) {
        event.description = description;
      }
      if (location != null) {
        event.location = location;
      }

      // Validate dates
      if (event.start != null && event.end != null && event.end!.isBefore(event.start!)) {
        // If validation fails, try to fix by preserving duration or adding 1 hour
        if (event.start != null) {
          if (eventDuration != null) {
            event.end = event.start!.add(eventDuration);
            debugPrint('>>> Fixed end time by preserving duration: ${event.end?.toIso8601String()}');
          } else {
            event.end = event.start!.add(const Duration(hours: 1));
            debugPrint('>>> Fixed end time by adding 1 hour: ${event.end?.toIso8601String()}');
          }
        } else {
          return {
            'ok': false,
            'error': 'Invalid event times: end time must be after start time. Please provide valid start and end times.',
          };
        }
      }
      
      debugPrint('>>> Updated: start=${event.start?.toIso8601String()}, end=${event.end?.toIso8601String()}');

      // Ensure event has valid ID and calendar ID for update
      if (event.eventId == null || event.eventId!.isEmpty) {
        return {
          'ok': false,
          'error': 'Cannot update event: event ID is missing',
        };
      }
      
      event.calendarId = calendarId;
      
      debugPrint('>>> Updating event with ID: ${event.eventId}, calendar: $calendarId');
      
      final updateResult = await _deviceCalendarPlugin.createOrUpdateEvent(event);

      if (updateResult == null || !updateResult.isSuccess) {
        final errorMsg = (updateResult != null && updateResult.errors.isNotEmpty)
            ? updateResult.errors.join(", ")
            : "Unknown error";
        return {
          'ok': false,
          'error': 'Failed to update event: $errorMsg',
        };
      }

      // Build list of updated fields
      final updatedFields = <String>[];
      if (newTitle != null && newTitle.isNotEmpty) updatedFields.add('title');
      if (startStr != null && startStr.isNotEmpty) updatedFields.add('start');
      if (endStr != null && endStr.isNotEmpty) updatedFields.add('end');
      if (description != null) updatedFields.add('description');
      if (location != null) updatedFields.add('location');
      
      debugPrint('>>> Event updated successfully. Fields changed: ${updatedFields.join(", ")}');

      return {
        'ok': true,
        'event_id': event.eventId,
        'title': event.title ?? '',
        'start': event.start != null ? _toLocalIso(event.start!) : '',
        'end': event.end != null ? _toLocalIso(event.end!) : '',
        'updated_fields': updatedFields,
        'message': 'Event updated successfully',
      };
    } catch (e) {
      return {
        'ok': false,
        'error': e.toString(),
      };
    }
  }

  /// Tool-compatible wrapper: delete calendar event
  static Future<Map<String, dynamic>> toolDeleteCalendarEvent(dynamic args) async {
    try {
      // Check permissions
      bool hasPermission = await hasPermissions();
      if (!hasPermission) {
        return {
          'ok': false,
          'error': 'Calendar permission denied',
        };
      }

      // Parse arguments
      final eventId = args is Map ? (args['event_id'] as String?) : null;
      final searchTitle = args is Map ? (args['title'] as String?) : null;
      final startDateStr = args is Map ? (args['start_date'] as String?) : null;

      Event? event;
      String? calendarId;

      if (eventId != null && eventId.isNotEmpty) {
        // Find event by ID
        final calendarsResult = await _deviceCalendarPlugin.retrieveCalendars();
        if (!calendarsResult.isSuccess || calendarsResult.data == null) {
          return {
            'ok': false,
            'error': 'Failed to retrieve calendars',
          };
        }

        bool found = false;
        for (final calendar in calendarsResult.data!) {
          if (calendar.id == null || calendar.id!.isEmpty) continue;

          try {
            final eventsResult = await _deviceCalendarPlugin.retrieveEvents(
              calendar.id!,
              RetrieveEventsParams(
                startDate: DateTime.now().subtract(const Duration(days: 365)),
                endDate: DateTime.now().add(const Duration(days: 365)),
              ),
            );

            if (eventsResult.isSuccess && eventsResult.data != null) {
              for (final e in eventsResult.data!) {
                try {
                  if (e.eventId == eventId) {
                    event = e;
                    calendarId = calendar.id;
                    found = true;
                    break;
                  }
                } catch (_) {
                  continue;
                }
              }
            }
          } catch (_) {
            continue;
          }
          if (found) break;
        }

        if (!found) {
          return {
            'ok': false,
            'error': 'Event not found',
          };
        }
      } else if (searchTitle != null && startDateStr != null) {
        // Search by title and date
        DateTime searchDate;
        try {
          searchDate = DateTime.parse(startDateStr);
        } catch (e) {
          return {
            'ok': false,
            'error': 'Invalid start_date format: $e',
          };
        }

        final searchResult = await _findEventByTitleAndDate(searchTitle, searchDate);
        if (searchResult == null) {
          return {
            'ok': false,
            'error': 'Event not found. Searched for title "$searchTitle" around date ${searchDate.toIso8601String()}. Please check the event title and date, or use event_id if you know it.',
          };
        }
        
        event = searchResult['event'] as Event;
        calendarId = searchResult['calendarId'] as String;
        
        debugPrint('>>> Found event to delete in calendar: ${searchResult['calendarName']}');
      } else {
        return {
          'ok': false,
          'error': 'Either event_id or (title and start_date) must be provided',
        };
      }

      if (event == null || calendarId == null || event.eventId == null) {
        return {
          'ok': false,
          'error': 'Event not found or cannot be deleted',
        };
      }

      // Delete event
      final deleteResult = await _deviceCalendarPlugin.deleteEvent(calendarId, event.eventId!);

      if (!deleteResult.isSuccess) {
        final errorMsg = deleteResult.errors.isNotEmpty
            ? deleteResult.errors.join(", ")
            : "Unknown error";
        return {
          'ok': false,
          'error': 'Failed to delete event: $errorMsg',
        };
      }

      return {
        'ok': true,
        'event_id': event.eventId,
        'title': event.title ?? '',
        'message': 'Event deleted successfully',
      };
    } catch (e) {
      return {
        'ok': false,
        'error': e.toString(),
      };
    }
  }
}


