package com.example.road_mate_flutter

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Short-lived foreground service (type: dataSync) used exclusively to launch
 * MainActivity from a background broadcast context.
 *
 * Android 14+ blocks startActivity() from BroadcastReceivers when the app has
 * no visible window.  A foreground service does not have this restriction.
 *
 * Flow:
 *  1. FlicButtonReceiver calls startForegroundService(FlicVoiceService)
 *  2. This service calls startForeground() → satisfies Android 8+ FGS rule
 *  3. startActivity(MainActivity + TRIGGER_VOICE + FLIC_BACKGROUND) → allowed
 *  4. stopSelf() — service disappears in < 1 s; notification is auto-dismissed
 */
class FlicVoiceService : Service() {

    companion object {
        private const val TAG = "FlicButton"
        private const val CHANNEL_ID = "roadmate_flic_launch"
        private const val NOTIF_ID = 997
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "FlicVoiceService: starting foreground then launching MainActivity")
        ensureChannel()

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("RoadMate")
            .setContentText("Starting voice…")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setSilent(true)
            .build()

        startForeground(NOTIF_ID, notification)

        // From a running FGS, startActivity() is always permitted on Android 10+.
        val launch = Intent(this, MainActivity::class.java).apply {
            action = "com.example.road_mate_flutter.TRIGGER_VOICE"
            putExtra("FLIC_BACKGROUND", true)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            )
        }
        startActivity(launch)

        // Stop immediately — notification will be auto-dismissed.
        stopSelf(startId)
        return START_NOT_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID,
                    "RoadMate Voice Activation",
                    NotificationManager.IMPORTANCE_MIN
                ).apply { setShowBadge(false) }
                nm.createNotificationChannel(ch)
            }
        }
    }
}
