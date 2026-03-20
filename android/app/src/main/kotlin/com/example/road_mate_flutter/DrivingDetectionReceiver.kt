package com.example.road_mate_flutter

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.location.LocationManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.android.gms.location.ActivityRecognitionResult
import com.google.android.gms.location.DetectedActivity

/**
 * Manifest-declared BroadcastReceiver for activity recognition events.
 *
 * Registered with its own PendingIntent (request code 77) in MainActivity,
 * independently of the activity_recognition_flutter plugin's registration.
 * Android wakes the app process briefly to deliver the broadcast — no
 * persistent foreground service required.
 *
 * When Flutter is alive (it updates [KEY_FLUTTER_ALIVE_TS] every ~60 s),
 * this receiver does nothing — the Dart DrivingMonitorService handles it.
 * When Flutter is dead (ts is stale), this receiver:
 *   1. Runs the driving + visit state machines in SharedPreferences
 *   2. Shows a notification via Android NotificationManager
 *   3. Appends pending events to [KEY_PENDING_EVENTS] for Flutter to pick
 *      up the next time the app is launched.
 */
class DrivingDetectionReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "DrivingDetection"

        const val PREFS_NAME = "roadmate_native_bridge"
        const val KEY_FLUTTER_ALIVE_TS = "flutter_alive_ts"
        // Public so MainActivity can read/write them when syncing Dart state.
        const val KEY_IS_DRIVING = "native_is_driving"
        const val KEY_VEHICLE_COUNT = "native_vehicle_count"
        const val KEY_STILL_COUNT = "native_still_count"
        private const val KEY_STILL_SINCE_TS = "native_still_since_ts"
        const val KEY_PENDING_EVENTS = "native_pending_events"
        private const val KEY_LAST_VEH_LAT = "native_last_veh_lat"
        private const val KEY_LAST_VEH_LON = "native_last_veh_lon"

        // Visit state keys
        private const val KEY_VISIT_ACTIVE = "native_visit_active"
        private const val KEY_VISIT_START_TS = "native_visit_start_ts"
        private const val KEY_VISIT_LAT = "native_visit_lat"
        private const val KEY_VISIT_LON = "native_visit_lon"
        private const val KEY_VISIT_LAST_TS = "native_visit_last_ts"

        // Flutter must have sent a heartbeat within this window or native takes over.
        private const val FLUTTER_ALIVE_WINDOW_MS = 120_000L

        const val DEBOUNCE_COUNT = 2
        private const val MIN_CONFIDENCE = 60

        private const val VISIT_RADIUS_M = 150f
        private const val VISIT_THRESHOLD_MS = 600_000L // 10 minutes
        private const val MIN_STILL_DURATION_MS = 90_000L // 90 s — red-light guard

        private const val NOTIF_CHANNEL_ID = "roadmate_driving_monitor"
        private const val NOTIF_CHANNEL_NAME = "Driving Monitor"
        private const val NOTIF_ID_START = 9001
        private const val NOTIF_ID_PARK = 9002
    }

    override fun onReceive(context: Context, intent: Intent) {
        val result = ActivityRecognitionResult.extractResult(intent) ?: return
        val mostLikely = result.probableActivities.maxByOrNull { it.confidence } ?: return

        Log.d(TAG, "Activity: type=${mostLikely.type} confidence=${mostLikely.confidence}")

        // If Flutter is alive and recently handling events, do nothing here.
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val flutterAliveTs = prefs.getLong(KEY_FLUTTER_ALIVE_TS, 0L)
        if (System.currentTimeMillis() - flutterAliveTs < FLUTTER_ALIVE_WINDOW_MS) {
            Log.d(TAG, "Flutter alive — skipping native handling")
            return
        }

        if (mostLikely.confidence < MIN_CONFIDENCE) return

        val isDriving = prefs.getBoolean(KEY_IS_DRIVING, false)
        var vehicleCount = prefs.getInt(KEY_VEHICLE_COUNT, 0)
        var stillCount = prefs.getInt(KEY_STILL_COUNT, 0)

        when (mostLikely.type) {
            DetectedActivity.IN_VEHICLE -> {
                // Finalize any active visit before processing drive start
                maybeFinalizeVisit(prefs)
                vehicleCount++
                prefs.edit()
                    .putInt(KEY_VEHICLE_COUNT, vehicleCount)
                    .putInt(KEY_STILL_COUNT, 0)      // cancel stop debounce
                    .remove(KEY_STILL_SINCE_TS)      // car is moving again
                    .apply()
                snapshotVehicleLocation(context, prefs)
                if (vehicleCount >= DEBOUNCE_COUNT && !isDriving) {
                    prefs.edit().putBoolean(KEY_IS_DRIVING, true).apply()
                    onDrivingStarted(context, prefs)
                }
            }
            DetectedActivity.STILL,
            DetectedActivity.ON_FOOT,
            DetectedActivity.WALKING -> {
                handleVisitActivity(context, prefs)
                stillCount++
                val now = System.currentTimeMillis()
                // Record when the still phase began (only on first still after moving)
                val stillSinceTs = prefs.getLong(KEY_STILL_SINCE_TS, 0L)
                    .takeIf { it != 0L } ?: run {
                        prefs.edit().putLong(KEY_STILL_SINCE_TS, now).apply()
                        now
                    }
                prefs.edit()
                    .putInt(KEY_VEHICLE_COUNT, 0)
                    .putInt(KEY_STILL_COUNT, stillCount)
                    .apply()
                // Mirror start-debounce AND enforce a minimum continuous still
                // duration so red-light stops (< 90 s) don't trigger a park event.
                if (isDriving && stillCount >= DEBOUNCE_COUNT) {
                    val elapsed = now - stillSinceTs
                    if (elapsed >= MIN_STILL_DURATION_MS) {
                        prefs.edit()
                            .putBoolean(KEY_IS_DRIVING, false)
                            .putInt(KEY_STILL_COUNT, 0)
                            .remove(KEY_STILL_SINCE_TS)
                            .apply()
                        onParked(context, prefs)
                    }
                }
            }
            else -> Unit
        }
    }

    // ---- Driving events ----

    private fun onDrivingStarted(context: Context, prefs: SharedPreferences) {
        Log.d(TAG, "Drive started (native)")
        addTripPendingEvent(prefs, "start")
        showNotification(context, NOTIF_ID_START, "Trip started", "Your drive has begun")
    }

    private fun onParked(context: Context, prefs: SharedPreferences) {
        Log.d(TAG, "Parked (native)")
        addTripPendingEvent(prefs, "park")
        showNotification(context, NOTIF_ID_PARK, "You parked", "Your drive has ended")
    }

    private fun addTripPendingEvent(prefs: SharedPreferences, type: String) {
        val ts = System.currentTimeMillis()
        val existing = prefs.getString(KEY_PENDING_EVENTS, "[]") ?: "[]"

        val newEvent = if (type == "park") {
            val lat = prefs.getFloat(KEY_LAST_VEH_LAT, Float.NaN)
            val lon = prefs.getFloat(KEY_LAST_VEH_LON, Float.NaN)
            if (!lat.isNaN() && !lon.isNaN()) {
                """{"type":"$type","ts":$ts,"lat":$lat,"lon":$lon}"""
            } else {
                """{"type":"$type","ts":$ts}"""
            }
        } else {
            """{"type":"$type","ts":$ts}"""
        }

        val updated = if (existing == "[]") "[$newEvent]" else "${existing.dropLast(1)},$newEvent]"
        prefs.edit().putString(KEY_PENDING_EVENTS, updated).apply()
        Log.d(TAG, "Trip pending event queued: $newEvent")
    }

    // ---- Visit state machine ----

    private fun handleVisitActivity(context: Context, prefs: SharedPreferences) {
        val coords = getLastKnownCoordinates(context) ?: return
        val (lat, lon) = coords
        val now = System.currentTimeMillis()

        val visitActive = prefs.getBoolean(KEY_VISIT_ACTIVE, false)

        if (!visitActive) {
            prefs.edit()
                .putBoolean(KEY_VISIT_ACTIVE, true)
                .putLong(KEY_VISIT_START_TS, now)
                .putFloat(KEY_VISIT_LAT, lat)
                .putFloat(KEY_VISIT_LON, lon)
                .putLong(KEY_VISIT_LAST_TS, now)
                .apply()
            Log.d(TAG, "Visit tracking started at $lat, $lon")
            return
        }

        val visitLat = prefs.getFloat(KEY_VISIT_LAT, 0f)
        val visitLon = prefs.getFloat(KEY_VISIT_LON, 0f)
        val distance = distanceM(visitLat.toDouble(), visitLon.toDouble(),
            lat.toDouble(), lon.toDouble())

        if (distance <= VISIT_RADIUS_M) {
            prefs.edit().putLong(KEY_VISIT_LAST_TS, now).apply()
            Log.d(TAG, "Visit still at same location (${distance.toInt()}m)")
        } else {
            // Moved — commit previous visit if it qualifies, start fresh.
            // Use now as end time (visit ends when user moved, not last ping).
            val startTs = prefs.getLong(KEY_VISIT_START_TS, now)
            if (now - startTs >= VISIT_THRESHOLD_MS) {
                Log.d(TAG, "Visit ended by location change: ${(now - startTs) / 60000}min")
                addVisitPendingEvent(prefs, startTs, now, visitLat, visitLon)
            }
            prefs.edit()
                .putBoolean(KEY_VISIT_ACTIVE, true)
                .putLong(KEY_VISIT_START_TS, now)
                .putFloat(KEY_VISIT_LAT, lat)
                .putFloat(KEY_VISIT_LON, lon)
                .putLong(KEY_VISIT_LAST_TS, now)
                .apply()
            Log.d(TAG, "Visit restarted at new location $lat, $lon")
        }
    }

    private fun maybeFinalizeVisit(prefs: SharedPreferences) {
        if (!prefs.getBoolean(KEY_VISIT_ACTIVE, false)) return

        val startTs = prefs.getLong(KEY_VISIT_START_TS, 0L)
        val visitLat = prefs.getFloat(KEY_VISIT_LAT, 0f)
        val visitLon = prefs.getFloat(KEY_VISIT_LON, 0f)
        // Use now as end time — the visit ends when driving starts, not when we
        // last pinged the location. lastTs can be many hours stale for overnight stays.
        val now = System.currentTimeMillis()

        prefs.edit()
            .putBoolean(KEY_VISIT_ACTIVE, false)
            .remove(KEY_VISIT_START_TS)
            .remove(KEY_VISIT_LAT)
            .remove(KEY_VISIT_LON)
            .remove(KEY_VISIT_LAST_TS)
            .apply()

        if (now - startTs >= VISIT_THRESHOLD_MS) {
            Log.d(TAG, "Visit finalized on drive start: ${(now - startTs) / 60000}min")
            addVisitPendingEvent(prefs, startTs, now, visitLat, visitLon)
        }
    }

    private fun addVisitPendingEvent(
        prefs: SharedPreferences,
        startTs: Long,
        endTs: Long,
        lat: Float,
        lon: Float
    ) {
        val existing = prefs.getString(KEY_PENDING_EVENTS, "[]") ?: "[]"
        val newEvent = """{"type":"visit","ts_start":$startTs,"ts_end":$endTs,"lat":$lat,"lon":$lon}"""
        val updated = if (existing == "[]") "[$newEvent]" else "${existing.dropLast(1)},$newEvent]"
        prefs.edit().putString(KEY_PENDING_EVENTS, updated).apply()
        Log.d(TAG, "Visit pending event queued: ${(endTs - startTs) / 60000}min at $lat, $lon")
    }

    // ---- Location helpers ----

    @SuppressLint("MissingPermission")
    private fun getLastKnownCoordinates(context: Context): Pair<Float, Float>? {
        return try {
            val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            for (provider in providers) {
                val loc = lm.getLastKnownLocation(provider) ?: continue
                return Pair(loc.latitude.toFloat(), loc.longitude.toFloat())
            }
            null
        } catch (e: Exception) {
            Log.w(TAG, "Could not get coordinates: $e")
            null
        }
    }

    @SuppressLint("MissingPermission")
    private fun snapshotVehicleLocation(context: Context, prefs: SharedPreferences) {
        try {
            val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            for (provider in providers) {
                val loc = lm.getLastKnownLocation(provider) ?: continue
                prefs.edit()
                    .putFloat(KEY_LAST_VEH_LAT, loc.latitude.toFloat())
                    .putFloat(KEY_LAST_VEH_LON, loc.longitude.toFloat())
                    .apply()
                Log.d(TAG, "Vehicle location snapshot: ${loc.latitude}, ${loc.longitude}")
                return
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not snapshot vehicle location: $e")
        }
    }

    private fun distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Float {
        val results = FloatArray(1)
        android.location.Location.distanceBetween(lat1, lon1, lat2, lon2, results)
        return results[0]
    }

    // ---- Notifications ----

    private fun showNotification(context: Context, id: Int, title: String, text: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIF_CHANNEL_ID,
                NOTIF_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_DEFAULT
            )
            nm.createNotificationChannel(channel)
        }

        val notification = NotificationCompat.Builder(context, NOTIF_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .build()

        nm.notify(id, notification)
        Log.d(TAG, "Notification shown: $title — $text")
    }
}
