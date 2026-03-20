package com.roadmate.re

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Exported BroadcastReceiver for Flic button single-press events.
 *
 * Configure in the Flic app:
 *   Send Intent → Action:   com.roadmate.re.FLIC_SINGLE
 *                 Package:  com.roadmate.re
 *                 Target:   Broadcast
 *
 * Starts FlicVoiceService, which calls startForeground() and then launches
 * MainActivity. This two-step approach is required on Android 14+ where
 * startActivity() is blocked directly from BroadcastReceivers.
 */
class FlicButtonReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        Log.d("FlicButton", "FlicButtonReceiver: received ${intent.action} — starting FlicVoiceService")
        val serviceIntent = Intent(context, FlicVoiceService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }
}
