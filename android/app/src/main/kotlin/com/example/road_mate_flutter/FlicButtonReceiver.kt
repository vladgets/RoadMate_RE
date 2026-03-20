package com.example.road_mate_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Exported BroadcastReceiver for Flic button single-press events.
 *
 * Configure in the Flic app:
 *   Send Intent → Action:   com.example.road_mate_flutter.FLIC_SINGLE
 *                 Package:  com.example.road_mate_flutter
 *                 Target:   Broadcast
 *
 * Sets a SharedPreferences flag (flutter.flic_pending = true) that the always-on
 * foreground service TaskHandler picks up in onRepeatEvent (every 2 s) and
 * forwards to the main Flutter isolate via sendDataToMain({'action': 'startVoice'}).
 *
 * No activity launch or service start needed — Android 12+ blocks both from
 * broadcast receivers.  The FGS is kept alive at all times once the app is opened.
 */
class FlicButtonReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        Log.d("FlicButton", "FlicButtonReceiver: received ${intent.action} — setting flic_pending flag")
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("flutter.flic_pending", true)
            .apply()
    }
}
