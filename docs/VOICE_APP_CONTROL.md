# Plan: Voice Control of Any Foreground App via Accessibility Service

## Context

The user wants RoadMate to act as a hands-free voice interface for **any app** running in the foreground. Primary use case: Waze shows a hazard alert asking "Confirm or Not there?" — impossible to answer hands-free in Waze itself. User speaks naturally into RoadMate ("confirm", "not there", "yes"), OpenAI maps the intent to a button text, and RoadMate taps that button in whichever app is active.

**Key decisions:**
- **Android only** (iOS OS-level sandboxing prevents accessing other apps' UI)
- **Generic**: works for any foreground app — no per-app config needed
- **Natural language shortcuts**: user says "confirm", "yes", "skip" — OpenAI figures out what button to tap
- **Text-based UI matching**: scan the foreground app's accessibility tree for a node with matching text

---

## How It Works

```
User says: "confirm"
  → OpenAI sees user intent + Waze is foreground app
  → Calls: tap_ui_button(button_text: "Confirm")
  → AppControlService scans Waze's UI tree for node with text "Confirm"
  → Simulates tap on that node
  → Returns {ok: true}
  → OpenAI says "Done!"
```

The same flow works for **any app**, any button:
- "close this" → `tap_ui_button(button_text: "Close")`
- "tap skip in Spotify" → `tap_ui_button(button_text: "Skip")`
- "press dismiss" → `tap_ui_button(button_text: "Dismiss")`

No per-app code. No configs. Just generic UI tree scanning.

---

## Technical Approach

### Core Technology
- **`flutter_accessibility_service` v0.3.0** package — Flutter bindings for Android AccessibilityService
- **Android `BIND_ACCESSIBILITY_SERVICE` permission** — user enables RoadMate in Settings > Accessibility (one-time)
- No per-app configurations or hardcoded UI patterns
- Event stream (`FlutterAccessibilityService.accessStream`) caches latest UI tree
- On tap request: flatten cached event's `subNodes` tree and search by text

### Matching Strategy (in priority order)
1. **Exact text match** — node whose `text` equals `button_text`
2. **Case-insensitive match** — same but case-insensitive
3. **Contains match** — node whose text *contains* `button_text`

Returns the first matching node.

---

## Files Created

| File | Purpose |
|------|---------|
| `lib/services/app_control_service.dart` | Core singleton: init plugin, check permission, `tapButtonByText(text)`, `getForegroundApp()`, tool handlers |
| `android/app/src/main/res/xml/accessibility_service_config.xml` | Android service config |
| `lib/ui/app_control_settings_screen.dart` | Settings: enable toggle, status indicator, privacy note |

---

## Files Modified

| File | Change |
|------|--------|
| `pubspec.yaml` | Added `flutter_accessibility_service: ^0.3.0` |
| `android/app/src/main/AndroidManifest.xml` | Added `<service>` for AccessibilityListener + permission |
| `lib/config.dart` | Added `tap_ui_button` and `get_foreground_app` tool schemas; updated system prompt |
| `lib/main.dart` | Registered both tool handlers + import |
| `lib/ui/main_settings_menu.dart` | Added "App Control" entry |

---

## Implementation Notes

### API Details (flutter_accessibility_service v0.3.0)
- Main class: `FlutterAccessibilityService` (all static)
- Event model: `AccessibilityEvent` (fields: `text`, `packageName`, `subNodes`, `isClickable`, `mapId`, etc.)
- Stream: `FlutterAccessibilityService.accessStream` — emits all accessibility events
- Tap: `FlutterAccessibilityService.performAction(node, NodeAction.actionClick)`
- Check permission: `FlutterAccessibilityService.isAccessibilityPermissionEnabled()`
- Open settings: `FlutterAccessibilityService.requestAccessibilityPermission()`

### AppControlService Pattern
- Singleton with `startListening()` / `stopListening()`
- Caches latest event with subNodes (UI tree)
- On `tapButtonByText`: flatten subNodes tree → 3-pass text search → performAction
- Starts listening automatically on first tool call if accessibility enabled

### Error Handling
All tool handlers return `{ok: bool, error?: string, message?: string}`:

| Scenario | Response |
|----------|---------|
| Accessibility not granted | "Enable App Control in RoadMate Settings." |
| No matching button found | "No button with text X found on screen." |
| Not Android | "App control is only supported on Android" |
| Success | `{ok: true, message: "Tapped 'Confirm' in Waze"}` |

---

## Setup & Verification

1. `flutter pub get` — install the new dependency
2. Build and install on Android (`flutter run`)
3. Open RoadMate Settings > App Control
4. Tap the toggle — confirm dialog → opens Android Accessibility Settings
5. Find "RoadMate" in the list and enable it
6. Return to RoadMate — status shows "Active"
7. Open any app with visible buttons (e.g. Waze hazard alert, a dialog)
8. Activate RoadMate voice mode, say "confirm" or "tap OK"
9. Verify the target app processes the tap
10. Run `flutter analyze` — no new warnings

---

## Status: ✅ Implemented (Feb 2026)
