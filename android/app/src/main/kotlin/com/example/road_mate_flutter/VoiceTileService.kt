package com.example.road_mate_flutter

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import androidx.annotation.RequiresApi

@RequiresApi(Build.VERSION_CODES.N)
class VoiceTileService : TileService() {

    companion object {
        // Kept in sync with the Flutter voice session state via
        // the roadmate/tile MethodChannel "setActive" call.
        var isVoiceActive = false
    }

    override fun onStartListening() {
        super.onStartListening()
        qsTile?.state = if (isVoiceActive) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        qsTile?.label = "RoadMate"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            qsTile?.subtitle = if (isVoiceActive) "Listening" else "Voice"
        }
        qsTile?.updateTile()
        Log.d("RoadMateA11y", "VoiceTileService: onStartListening isVoiceActive=$isVoiceActive")
    }

    override fun onClick() {
        super.onClick()
        val action = if (isVoiceActive)
            "com.example.road_mate_flutter.STOP_VOICE"
        else
            "com.example.road_mate_flutter.TRIGGER_VOICE"

        Log.d("RoadMateA11y", "VoiceTileService: tile tapped action=$action")

        val intent = Intent(this, MainActivity::class.java).apply {
            this.action = action
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pending = PendingIntent.getActivity(
                this, 0, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    override fun onStopListening() {
        super.onStopListening()
        Log.d("RoadMateA11y", "VoiceTileService: tile hidden")
    }
}
