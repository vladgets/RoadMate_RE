package com.example.road_mate_flutter

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.graphics.Bitmap
import android.os.Build
import android.util.Log
import android.view.Display
import androidx.annotation.RequiresApi
import slayer.accessibility.service.flutter_accessibility_service.AccessibilityListener
import java.io.File
import java.io.FileOutputStream

class RoadMateAccessibilityService : AccessibilityListener() {

    companion object {
        /** Non-null while the service is connected. Used by MainActivity to request screenshots. */
        var instance: RoadMateAccessibilityService? = null
    }

    override fun onServiceConnected() {
        try {
            super.onServiceConnected()
        } catch (e: Exception) {
            // super.onServiceConnected() crashes when FlutterEngineCache is empty
            // (e.g. service reconnected after process restart). Safe to ignore.
            Log.w("RoadMateA11y", "super.onServiceConnected non-fatal: $e")
        }
        instance = this
        Log.d("RoadMateA11y", "Service connected — instance set")
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        Log.d("RoadMateA11y", "Service unbound — instance cleared")
        return super.onUnbind(intent)
    }

    /**
     * Capture the current screen as a PNG and write it to the app cache dir.
     * [callback] receives the absolute file path on success, null on failure.
     * Requires Android 11+ (API 30).
     */
    @RequiresApi(Build.VERSION_CODES.R)
    fun captureScreen(callback: (String?) -> Unit) {
        takeScreenshot(
            Display.DEFAULT_DISPLAY,
            mainExecutor,
            object : AccessibilityService.TakeScreenshotCallback {
                override fun onSuccess(screenshot: AccessibilityService.ScreenshotResult) {
                    try {
                        val hwBitmap = Bitmap.wrapHardwareBuffer(
                            screenshot.hardwareBuffer, screenshot.colorSpace
                        )
                        screenshot.hardwareBuffer.close()
                        if (hwBitmap == null) { callback(null); return }

                        // Hardware bitmaps can't be compressed directly — copy to software.
                        val softBitmap = hwBitmap.copy(Bitmap.Config.ARGB_8888, false)
                        hwBitmap.recycle()

                        val file = File(cacheDir, "screenshot_${System.currentTimeMillis()}.png")
                        FileOutputStream(file).use { out ->
                            softBitmap.compress(Bitmap.CompressFormat.PNG, 90, out)
                        }
                        softBitmap.recycle()

                        Log.d("RoadMateA11y", "Screenshot saved: ${file.absolutePath}")
                        callback(file.absolutePath)
                    } catch (e: Exception) {
                        Log.e("RoadMateA11y", "Screenshot processing error: $e")
                        callback(null)
                    }
                }

                override fun onFailure(errorCode: Int) {
                    Log.w("RoadMateA11y", "takeScreenshot failed: errorCode=$errorCode")
                    callback(null)
                }
            }
        )
    }
}
