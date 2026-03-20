# Background Driving Detection

## Overview

RoadMate automatically detects when you start and stop driving — no manual interaction required. When a drive begins or ends, the app:

1. Shows a system notification with time (and location when available)
2. Logs a timestamped event (GPS + address) to a local store
3. Makes the history queryable via the `get_driving_log` voice tool

Detection works **even when the app process is completely killed**, with no permanent notification icon in the status bar.

---

## Architecture

### Dual-path detection

Two systems run independently and hand off based on whether Flutter is alive:

```
Google Play Services
        │ PendingIntent (request code 0)        │ PendingIntent (request code 77)
        ▼                                        ▼
ActivityRecognizedBroadcastReceiver     DrivingDetectionReceiver
  (plugin, Dart stream path)              (native, killed-app path)
        │                                        │
  SharedPreferences ──► Flutter plugin           │ checks flutter_alive_ts
  OnSharedPreference-                    ├── < 2 min ago → skip (Dart handling it)
  ChangeListener                         └── stale → state machine + notification
        │                                        │
  DrivingMonitorService._onActivity()     roadmate_native_bridge SharedPreferences
  (Dart state machine)                    native_pending_events (JSON queue)
        │                                        │
  DrivingLogStore ◄───────────────────────────── DrivingMonitorService.start()
  + Flutter notifications                         drains queue on next launch
```

### Handoff mechanism

`DrivingMonitorService` writes a **Flutter-alive heartbeat** (`flutter_alive_ts`) to `roadmate_native_bridge` SharedPreferences via MethodChannel on startup and every ~60 s while the activity stream is running.

`DrivingDetectionReceiver` checks this timestamp before processing any event:
- **< 2 minutes old** → Flutter is alive and handling it → receiver skips
- **Stale / missing** → Flutter is dead → receiver runs the full state machine

### State machine (same logic in both paths)

| Condition | Action |
|-----------|--------|
| `inVehicle` + confidence ≥ 60% | Increment debounce counter |
| Counter reaches 2, not already driving | Set `_isDriving = true`, fire drive-started |
| `still` / `onFoot` / `walking` + confidence ≥ 60% | Reset counter |
| Was driving + non-vehicle activity | Set `_isDriving = false`, fire parked |
| `running`, `onBicycle`, `unknown`, `tilting` | No state change |

**Debounce**: 2 consecutive `inVehicle` readings (~60–120 s) before logging trip start.

---

## Architecture files

### Key files

#### `lib/services/driving_log_store.dart`
- `DrivingEvent` — model with `id`, `type` ('start'|'park'), `timestamp` (ISO8601 UTC), `lat?`, `lon?`, `address?`
- `DrivingLogStore` — singleton backed by SharedPreferences key `driving_events_v1`
  - Max 500 events (auto-pruned, newest-first)
  - `logEvent(type, location)` — builds address from location map, inserts, saves
  - `insertEvent(event)` — inserts a pre-built event (used when draining native queue)
  - `getRecentEvents(limit)` — unmodifiable list slice
  - `toolGetDrivingLog(args)` — tool handler returning `{ok, events[], count}`

#### `lib/services/driving_monitor_service.dart`
- `DrivingMonitorService` — singleton, Dart-side path
- Subscribes to `ActivityRecognition().activityStream(runForegroundService: false)`
- Manages its own `FlutterLocalNotificationsPlugin` on channel `roadmate_driving_monitor`
- Notification IDs: 9001 (trip start), 9002 (parked)
- On `start()`:
  1. Calls `setFlutterAlive` MethodChannel to suppress the native receiver
  2. Calls `getPendingEvents` MethodChannel to drain native queue into `DrivingLogStore`
- Every ~60 s on each activity event: calls `setFlutterAlive` to keep heartbeat fresh
- Exposes `rawEvents` stream for the Developer Area live feed

#### `android/app/src/main/kotlin/.../DrivingDetectionReceiver.kt`
- Manifest-declared `BroadcastReceiver` registered with `ActivityRecognitionClient`
  via `PendingIntent.getBroadcast(context, 77, ...)` in `MainActivity`
- SharedPreferences file: `roadmate_native_bridge`
  - `flutter_alive_ts` — last time Flutter confirmed it was alive (epoch ms, written by Dart)
  - `native_is_driving` — current driving state
  - `native_vehicle_count` — debounce counter
  - `native_pending_events` — JSON array of `{type, ts}` events for Flutter to pick up
- Shows notifications via `NotificationManager` (channel `roadmate_driving_monitor`, IDs 9001/9002)

#### `android/app/src/main/kotlin/.../MainActivity.kt`
- Calls `ActivityRecognition.getClient(this).requestActivityUpdates(5000, pendingIntent)`
  with `DrivingDetectionReceiver` target on every app launch
- MethodChannel `roadmate/driving_bridge`:
  - `setFlutterAlive` → writes `flutter_alive_ts = now()`
  - `getPendingEvents` → reads + clears `native_pending_events`, returns JSON string

#### `lib/ui/driving_log_screen.dart`
- Developer screen: Settings → Developer → Driving Log
- Lists all events newest-first with icon, label, time, address
- Tap row or map icon → opens Maps app pinned to that location
- AppBar has Refresh and Clear buttons

#### `lib/ui/developer_area_menu.dart`
- **Live Activity Feed** widget: subscribes to `DrivingMonitorService.rawEvents`
  and shows last 5 raw sensor events (type, confidence %, timestamp)
- Use this to verify the full sensor pipeline is working without driving (walk around → should see `walking`/`still` events)

### Modified files

| File | Change |
|------|--------|
| `pubspec.yaml` | Added `activity_recognition_flutter: ^6.0.0` |
| `AndroidManifest.xml` | `ACTIVITY_RECOGNITION`, `FOREGROUND_SERVICE_*` permissions; declared `ActivityRecognizedBroadcastReceiver`, `ActivityRecognizedService`, `ForegroundService` (plugin), `DrivingDetectionReceiver` (native) |
| `ios/Runner/Info.plist` | Added `NSMotionUsageDescription`; added `location` to `UIBackgroundModes` |
| `lib/main.dart` | Init driving log + monitor at startup; `get_driving_log` tool entry |
| `lib/config.dart` | Added `get_driving_log` tool schema |
| `lib/ui/developer_area_menu.dart` | Added Live Activity Feed; Driving Log entry |

---

## Background detection reliability

The native `DrivingDetectionReceiver` is delivered via `PendingIntent` from Google Play Services. Android wakes the app process briefly to run `onReceive()` — this works even when the process was completely killed.

### Practical expectations

| Scenario | Detection works? |
|----------|-----------------|
| App open in foreground or background | ✅ Yes (Dart stream) |
| App killed by user / Android, Pixel device | ✅ Yes (native receiver) |
| App killed, Samsung/Xiaomi with aggressive battery settings | ⚠️ Maybe (OEM may block receivers) |
| `ACTIVITY_RECOGNITION` permission not granted | ❌ No |
| User force-stopped the app from Settings | ❌ No (system blocks broadcasts for force-stopped apps) |

### Foreground service and notification icon

The foreground service (FGS) is **only active during voice mode**:

| App state | FGS | Notification icon |
|-----------|-----|-------------------|
| Idle / background / killed | ❌ Not running | No icon |
| Voice mode active | ✅ Running | Icon visible + "Stop" button |

Drive detection runs silently via the native `PendingIntent` path — no permanent status bar icon.

### Pending-events latency

Events that occur while the app is dead are stored in SharedPreferences by the native receiver and flushed into `DrivingLogStore` the next time the user opens RoadMate. The **notification** appears immediately (shown natively); the **log entry** appears on next launch. This is acceptable since the log is reviewed after the fact.

---

## Voice Tool

**`get_driving_log`** — returns recent driving events.

```
User: "where did I park last?"
  → AI calls get_driving_log(limit: 5)
  → Returns last 5 events with type, timestamp, address
  → AI: "You parked on Main St, Oakland at 3:15 PM"
```

Parameters:
- `limit` (integer, optional) — max events to return, default 10, max 50

Response shape:
```json
{
  "ok": true,
  "events": [
    {
      "id": "uuid",
      "type": "park",
      "timestamp": "2026-02-16T15:15:00Z",
      "lat": 37.8044,
      "lon": -122.2712,
      "address": "Main St, Oakland, CA"
    }
  ],
  "count": 1
}
```

---

## Platform Notes

### Android
- Requires `ACTIVITY_RECOGNITION` permission (Android 10+ / API 29+) — requested at runtime on `DrivingMonitorService.start()`
- `com.google.android.gms.permission.ACTIVITY_RECOGNITION` also declared for older GMS builds
- `activity_recognition_flutter` v6 requires the app manifest to declare its `BroadcastReceiver` and `JobIntentService` manually — they are **not** auto-declared by the plugin
- `DrivingDetectionReceiver` uses a separate PendingIntent (request code 77) registered on every `MainActivity` launch

### iOS
- Uses CoreMotion (`CMMotionActivityManager`) via `activity_recognition_flutter`
- `NSMotionUsageDescription` in `Info.plist` for permission prompt
- `location` in `UIBackgroundModes` enables background location access for GPS logging
- Native receiver not applicable — iOS background detection handled by the Dart stream

---

## Developer Testing

### Live Activity Feed (Developer Area)

Settings → Developer Area shows a **Live Activity Feed** with the last 5 raw sensor events. Walk around the office to confirm the sensor pipeline is working:
- Sit still → `still` events within ~30–60 s
- Walk to the kitchen → `walking` / `onFoot` events

If the feed shows "Waiting for sensor events…" after a minute of walking, check:
- Settings → Apps → RoadMate → Permissions → **Physical activity** (must be Allowed)
- Logcat filter `DrivingDetection` or `DrivingMonitor` for diagnostics

### Logcat tags

| Tag | Source |
|-----|--------|
| `DrivingMonitor` | Dart `DrivingMonitorService` |
| `DrivingDetection` | Native `DrivingDetectionReceiver` |
| `ActivityRecognizedService` | Plugin `JobIntentService` |
