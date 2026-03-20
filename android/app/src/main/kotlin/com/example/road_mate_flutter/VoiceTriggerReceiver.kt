package com.example.road_mate_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Manifest-declared receiver for voice trigger broadcasts.
 * Always active regardless of whether MainActivity is alive.
 * Starts/resumes MainActivity with a TRIGGER_VOICE intent handled in onNewIntent.
 */
class VoiceTriggerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.d("RoadMateA11y", "VoiceTriggerReceiver: received ${intent.action} — launching MainActivity with TRIGGER_VOICE")
        val launch = Intent(context, MainActivity::class.java).apply {
            action = "com.example.road_mate_flutter.TRIGGER_VOICE"
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        context.startActivity(launch)
    }
}
