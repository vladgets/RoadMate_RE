import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'named_places_store.dart';
import '../config.dart';

/// A single driving or place-visit event.
/// type: 'start' | 'park' | 'visit'
class DrivingEvent {
  final String id;
  final String type;
  final String timestamp; // ISO8601 UTC — arrival time for visits
  final String? endTimestamp; // ISO8601 UTC — only set for 'visit' events
  final double? lat;
  final double? lon;
  final String? address;
  final String? label; // named place label for visits (e.g. "Home", "Work")

  DrivingEvent({
    required this.id,
    required this.type,
    required this.timestamp,
    this.endTimestamp,
    this.lat,
    this.lon,
    this.address,
    this.label,
  });

  int? get durationMinutes {
    if (endTimestamp == null) return null;
    try {
      final start = DateTime.parse(timestamp);
      final end = DateTime.parse(endTimestamp!);
      return end.difference(start).inMinutes;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'timestamp': timestamp,
        if (endTimestamp != null) 'endTimestamp': endTimestamp,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        if (address != null) 'address': address,
        if (label != null) 'label': label,
      };

  static DrivingEvent fromJson(Map<String, dynamic> json) => DrivingEvent(
        id: json['id'] as String,
        type: (json['type'] ?? 'start').toString(),
        timestamp: (json['timestamp'] ?? '').toString(),
        endTimestamp: json['endTimestamp'] as String?,
        lat: (json['lat'] as num?)?.toDouble(),
        lon: (json['lon'] as num?)?.toDouble(),
        address: json['address'] as String?,
        label: json['label'] as String?,
      );
}

/// Singleton store for driving events and place visits.
/// Persists to SharedPreferences as JSON (newest-first, max 500 events).
class DrivingLogStore {
  DrivingLogStore._();
  static final DrivingLogStore instance = DrivingLogStore._();

  static const String _storageKey = 'driving_events_v1';
  static const int _maxEvents = 500;
  static const _uuid = Uuid();

  List<DrivingEvent> _events = [];
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    await _load();
    _initialized = true;
    debugPrint('[DrivingLogStore] Initialized with ${_events.length} events');
  }

  List<DrivingEvent> get allEvents => List.unmodifiable(_events);

  /// Log a driving event. [type] is 'start' or 'park'.
  /// [eventTime] overrides the timestamp — pass the time of the first signal
  /// so the recorded time reflects when the event actually started rather than
  /// when the debounce window completed.
  Future<DrivingEvent> logEvent(String type, Map<String, dynamic> location,
      {DateTime? eventTime}) async {
    await init();

    double? lat;
    double? lon;
    String? address;

    if (location['ok'] == true) {
      lat = (location['lat'] as num?)?.toDouble();
      lon = (location['lon'] as num?)?.toDouble();
      final addr = location['address'];
      if (addr is Map) {
        final parts = <String>[];
        final street = addr['street'];
        final city = addr['city'];
        final state = addr['state'];
        if (street != null && (street as String).isNotEmpty) parts.add(street);
        if (city != null && (city as String).isNotEmpty) parts.add(city);
        if (state != null && (state as String).isNotEmpty) parts.add(state);
        if (parts.isNotEmpty) address = parts.join(', ');
      }
    }

    final eventTs = eventTime?.toUtc() ?? DateTime.now().toUtc();

    // Suppress duplicate: if a same-type event already exists within 5 min,
    // return the existing one rather than creating a second consecutive event.
    if (_hasDuplicateNearby(type, eventTs)) {
      final existing = _events.firstWhere(
        (e) {
          if (e.type != type) return false;
          try {
            return eventTs.difference(DateTime.parse(e.timestamp)).abs().inMilliseconds <= 300000;
          } catch (_) {
            return false;
          }
        },
      );
      debugPrint('[DrivingLogStore] Suppressed duplicate $type event (${existing.id})');
      return existing;
    }

    final event = DrivingEvent(
      id: _uuid.v4(),
      type: type,
      timestamp: eventTs.toIso8601String(),
      lat: lat,
      lon: lon,
      address: address,
    );

    _events.insert(0, event);
    _sortEvents();
    if (_events.length > _maxEvents) {
      _events = _events.sublist(0, _maxEvents);
    }

    await _save();
    debugPrint('[DrivingLogStore] Logged $type event: ${event.id}'
        '${address != null ? ' at $address' : ''}');
    return event;
  }

  /// Log a place visit with start/end times.
  /// [location] should be the map from getBestEffortBackgroundLocation().
  Future<DrivingEvent> logVisit(
      DateTime start, DateTime end, Map<String, dynamic> location) async {
    await init();

    double? lat;
    double? lon;
    String? address;

    if (location['ok'] == true) {
      lat = (location['lat'] as num?)?.toDouble();
      lon = (location['lon'] as num?)?.toDouble();
      final addr = location['address'];
      if (addr is Map) {
        final parts = <String>[];
        final street = addr['street'];
        final city = addr['city'];
        final state = addr['state'];
        if (street != null && (street as String).isNotEmpty) parts.add(street);
        if (city != null && (city as String).isNotEmpty) parts.add(city);
        if (state != null && (state as String).isNotEmpty) parts.add(state);
        if (parts.isNotEmpty) address = parts.join(', ');
      }
    }

    // Auto-label: check named places first, then try POI lookup if enabled
    String? label;
    if (lat != null && lon != null) {
      label = NamedPlacesStore.instance.findNearest(lat, lon)?.label;
      if (label == null && await NamedPlacesStore.instance.getPoiLookupEnabled()) {
        label = await _fetchPoiName(lat, lon);
      }
    }

    final event = DrivingEvent(
      id: _uuid.v4(),
      type: 'visit',
      timestamp: start.toUtc().toIso8601String(),
      endTimestamp: end.toUtc().toIso8601String(),
      lat: lat,
      lon: lon,
      address: address,
      label: label,
    );

    _events.insert(0, event);
    _sortEvents();
    if (_events.length > _maxEvents) {
      _events = _events.sublist(0, _maxEvents);
    }

    await _save();
    final dur = end.difference(start).inMinutes;
    debugPrint('[DrivingLogStore] Logged visit: ${dur}min'
        '${address != null ? ' at $address' : ''}'
        '${label != null ? ' ($label)' : ''}');
    return event;
  }

  /// Insert an already-constructed event (e.g. from native pending queue).
  Future<void> insertEvent(DrivingEvent event) async {
    await init();

    // Suppress duplicate start/park events within 5-minute window.
    if (event.type != 'visit') {
      try {
        final ts = DateTime.parse(event.timestamp);
        if (_hasDuplicateNearby(event.type, ts)) {
          debugPrint('[DrivingLogStore] Suppressed duplicate native ${event.type} event');
          return;
        }
      } catch (_) {}
    }

    _events.insert(0, event);
    _sortEvents();
    if (_events.length > _maxEvents) {
      _events = _events.sublist(0, _maxEvents);
    }
    await _save();
    debugPrint('[DrivingLogStore] Inserted native event: ${event.type} at ${event.timestamp}');
  }

  List<DrivingEvent> getRecentEvents(int limit) {
    if (_events.isEmpty) return [];
    final count = limit.clamp(1, _events.length);
    return List.unmodifiable(_events.sublist(0, count));
  }

  /// Delete a single event by ID.
  Future<void> deleteEvent(String id) async {
    await init();
    _events.removeWhere((e) => e.id == id);
    await _save();
    debugPrint('[DrivingLogStore] Deleted event $id');
  }

  /// Update the label of a visit event.
  Future<void> updateEventLabel(String id, String label) async {
    await init();
    final index = _events.indexWhere((e) => e.id == id);
    if (index == -1) return;
    final old = _events[index];
    _events[index] = DrivingEvent(
      id: old.id,
      type: old.type,
      timestamp: old.timestamp,
      endTimestamp: old.endTimestamp,
      lat: old.lat,
      lon: old.lon,
      address: old.address,
      label: label.trim().isEmpty ? null : label.trim(),
    );
    await _save();
    debugPrint('[DrivingLogStore] Updated label for $id: "$label"');
  }

  /// Tool handler for get_driving_log (trips only).
  Future<Map<String, dynamic>> toolGetDrivingLog(dynamic args) async {
    await init();
    int limit = 10;
    if (args is Map) {
      final raw = args['limit'];
      if (raw is int) limit = raw.clamp(1, 50);
      if (raw is num) limit = raw.toInt().clamp(1, 50);
    }
    final events = _events
        .where((e) => e.type == 'start' || e.type == 'park')
        .take(limit)
        .toList();
    return {
      'ok': true,
      'events': events.map((e) => e.toJson()).toList(),
      'count': events.length,
    };
  }

  /// Tool handler for get_place_visits (visits only).
  Future<Map<String, dynamic>> toolGetPlaceVisits(dynamic args) async {
    await init();
    int limit = 10;
    if (args is Map) {
      final raw = args['limit'];
      if (raw is int) limit = raw.clamp(1, 50);
      if (raw is num) limit = raw.toInt().clamp(1, 50);
    }
    final visits = _events.where((e) => e.type == 'visit').take(limit).toList();
    return {
      'ok': true,
      'visits': visits.map((e) => e.toJson()).toList(),
      'count': visits.length,
    };
  }

  // ---- Internal ----

  /// Sort events newest-first by effective timestamp.
  /// Visits use their end time so they appear at the position in the timeline
  /// where they concluded (right before the next trip), not where they started.
  /// Tiebreaker: start events before park, park before visit — so a trip-start
  /// at 3:30 appears above a visit that ended at 3:30.
  void _sortEvents() {
    const typePriority = {'start': 0, 'park': 1, 'visit': 2};
    _events.sort((a, b) {
      final aTs = a.type == 'visit' ? (a.endTimestamp ?? a.timestamp) : a.timestamp;
      final bTs = b.type == 'visit' ? (b.endTimestamp ?? b.timestamp) : b.timestamp;
      final cmp = bTs.compareTo(aTs); // descending by time
      if (cmp != 0) return cmp;
      // Tiebreaker: start > park > visit in the list (lowest priority = furthest down)
      return (typePriority[a.type] ?? 2).compareTo(typePriority[b.type] ?? 2);
    });
  }

  /// Returns true if an event of [type] already exists within [windowMs] ms
  /// of [ts]. Used to suppress duplicate start/park events.
  bool _hasDuplicateNearby(String type, DateTime ts, {int windowMs = 300000}) {
    return _events.any((e) {
      if (e.type != type) return false;
      try {
        final diff = ts.difference(DateTime.parse(e.timestamp)).abs().inMilliseconds;
        return diff <= windowMs;
      } catch (_) {
        return false;
      }
    });
  }

  Future<String?> _fetchPoiName(double lat, double lon) async {
    try {
      final url = Uri.parse('${Config.serverUrl}/nominatim/reverse');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'lat': lat, 'lon': lon}),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final poiName = data['poi_name'] as String?;
        if (poiName != null && poiName.isNotEmpty) {
          debugPrint('[DrivingLogStore] POI lookup: $poiName');
          return poiName;
        }
      }
    } catch (e) {
      debugPrint('[DrivingLogStore] POI lookup failed: $e');
    }
    return null;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.trim().isEmpty) {
        _events = [];
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        _events = [];
        return;
      }
      _events = decoded
          .whereType<Map>()
          .map((e) => DrivingEvent.fromJson(e.cast<String, dynamic>()))
          .toList();
      _sortEvents();
    } catch (e) {
      debugPrint('[DrivingLogStore] Failed to load: $e');
      _events = [];
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(_events.map((e) => e.toJson()).toList());
      await prefs.setString(_storageKey, encoded);
    } catch (e) {
      debugPrint('[DrivingLogStore] Failed to save: $e');
    }
  }

  /// One-time migration: update existing events with addresses and POI names.
  /// Returns a map with 'ok', 'updated' count, and optional 'error'.
  Future<Map<String, dynamic>> migrateExistingEvents() async {
    await init();
    int updated = 0;
    final errors = <String>[];

    for (int i = 0; i < _events.length; i++) {
      final event = _events[i];

      // Skip if no coordinates
      if (event.lat == null || event.lon == null) continue;

      // Skip if already has both address and label (for visits) or address (for trips)
      if (event.type == 'visit' && event.address != null && event.label != null) continue;
      if (event.type != 'visit' && event.address != null) continue;

      try {
        // Fetch address and POI from Nominatim
        final url = Uri.parse('${Config.serverUrl}/nominatim/reverse');
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'lat': event.lat, 'lon': event.lon}),
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final address = data['address'] as String?;
          final poiName = data['poi_name'] as String?;

          // Build address string from components (same logic as logEvent/logVisit)
          String? formattedAddress;
          if (address != null && address.isNotEmpty) {
            // Nominatim returns full formatted address, but we want short form
            // Parse it to extract street, city, state
            final parts = address.split(', ');
            if (parts.length >= 3) {
              formattedAddress = parts.take(3).join(', ');
            } else {
              formattedAddress = address;
            }
          }

          // Update event only if we got new data
          bool needsUpdate = false;
          String? newAddress = event.address;
          String? newLabel = event.label;

          if (formattedAddress != null && event.address == null) {
            newAddress = formattedAddress;
            needsUpdate = true;
          }

          // For visits, check named places first, then POI
          if (event.type == 'visit' && event.label == null) {
            final namedPlace = NamedPlacesStore.instance.findNearest(event.lat!, event.lon!);
            if (namedPlace != null) {
              newLabel = namedPlace.label;
              needsUpdate = true;
            } else if (await NamedPlacesStore.instance.getPoiLookupEnabled() &&
                       poiName != null && poiName.isNotEmpty) {
              newLabel = poiName;
              needsUpdate = true;
            }
          }

          if (needsUpdate) {
            _events[i] = DrivingEvent(
              id: event.id,
              type: event.type,
              timestamp: event.timestamp,
              endTimestamp: event.endTimestamp,
              lat: event.lat,
              lon: event.lon,
              address: newAddress,
              label: newLabel,
            );
            updated++;
          }
        }
      } catch (e) {
        debugPrint('[DrivingLogStore] Migration failed for event ${event.id}: $e');
        errors.add('${event.type} ${event.timestamp}: ${e.toString()}');
      }

      // Rate limiting: wait 1 second between requests to respect Nominatim usage policy
      if (i < _events.length - 1) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    if (updated > 0) {
      await _save();
    }

    debugPrint('[DrivingLogStore] Migration complete: $updated events updated');
    return {
      'ok': true,
      'updated': updated,
      'total': _events.length,
      'errors': errors,
    };
  }
}
