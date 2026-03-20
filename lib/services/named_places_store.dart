import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NamedPlace {
  final String label;
  final double lat;
  final double lon;
  final double radiusM;

  const NamedPlace({
    required this.label,
    required this.lat,
    required this.lon,
    this.radiusM = 200.0,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'lat': lat,
        'lon': lon,
        'radiusM': radiusM,
      };

  static NamedPlace fromJson(Map<String, dynamic> json) => NamedPlace(
        label: json['label'] as String,
        lat: (json['lat'] as num).toDouble(),
        lon: (json['lon'] as num).toDouble(),
        radiusM: (json['radiusM'] as num?)?.toDouble() ?? 200.0,
      );
}

/// Stores user-named places (Home, Work, Gym, etc.) and the visit threshold.
/// Backed by SharedPreferences.
class NamedPlacesStore {
  NamedPlacesStore._();
  static final NamedPlacesStore instance = NamedPlacesStore._();

  static const _placesKey = 'named_places_v1';
  static const _thresholdKey = 'visit_threshold_minutes';
  static const _poiLookupKey = 'poi_lookup_enabled';
  static const _defaultThreshold = 10;

  List<NamedPlace> _places = [];
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    await _load();
    _initialized = true;
  }

  List<NamedPlace> get all => List.unmodifiable(_places);

  Future<void> save(String label, double lat, double lon) async {
    await init();
    _places.removeWhere((p) => p.label.toLowerCase() == label.toLowerCase());
    _places.add(NamedPlace(label: label, lat: lat, lon: lon));
    await _savePlaces();
    debugPrint('[NamedPlacesStore] Saved "$label" at $lat, $lon');
  }

  Future<void> delete(String label) async {
    await init();
    _places.removeWhere((p) => p.label.toLowerCase() == label.toLowerCase());
    await _savePlaces();
  }

  /// Returns the matching named place if [lat]/[lon] falls within its radius,
  /// or null if no match.
  NamedPlace? findNearest(double lat, double lon) {
    for (final place in _places) {
      if (_distanceM(lat, lon, place.lat, place.lon) <= place.radiusM) {
        return place;
      }
    }
    return null;
  }

  Future<int> getVisitThresholdMinutes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_thresholdKey) ?? _defaultThreshold;
  }

  Future<void> setVisitThresholdMinutes(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_thresholdKey, minutes);
    debugPrint('[NamedPlacesStore] Visit threshold set to ${minutes}min');
  }

  Future<bool> getPoiLookupEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_poiLookupKey) ?? true; // default enabled
  }

  Future<void> setPoiLookupEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_poiLookupKey, enabled);
    debugPrint('[NamedPlacesStore] POI lookup ${enabled ? 'enabled' : 'disabled'}');
  }

  /// Tool handler: saves the user's current GPS position as a named place.
  /// [location] should be the map returned by getCurrentLocation().
  Future<Map<String, dynamic>> toolSaveNamedPlace(
      dynamic args, Map<String, dynamic> location) async {
    await init();
    if (args is! Map) {
      return {'ok': false, 'error': 'Invalid arguments'};
    }
    final label = args['label'] as String?;
    if (label == null || label.trim().isEmpty) {
      return {'ok': false, 'error': 'label is required'};
    }
    if (location['ok'] != true) {
      return {'ok': false, 'error': 'Location not available'};
    }
    final lat = (location['lat'] as num?)?.toDouble();
    final lon = (location['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) {
      return {'ok': false, 'error': 'GPS coordinates not available'};
    }
    await save(label.trim(), lat, lon);
    return {
      'ok': true,
      'label': label.trim(),
      'lat': lat,
      'lon': lon,
      'message': 'Saved "${label.trim()}" at your current location',
    };
  }

  static double _distanceM(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) *
            sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_placesKey);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List<dynamic>;
      _places = list
          .whereType<Map>()
          .map((e) => NamedPlace.fromJson(e.cast<String, dynamic>()))
          .toList();
      debugPrint('[NamedPlacesStore] Loaded ${_places.length} named places');
    } catch (e) {
      debugPrint('[NamedPlacesStore] Failed to load: $e');
      _places = [];
    }
  }

  Future<void> _savePlaces() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(_places.map((p) => p.toJson()).toList());
      await prefs.setString(_placesKey, encoded);
    } catch (e) {
      debugPrint('[NamedPlacesStore] Failed to save: $e');
    }
  }
}
