import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:intl/intl.dart';


/// Reverse geocode helper shared by foreground and background flows.
/// Returns a Placemark or null if not available.
Future<Placemark?> reverseGeocode(double lat, double lon) async {
  try {
    final placemarks = await placemarkFromCoordinates(lat, lon);
    return placemarks.isNotEmpty ? placemarks.first : null;
  } catch (_) {
    // Geocoding may fail in background; that's OK.
    return null;
  }
}

/// Currently used as a tool
Future<Map<String, dynamic>> getCurrentLocation() async {
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }

  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    return {
      "ok": false,
      "error": "Location permission denied",
    };
  }

  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
    ),
  );

  // 🔹 Reverse geocoding
  final place = await reverseGeocode(position.latitude, position.longitude);

  return {
    "ok": true,
    "lat": position.latitude,
    "lon": position.longitude,

    // Human-readable address
    "address": place == null ? null : {
      "street": place.street,
      "city": place.locality,
      "state": place.administrativeArea,
      "country": place.country,
      "postal_code": place.postalCode,
      "name": place.name,
    },
  };
}

/// Best-effort location for background execution.
///
/// In background isolates / restricted states, high-accuracy GPS + reverse geocoding
/// may fail or take too long. This helper:
///  - does NOT do reverse geocoding
///  - prefers last known position (fast, often available)
///  - falls back to a low-power current position with a short time limit
Future<Map<String, dynamic>> getBestEffortBackgroundLocation({
  Duration timeLimit = const Duration(seconds: 3),
}) async {
  // IMPORTANT: Do not prompt the user in background. Only check current permission.
  final permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    return {
      "ok": false,
      "error": "Location permission not granted",
    };
  }

  // 1) Try last known (fast, usually allowed even in background).
  try {
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) {
      final place = await reverseGeocode(last.latitude, last.longitude);

      return {
        "ok": true,
        "lat": last.latitude,
        "lon": last.longitude,
        "accuracy_m": last.accuracy,
          "address": place == null ? null : {
          "street": place.street,
          "city": place.locality,
          "state": place.administrativeArea,
          "country": place.country,
          "postal_code": place.postalCode,
          "name": place.name,
        },
        "source": "last_known",
      };
    }
  } catch (e) {
    // Ignore and fall back.
  }

  // 2) Try a low-power fix with a short time limit.
  try {
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.low,
      )
    );

    final place = await reverseGeocode(pos.latitude, pos.longitude);

    return {
      "ok": true,
      "lat": pos.latitude,
      "lon": pos.longitude,
      "accuracy_m": pos.accuracy,
      "address": place == null ? null : {
      "street": place.street,
      "city": place.locality,
      "state": place.administrativeArea,
      "country": place.country,
      "postal_code": place.postalCode,
      "name": place.name,
      },
      "source": "low_power_fix",
    };
  } catch (e) {
    return {
      "ok": false,
      "error": "Failed to acquire location: $e",
    };
  }
}



/// Returning redable date string like "Thursday, January 1, 2026" 
String getCurrentReadableDate() {
  final now = DateTime.now();
  final readableDate = DateFormat.yMMMMEEEEd().format(now);
  return readableDate;
}

/// LLM tool: returns current local time as a human-readable string
/// Example: "Thursday, January 1, 2026 at 6:42 PM"
Future<Map<String, dynamic>> getCurrentTime() async {
  final now = DateTime.now();

  return {
    "readable": DateFormat.yMMMMEEEEd().add_jm().format(now),  
  };
}