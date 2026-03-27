import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:activity_recognition_flutter/activity_recognition_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import '../config.dart';
import 'driving_log_store.dart';
import 'named_places_store.dart';
import 'geo_time_tools.dart';

/// Monitors device activity to detect driving start/stop events and place visits.
///
/// Dual-path detection:
///   • App alive → this Dart service handles everything via activity stream.
///   • App killed → DrivingDetectionReceiver.kt handles it natively.
class DrivingMonitorService {
  DrivingMonitorService._();
  static final DrivingMonitorService instance = DrivingMonitorService._();

  // ---- Config ----
  static const int _debounceCount = 2;
  static const int _minConfidence = 60;
  static const double _visitRadiusM = 150.0;
  /// Minimum continuous still duration before a trip is considered ended.
  /// Prevents red-light stops (typically < 90 s) from triggering a park event.
  static const int _minStillDurationSecs = 90;
  /// Shorter gate used when onFoot/walking is detected: person clearly left the
  /// car, so we don't need a full 90-second wait.
  static const int _minWalkingDurationSecs = 30;

  // ---- Notifications ----
  static const int _notifIdStart = 9001;
  static const int _notifIdPark = 9002;
  static const String _channelId = 'roadmate_driving_monitor';
  static const String _channelName = 'Driving Monitor';

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _notifInitialized = false;

  // ---- Native bridge ----
  static const _bridge = MethodChannel('roadmate/driving_bridge');
  static const _uuid = Uuid();

  // ---- Raw event stream (for Developer Area live feed) ----
  final StreamController<ActivityEvent> _rawEventController =
      StreamController<ActivityEvent>.broadcast();
  Stream<ActivityEvent> get rawEvents => _rawEventController.stream;

  // ---- Visit state stream (for UI refresh when POI resolves or visit changes) ----
  final StreamController<void> _visitStateController =
      StreamController<void>.broadcast();
  Stream<void> get visitUpdates => _visitStateController.stream;

  // ---- Driving state ----
  StreamSubscription<ActivityEvent>? _subscription;
  bool _isDriving = false;
  int _vehicleReadings = 0;
  int _stillReadings = 0; // debounce for trip-stop, mirrors _vehicleReadings
  DateTime? _stillSince; // when the current continuous still phase began
  DateTime? _firstVehicleTime; // time of the very first inVehicle signal this trip
  Map<String, dynamic>? _firstStillLocation; // GPS snapped at the first still event
  Map<String, dynamic>? _lastVehicleLocation;
  DateTime? _lastVehicleLocationTs;
  Map<String, dynamic>? _lastVisitLocation; // saved from closed visit; fallback for trip-start

  // ---- Visit tracking state ----
  bool _visitActive = false;
  double? _visitLat;
  double? _visitLon;
  DateTime? _visitStartTime;
  DateTime? _visitLastTime;
  Map<String, dynamic>? _visitLocation; // full location map with address

  /// Non-null while a visit is being tracked (app alive).
  /// Used by DrivingLogScreen to show "Visiting since…" indicator.
  Map<String, dynamic>? get currentVisit {
    if (!_visitActive) return null;

    final result = <String, dynamic>{
      'startTime': _visitStartTime!.toIso8601String(),
      'lat': _visitLat,
      'lon': _visitLon,
    };

    // Add address if available
    if (_visitLocation != null && _visitLocation!['address'] != null) {
      final addr = _visitLocation!['address'] as Map;
      final parts = <String>[];
      final street = addr['street'];
      final city = addr['city'];
      final state = addr['state'];
      if (street != null && (street as String).isNotEmpty) parts.add(street);
      if (city != null && (city as String).isNotEmpty) parts.add(city);
      if (state != null && (state as String).isNotEmpty) parts.add(state);
      if (parts.isNotEmpty) {
        result['address'] = parts.join(', ');
      }
    }

    // Add POI label if available — prefer resolved poi_name, fall back to
    // device geocoder's place name (available immediately from address map).
    if (_visitLocation != null) {
      final poiName = _visitLocation!['poi_name'] as String?;
      if (poiName != null && poiName.isNotEmpty) {
        result['label'] = poiName;
      } else {
        final addrObj = _visitLocation!['address'];
        if (addrObj is Map) {
          final placeName = addrObj['name'] as String?;
          if (placeName != null && placeName.isNotEmpty) {
            result['label'] = placeName;
          }
        }
      }
    }

    return result;
  }

  // ---- SharedPreferences keys for visit state persistence ----
  static const _kVisitStartTs = 'dart_visit_start_ts';
  static const _kVisitLastTs = 'dart_visit_last_ts';
  static const _kVisitLat = 'dart_visit_lat';
  static const _kVisitLon = 'dart_visit_lon';
  static const _kVisitLocation = 'dart_visit_location'; // full location JSON

  // ---- Throttle ----
  DateTime? _lastAlivePing;

  // ---- Public API ----

  Future<void> start() async {
    if (_subscription != null) return;

    await _initNotifications();
    await NamedPlacesStore.instance.init();
    await _restoreVisitState(); // reload persisted visit start time before draining native events
    await _pingAlive();

    if (Platform.isAndroid) {
      await _drainNativePendingEvents();
    }

    if (Platform.isAndroid) {
      final status = await Permission.activityRecognition.request();
      if (status.isDenied || status.isPermanentlyDenied) {
        debugPrint('[DrivingMonitor] Activity recognition permission denied — monitoring disabled');
        return;
      }
    }

    try {
      final stream = ActivityRecognition().activityStream(
        runForegroundService: false,
      );
      _subscription = stream.listen(_onActivity, onError: (e) {
        debugPrint('[DrivingMonitor] Stream error: $e');
      });
      debugPrint('[DrivingMonitor] Started');
    } catch (e) {
      debugPrint('[DrivingMonitor] Failed to start: $e');
    }
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _isDriving = false;
    _vehicleReadings = 0;
    _stillReadings = 0;
    _stillSince = null;
    _firstVehicleTime = null;
    _firstStillLocation = null;
    _visitActive = false;
    debugPrint('[DrivingMonitor] Stopped');
  }

  Future<void> simulateTripStart() async {
    await _initNotifications();
    _isDriving = true;
    _vehicleReadings = _debounceCount;
    _onDrivingStarted();
  }

  Future<void> simulateParked() async {
    await _initNotifications();
    _isDriving = false;
    _vehicleReadings = 0;
    _stillReadings = 0;
    _stillSince = null;
    _firstStillLocation = null;
    _onParked();
  }

  // ---- Activity handling ----

  void _onActivity(ActivityEvent event) {
    final type = event.type;
    final confidence = event.confidence;

    debugPrint('[DrivingMonitor] Activity: $type confidence=$confidence isDriving=$_isDriving');

    _rawEventController.add(event);
    unawaited(_pingAlive());

    // Capture the earliest candidate trip-start time at any confidence level,
    // before the high-confidence gate below. Activity recognition often emits
    // several low-confidence inVehicle readings before reaching the 60% threshold,
    // so using the very first signal (even at 30-50%) gives a much more accurate
    // trip-start timestamp when the trip is later confirmed.
    if (type == ActivityType.inVehicle && !_isDriving && _firstVehicleTime == null) {
      _firstVehicleTime = DateTime.now();
      debugPrint('[DrivingMonitor] First vehicle candidate at confidence=$confidence');
    }

    if (confidence < _minConfidence) return;

    switch (type) {
      case ActivityType.inVehicle:
        // Close any active visit before registering driving
        unawaited(_maybeCloseVisit());
        _vehicleReadings++;
        _stillReadings = 0; // any vehicle reading cancels the stop debounce
        _stillSince = null; // car is moving again
        _firstStillLocation = null; // previous stop was a false alarm
        if (_vehicleReadings == 1) {
          // Snap time and location at the very first vehicle signal so the
          // confirmed trip-start event uses these rather than the debounce time.
          _firstVehicleTime ??= DateTime.now();
          unawaited(_refreshVehicleLocationForced());
        } else {
          unawaited(_refreshVehicleLocation());
        }
        if (_vehicleReadings >= _debounceCount && !_isDriving) {
          _isDriving = true;
          unawaited(_syncNativeDrivingState(isDriving: true));
          final firstTime = _firstVehicleTime;
          _firstVehicleTime = null;
          _lastVehicleLocation = null;
          _lastVehicleLocationTs = null;
          _onDrivingStarted(firstTime: firstTime);
        }
        break;

      case ActivityType.still:
        _vehicleReadings = 0;
        _firstVehicleTime = null; // reset for next trip
        _stillReadings++;
        if (_stillReadings == 1 && _isDriving) {
          // Snap GPS at the very first still event so the park location
          // reflects where the car stopped, not where it is 90 s later.
          unawaited(_snapFirstStillLocation());
        }
        _stillSince ??= DateTime.now();
        unawaited(_onStillActivity());
        // still alone = could be traffic jam; apply full 90-second gate.
        if (_isDriving && _stillReadings >= _debounceCount) {
          final stillSecs = DateTime.now().difference(_stillSince!).inSeconds;
          if (stillSecs >= _minStillDurationSecs) {
            _isDriving = false;
            unawaited(_syncNativeDrivingState(isDriving: false));
            _stillReadings = 0;
            final firstStillTime = _stillSince; // capture before clearing
            _stillSince = null;
            _onParked(firstStillTime: firstStillTime);
          }
        }
        break;

      case ActivityType.onFoot:
      case ActivityType.walking:
        _vehicleReadings = 0;
        _firstVehicleTime = null; // reset for next trip
        _stillReadings++;
        if (_stillReadings == 1 && _isDriving) {
          unawaited(_snapFirstStillLocation());
        }
        _stillSince ??= DateTime.now();
        unawaited(_onStillActivity());
        // Walking/onFoot means the person left the car — use a shorter gate so
        // the park is logged promptly while the snapped location is still fresh.
        if (_isDriving && _stillReadings >= _debounceCount) {
          final stillSecs = DateTime.now().difference(_stillSince!).inSeconds;
          if (stillSecs >= _minWalkingDurationSecs) {
            _isDriving = false;
            unawaited(_syncNativeDrivingState(isDriving: false));
            _stillReadings = 0;
            final firstStillTime = _stillSince; // capture before clearing
            _stillSince = null;
            _onParked(firstStillTime: firstStillTime);
          }
        }
        break;

      // running, onBicycle, unknown, tilting, invalid — no state change
      default:
        break;
    }
  }

  // ---- Visit tracking ----

  Future<void> _onStillActivity() async {
    try {
      final loc = await getBestEffortBackgroundLocation();
      if (loc['ok'] != true) return;
      final lat = (loc['lat'] as num).toDouble();
      final lon = (loc['lon'] as num).toDouble();

      if (!_visitActive) {
        _visitLat = lat;
        _visitLon = lon;
        _visitLocation = loc;
        _visitStartTime = DateTime.now();
        _visitLastTime = DateTime.now();
        _visitActive = true;
        _visitStateController.add(null);
        unawaited(_resolveVisitPlace(lat, lon)); // fetch POI name in background
        unawaited(_saveVisitState());
        debugPrint('[DrivingMonitor] Visit tracking started at $lat, $lon');
        return;
      }

      final dist = _distanceM(_visitLat!, _visitLon!, lat, lon);
      if (dist <= _visitRadiusM) {
        _visitLastTime = DateTime.now();
        unawaited(_saveVisitState()); // keep last-seen time fresh across restarts
        debugPrint('[DrivingMonitor] Visit same location (${dist.toStringAsFixed(0)}m), '
            '${DateTime.now().difference(_visitStartTime!).inMinutes}min elapsed');
      } else {
        // Moved to a different location — close current visit if it qualifies
        debugPrint('[DrivingMonitor] Moved ${dist.toStringAsFixed(0)}m from visit location');
        await _maybeCloseVisit(); // also clears persisted state
        // Start fresh at new location
        _visitLat = lat;
        _visitLon = lon;
        _visitLocation = loc;
        _visitStartTime = DateTime.now();
        _visitLastTime = DateTime.now();
        _visitActive = true;
        _visitStateController.add(null);
        unawaited(_resolveVisitPlace(lat, lon)); // fetch POI name in background
        unawaited(_saveVisitState());
      }
    } catch (e) {
      debugPrint('[DrivingMonitor] _onStillActivity error: $e');
    }
  }

  Future<void> _maybeCloseVisit() async {
    if (!_visitActive) return;

    // Capture and clear state atomically.
    // Use DateTime.now() as the end time — the visit ends when this method is
    // called (driving started or location changed), NOT when we last pinged
    // the location. _visitLastTime can be hours stale for overnight stays.
    final start = _visitStartTime!;
    final end = DateTime.now();
    final lat = _visitLat!;
    final lon = _visitLon!;
    final location = _visitLocation ?? {'ok': true, 'lat': lat, 'lon': lon};

    // Save for trip-start location fallback before clearing.
    if (location['ok'] == true) _lastVisitLocation = location;

    _visitActive = false;
    _visitLat = null;
    _visitLon = null;
    _visitStartTime = null;
    _visitLastTime = null;
    _visitLocation = null;
    _visitStateController.add(null);
    unawaited(_clearVisitState());

    final thresholdMin = await NamedPlacesStore.instance.getVisitThresholdMinutes();
    final durationMin = end.difference(start).inMinutes;

    if (durationMin >= thresholdMin) {
      debugPrint('[DrivingMonitor] Visit qualified: ${durationMin}min');
      try {
        await DrivingLogStore.instance.logVisit(start, end, location);
      } catch (e) {
        debugPrint('[DrivingMonitor] Error logging visit: $e');
      }
    } else {
      debugPrint('[DrivingMonitor] Visit too short (${durationMin}min < ${thresholdMin}min), discarded');
    }
  }

  // ---- Driving events ----

  void _onDrivingStarted({DateTime? firstTime}) {
    debugPrint('[DrivingMonitor] Driving started');
    _captureAndLog('start', 'Trip started', 'Detecting your drive…',
        eventTime: firstTime);
  }

  void _onParked({DateTime? firstStillTime}) {
    debugPrint('[DrivingMonitor] Parked');
    _captureAndLog('park', 'You parked', 'Logging your parking spot…',
        eventTime: firstStillTime);
  }

  /// Snap GPS at the moment the car first goes still so we have an accurate
  /// parking-spot location ready before the debounce window expires.
  Future<void> _snapFirstStillLocation() async {
    try {
      final loc = await getBestEffortBackgroundLocation();
      if (loc['ok'] == true) {
        _firstStillLocation = loc;
        debugPrint('[DrivingMonitor] First-still location snapped: '
            '${loc['lat']}, ${loc['lon']}');
      }
    } catch (_) {}
  }

  Future<void> _captureAndLog(
      String type, String notifTitle, String notifBodyFallback,
      {DateTime? eventTime}) async {
    try {
      Map<String, dynamic> location;
      if (type == 'park' && _firstStillLocation != null) {
        // Use the location snapped at the first still event — this is where
        // the car actually stopped, not where it is 90 s later.
        location = _firstStillLocation!;
        _firstStillLocation = null;
        debugPrint('[DrivingMonitor] Using first-still location for park event');
      } else if (type == 'park' && _lastVehicleLocation != null) {
        location = _lastVehicleLocation!;
        debugPrint('[DrivingMonitor] Using last-vehicle location for park event');
      } else {
        location = await getBestEffortBackgroundLocation();
        // If live GPS failed, fall back to last known vehicle location.
        if (location['ok'] != true && _lastVehicleLocation != null) {
          location = _lastVehicleLocation!;
          debugPrint('[DrivingMonitor] GPS unavailable — using last-vehicle location for $type event');
        }
        // For trip starts, also fall back to the previous visit location
        // (coordinates match when the trip begins right where the last visit ended).
        if (type == 'start' && location['ok'] != true && _lastVisitLocation != null) {
          location = _lastVisitLocation!;
          debugPrint('[DrivingMonitor] GPS unavailable — using last-visit location for start event');
        }
      }

      final event = await DrivingLogStore.instance.logEvent(type, location,
          eventTime: eventTime);

      // After a successful park, save location so the next trip start can use
      // it as a fallback if GPS is unavailable at departure.
      if (type == 'park' && location['ok'] == true) {
        _lastVisitLocation = location;
        debugPrint('[DrivingMonitor] Saved park location for next trip-start fallback');
      }

      final timeStr = DateFormat('h:mm a').format(DateTime.now());
      String body;
      if (event.address != null && event.address!.isNotEmpty) {
        final verb = type == 'start' ? 'Trip started at' : 'Parked at';
        body = '$verb ${event.address} • $timeStr';
      } else {
        body = '${type == 'start' ? 'Trip started' : 'Parked'} • $timeStr';
      }

      await _showNotification(
        id: type == 'start' ? _notifIdStart : _notifIdPark,
        title: notifTitle,
        body: body,
      );
    } catch (e) {
      debugPrint('[DrivingMonitor] Error in _captureAndLog: $e');
    }
  }

  // ---- Helpers ----

  Future<void> _refreshVehicleLocation() async {
    final now = DateTime.now();
    if (_lastVehicleLocationTs != null &&
        now.difference(_lastVehicleLocationTs!).inMinutes < 2) {
      return;
    }
    _lastVehicleLocationTs = now;
    try {
      final loc = await getBestEffortBackgroundLocation();
      if (loc['ok'] == true) {
        _lastVehicleLocation = loc;
        debugPrint('[DrivingMonitor] Vehicle location updated: '
            '${loc['lat']}, ${loc['lon']}');
      }
    } catch (_) {}
  }

  /// Force an immediate location capture regardless of the throttle.
  /// Called on the first vehicle reading so we have a location ready before
  /// the trip-start debounce window completes.
  Future<void> _refreshVehicleLocationForced() async {
    try {
      final loc = await getBestEffortBackgroundLocation();
      if (loc['ok'] == true) {
        _lastVehicleLocation = loc;
        _lastVehicleLocationTs = DateTime.now();
        debugPrint('[DrivingMonitor] Vehicle location force-captured: '
            '${loc['lat']}, ${loc['lon']}');
      }
    } catch (_) {}
  }

  /// Write Dart's current driving state to native SharedPreferences so the
  /// native BroadcastReceiver never re-fires a trip-start that Dart handled.
  Future<void> _syncNativeDrivingState({required bool isDriving}) async {
    if (!Platform.isAndroid) return;
    try {
      await _bridge.invokeMethod('setNativeDrivingState', {'isDriving': isDriving});
      debugPrint('[DrivingMonitor] Synced native isDriving=$isDriving');
    } catch (e) {
      debugPrint('[DrivingMonitor] Failed to sync native driving state: $e');
    }
  }

  Future<void> _pingAlive() async {
    if (!Platform.isAndroid) return;
    final now = DateTime.now();
    if (_lastAlivePing != null && now.difference(_lastAlivePing!).inSeconds < 60) return;
    _lastAlivePing = now;
    try {
      await _bridge.invokeMethod('setFlutterAlive');
    } catch (_) {}
  }

  Future<void> _drainNativePendingEvents() async {
    try {
      final json = await _bridge.invokeMethod<String>('getPendingEvents');

      // Always read native driving state so Dart is initialised correctly even
      // if there are no pending events — prevents a duplicate trip-start when
      // the activity stream fires while the user is already driving.
      final nativeIsDriving =
          await _bridge.invokeMethod<bool>('getNativeDrivingState') ?? false;
      if (nativeIsDriving && !_isDriving) {
        _isDriving = true;
        _vehicleReadings = _debounceCount; // suppress debounce re-trigger
        debugPrint('[DrivingMonitor] Initialised Dart isDriving=true from native state');
      }

      if (json == null || json == '[]') return;
      final list = jsonDecode(json) as List<dynamic>;
      for (final raw in list) {
        if (raw is! Map) continue;
        final type = raw['type'] as String? ?? 'start';
        final tsMs = raw['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch;

        if (type == 'visit') {
          // Visit events have ts_start, ts_end, lat, lon
          final tsStart = raw['ts_start'] as int? ?? tsMs;
          final tsEnd = raw['ts_end'] as int? ?? tsMs;
          final lat = (raw['lat'] as num?)?.toDouble();
          final lon = (raw['lon'] as num?)?.toDouble();
          final start = DateTime.fromMillisecondsSinceEpoch(tsStart);
          final end = DateTime.fromMillisecondsSinceEpoch(tsEnd);
          final location = lat != null
              ? {'ok': true, 'lat': lat, 'lon': lon}
              : {'ok': false};
          await DrivingLogStore.instance.logVisit(start, end, location);
          debugPrint('[DrivingMonitor] Drained native visit: '
              '${end.difference(start).inMinutes}min'
              '${lat != null ? ' at ($lat, $lon)' : ''}');
        } else {
          // 'start' or 'park'
          final lat = (raw['lat'] as num?)?.toDouble();
          final lon = (raw['lon'] as num?)?.toDouble();

          if (type == 'start' && _visitActive) {
            // A trip started while the app was dead — any active visit ended then.
            // Clear stale Dart visit state so returning to the same location later
            // starts a fresh visit with the correct return time, not the old start.
            if (_visitLocation != null && _visitLocation!['ok'] == true) {
              _lastVisitLocation = _visitLocation;
            }
            _visitActive = false;
            _visitLat = null;
            _visitLon = null;
            _visitStartTime = null;
            _visitLastTime = null;
            _visitLocation = null;
            _visitStateController.add(null);
            unawaited(_clearVisitState());
            debugPrint('[DrivingMonitor] Cleared stale visit state on native trip-start drain');
          }

          // For park events with coordinates, save as last visit location fallback.
          if (type == 'park' && lat != null && lon != null) {
            _lastVisitLocation = {'ok': true, 'lat': lat, 'lon': lon};
          }

          final event = DrivingEvent(
            id: _uuid.v4(),
            type: type,
            timestamp: DateTime.fromMillisecondsSinceEpoch(tsMs).toUtc().toIso8601String(),
            lat: lat,
            lon: lon,
          );
          await DrivingLogStore.instance.insertEvent(event);
          debugPrint('[DrivingMonitor] Drained native event: $type at ${event.timestamp}'
              '${lat != null ? ' ($lat, $lon)' : ''}');
        }
      }
    } catch (e) {
      debugPrint('[DrivingMonitor] Failed to drain native events: $e');
    }
  }

  // ---- Visit state persistence ----

  Future<void> _saveVisitState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kVisitStartTs, _visitStartTime!.millisecondsSinceEpoch);
      await prefs.setInt(_kVisitLastTs, _visitLastTime!.millisecondsSinceEpoch);
      await prefs.setDouble(_kVisitLat, _visitLat!);
      await prefs.setDouble(_kVisitLon, _visitLon!);
      if (_visitLocation != null) {
        await prefs.setString(_kVisitLocation, jsonEncode(_visitLocation));
      }
    } catch (_) {}
  }

  Future<void> _clearVisitState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kVisitStartTs);
      await prefs.remove(_kVisitLastTs);
      await prefs.remove(_kVisitLat);
      await prefs.remove(_kVisitLon);
      await prefs.remove(_kVisitLocation);
    } catch (_) {}
  }

  Future<void> _restoreVisitState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final startTs = prefs.getInt(_kVisitStartTs);
      if (startTs == null) return;
      final lastTs = prefs.getInt(_kVisitLastTs);
      final lat = prefs.getDouble(_kVisitLat);
      final lon = prefs.getDouble(_kVisitLon);
      if (lat == null || lon == null) return;

      _visitStartTime = DateTime.fromMillisecondsSinceEpoch(startTs);
      _visitLastTime = lastTs != null
          ? DateTime.fromMillisecondsSinceEpoch(lastTs)
          : DateTime.now();
      _visitLat = lat;
      _visitLon = lon;

      // Restore full location JSON if available
      final locationJson = prefs.getString(_kVisitLocation);
      if (locationJson != null) {
        try {
          _visitLocation = jsonDecode(locationJson) as Map<String, dynamic>;
        } catch (_) {
          _visitLocation = {'ok': true, 'lat': lat, 'lon': lon};
        }
      } else {
        _visitLocation = {'ok': true, 'lat': lat, 'lon': lon};
      }

      _visitActive = true;
      debugPrint('[DrivingMonitor] Restored visit state: started '
          '${DateTime.now().difference(_visitStartTime!).inMinutes}min ago at $lat, $lon');

      // Re-resolve POI if it wasn't persisted (app was killed before resolution completed)
      final hasPoi = _visitLocation!['poi_name'] != null;
      if (!hasPoi) {
        unawaited(_resolveVisitPlace(lat, lon));
      }
    } catch (e) {
      debugPrint('[DrivingMonitor] Could not restore visit state: $e');
    }
  }

  /// Resolve POI name for the current visit location.
  /// Checks named places first, then queries Nominatim if POI lookup is enabled.
  Future<void> _resolveVisitPlace(double lat, double lon) async {
    try {
      // Check named places first
      final namedPlace = NamedPlacesStore.instance.findNearest(lat, lon);
      if (namedPlace != null) {
        if (_visitLocation != null) {
          _visitLocation!['poi_name'] = namedPlace.label;
          _visitStateController.add(null);
        }
        unawaited(_saveVisitState());
        debugPrint('[DrivingMonitor] Visit at named place: ${namedPlace.label}');
        return;
      }

      // POI lookup via Nominatim if enabled
      if (!await NamedPlacesStore.instance.getPoiLookupEnabled()) return;

      final url = Uri.parse('${Config.serverUrl}/nominatim/reverse');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'lat': lat, 'lon': lon}),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final poiName = data['poi_name'] as String?;
        if (poiName != null && poiName.isNotEmpty && _visitLocation != null) {
          _visitLocation!['poi_name'] = poiName;
          _visitStateController.add(null);
          unawaited(_saveVisitState());
          debugPrint('[DrivingMonitor] Visit POI resolved: $poiName');
        }
      }
    } catch (e) {
      debugPrint('[DrivingMonitor] POI resolution failed: $e');
    }
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

  // ---- Notifications ----

  Future<void> _showNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    try {
      const androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Automatic drive start/stop detection',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        autoCancel: true,
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentSound: false,
      );
      const details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );
      await _notifications.show(id, title, body, details);
      debugPrint('[DrivingMonitor] Notification shown: $title — $body');
    } catch (e) {
      debugPrint('[DrivingMonitor] Failed to show notification: $e');
    }
  }

  Future<void> _initNotifications() async {
    if (_notifInitialized) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );
    await _notifications.initialize(initSettings);

    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: 'Automatic drive start/stop detection',
      importance: Importance.defaultImportance,
    );
    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(channel);
    }

    _notifInitialized = true;
    debugPrint('[DrivingMonitor] Notifications initialized');
  }
}
