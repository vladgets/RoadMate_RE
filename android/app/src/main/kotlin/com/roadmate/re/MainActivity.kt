package com.roadmate.re

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import com.google.android.gms.location.ActivityRecognition
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Native driving detection bridge.
        // Flutter calls setFlutterAlive to prevent the native receiver from
        // duplicating work while the Dart stream is subscribed.
        // Flutter calls getPendingEvents on startup to pick up events that
        // the native receiver logged while the app process was dead.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "roadmate/driving_bridge")
            .setMethodCallHandler { call, result ->
                val prefs = applicationContext.getSharedPreferences(
                    DrivingDetectionReceiver.PREFS_NAME, Context.MODE_PRIVATE
                )
                when (call.method) {
                    "setFlutterAlive" -> {
                        prefs.edit()
                            .putLong(DrivingDetectionReceiver.KEY_FLUTTER_ALIVE_TS,
                                     System.currentTimeMillis())
                            .apply()
                        result.success(null)
                    }
                    "getPendingEvents" -> {
                        val json = prefs.getString(
                            DrivingDetectionReceiver.KEY_PENDING_EVENTS, "[]") ?: "[]"
                        prefs.edit()
                            .remove(DrivingDetectionReceiver.KEY_PENDING_EVENTS)
                            .apply()
                        result.success(json)
                    }
                    "getNativeDrivingState" -> {
                        val isDriving = prefs.getBoolean(
                            DrivingDetectionReceiver.KEY_IS_DRIVING, false)
                        result.success(isDriving)
                    }
                    "setNativeDrivingState" -> {
                        val isDriving = call.argument<Boolean>("isDriving") ?: false
                        prefs.edit()
                            .putBoolean(DrivingDetectionReceiver.KEY_IS_DRIVING, isDriving)
                            .putInt(DrivingDetectionReceiver.KEY_VEHICLE_COUNT,
                                    if (isDriving) DrivingDetectionReceiver.DEBOUNCE_COUNT else 0)
                            .putInt(DrivingDetectionReceiver.KEY_STILL_COUNT, 0)
                            .apply()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        registerNativeDrivingDetection()
    }

    private fun registerNativeDrivingDetection() {
        try {
            val intent = Intent(this, DrivingDetectionReceiver::class.java)
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pendingIntent = PendingIntent.getBroadcast(this, 77, intent, flags)
            ActivityRecognition.getClient(this)
                .requestActivityUpdates(5_000L, pendingIntent)
                .addOnSuccessListener {
                    Log.d("DrivingDetection", "Native activity recognition registered")
                }
                .addOnFailureListener { e: Exception ->
                    Log.w("DrivingDetection", "Native registration failed (permission not granted yet?): $e")
                }
        } catch (e: Exception) {
            Log.e("DrivingDetection", "registerNativeDrivingDetection error: $e")
        }
    }
}
