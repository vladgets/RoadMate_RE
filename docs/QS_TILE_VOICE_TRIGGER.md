# Quick Settings Tile Voice Trigger

## Overview

A Quick Settings tile ("RoadMate") lets the user start or stop a RoadMate voice session from any app — without unlocking the phone or switching apps. The tile lives in the Android notification shade and is always one swipe + tap away.

## User Experience

- **Inactive tile**: grey mic icon, subtitle "Voice". Tap to start listening.
- **Active tile**: highlighted mic icon, subtitle "Listening". Tap again to stop.
- After tapping to start, RoadMate briefly flashes on screen (while it connects to OpenAI), then automatically minimizes. The voice session continues in the background — the user stays in Waze, Spotify, or wherever they were.
- Tapping the active tile stops the session and returns the user to their previous app.

## How It Works

### Trigger path (start)
1. User taps the tile → Android calls `VoiceTileService.onClick()`
2. The tile uses `startActivityAndCollapse()` — the only API that can reliably launch an Activity from a Quick Settings tile on modern Android (bypasses background launch restrictions)
3. RoadMate's main screen comes to the foreground with a `TRIGGER_VOICE` intent
4. The intent is delivered to Flutter via an `EventChannel`, which fires the voice connection callback
5. Once the foreground microphone service has started, the app minimizes itself back to the previous app

### Trigger path (stop)
Same as start but with a `STOP_VOICE` intent, which fires the disconnect callback.

### Tile state sync
Flutter calls a `MethodChannel` whenever the voice session connects or disconnects. The native side updates a static flag in `VoiceTileService` and calls `TileService.requestListeningState()` (Android 11+), which triggers `onStartListening` and refreshes the tile's visual state immediately — no need to close and reopen the shade.

## Android Constraints Solved

| Constraint | Solution |
|---|---|
| Background Activity start blocked (Android 10+) | Use `startActivityAndCollapse()` which has system-granted exemption |
| Implicit broadcasts ignored in background (Android 8+) | Use `startActivityAndCollapse` directly — no broadcast needed |
| Microphone FGS must call `startForeground()` while app is in foreground (Android 14+) | Poll `isRunningService` every 100 ms; minimize only after the service confirms it's started |
| Tile state stale until shade reopened | `TileService.requestListeningState()` forces an immediate `onStartListening` callback |
| Accessibility button callback dead on Android 12+ (gesture nav) | Abandoned; tile is the reliable modern replacement |

## Files Added / Modified

| File | Role |
|---|---|
| `VoiceTileService.kt` | Quick Settings tile service; toggles start/stop intent; reflects voice state |
| `VoiceTriggerReceiver.kt` | Manifest-declared receiver as a fallback entry point when the Activity is not alive |
| `RoadMateAccessibilityService.kt` | Stripped to minimal subclass; accessibility button code removed |
| `MainActivity.kt` | Handles `TRIGGER_VOICE` / `STOP_VOICE` intents in `onNewIntent`; exposes `roadmate/tile` and `roadmate/navigation` MethodChannels |
| `app_control_service.dart` | `setTileActive()` and `moveToBackground()` Flutter helpers |
| `main.dart` | Wires tile callbacks; calls `setTileActive` on connect/disconnect; `_minimizeWhenFgsReady()` for safe background transition |
