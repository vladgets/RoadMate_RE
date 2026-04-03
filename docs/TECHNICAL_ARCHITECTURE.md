# RoadMate — Technical Architecture

This document covers the system design, component breakdown, development workflow, and extension points for RoadMate.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Mobile/Desktop app | Flutter (Dart) |
| Backend server | Node.js + Express |
| Voice AI | OpenAI Realtime API (`gpt-realtime-mini-2025-12-15`) |
| Audio transport | WebRTC via `flutter_webrtc` |
| OAuth | Google APIs (Gmail, YouTube) |
| CRM | Follow Up Boss REST API |
| Notifications | `flutter_local_notifications` |
| Permissions | `permission_handler` |
| Deployment | Render.com (`https://roadmate-flutter.onrender.com`) |

---

## Development Commands

### Flutter App

```bash
flutter pub get          # Install dependencies
flutter run              # Run in development
flutter build apk        # Android
flutter build ios        # iOS (requires macOS)
flutter build macos      # macOS desktop
flutter test             # Run tests
flutter analyze          # Static analysis
dart format lib/         # Format code
```

### Backend Server

```bash
cd server
npm install
export OPENAI_API_KEY=<your_key>   # Required
export FUB_API_KEY=<fub_key>       # Required for CRM features
node server.js                      # Starts on port 3000
```

For local development, update `lib/config.dart`:
```dart
// static final serverUrl = kIsWeb ? '' : 'https://roadmate-flutter.onrender.com';
static final serverUrl = kIsWeb ? '' : 'http://10.0.0.219:3000'; // local test
```

---

## Voice Interaction Flow

```
User speaks
    ↓ microphone audio track (WebRTC)
OpenAI Realtime API
    ↓ tool_call event (data channel)
_VoiceButtonPageState._handleToolCall()
    ↓ dispatches to _tools map
Tool handler (lib/services/ or inline)
    ↓ function_call_output event (data channel)
OpenAI Realtime API
    ↓ audio track (WebRTC)
User hears response
```

1. **Connection**: App establishes a WebRTC peer connection via `/v1/realtime/calls` using an ephemeral token from the backend `/token` endpoint.
2. **Audio**: Microphone is added as a local audio track. Assistant audio is received via `onTrack`.
3. **Data channel** (`oai-events`): Bidirectional JSON events for tool calls and session configuration.
4. **Tool calls**: Model emits `conversation.item.create` with `type: function_call`. App executes and responds with `function_call_output`.

### Tool Call Deduplication

OpenAI may emit the same tool call twice (`in_progress` + `completed`). The app:
- Only processes `status: completed` events
- Tracks handled call IDs in `_handledToolCallIds`
- Clears the set on disconnect

---

## Key Files

| File | Responsibility |
|------|---------------|
| `lib/main.dart` | WebRTC connection, tool dispatch, UI |
| `lib/config.dart` | System prompt, tool schemas, app config, preferences |
| `lib/services/` | All tool implementations |
| `lib/ui/` | UI screens |
| `server/server.js` | Express app, route registration |
| `server/followupboss.js` | FUB API proxy routes |
| `server/gmail.js` | Gmail OAuth routes |
| `server/youtube.js` | YouTube OAuth routes |
| `server/google_maps.js` | Geocoding and directions |

---

## Tool System

Tools are defined in `lib/config.dart:Config.tools` as JSON schemas and executed in `lib/main.dart` via the `_tools` map.

### Tool categories

| Category | Tools | Implementation |
|----------|-------|----------------|
| Location | GPS, navigation, traffic ETA | `services/geo_time_tools.dart`, `services/map_navigation.dart` |
| Memory | Long-term fact storage | `services/memory_store.dart` |
| Calendar | Read/write device calendar | `services/calendar.dart` |
| Web Search | OpenAI web search proxy | `services/web_search.dart` |
| Gmail | OAuth email search/read | `services/gmail_client.dart` |
| YouTube | OAuth subscriptions/playback | `services/youtube_client.dart` |
| Reminders | Local notifications | `services/reminders.dart` |
| Phone | Initiate calls | `services/phone_call.dart` |
| CRM (FUB) | Tasks, contacts | `services/fub_client.dart` → server |
| Voice Notes | Record/search voice memos | `services/voice_memory_store.dart` |
| Driving Log | Trip history | `services/driving_log_store.dart` |
| Photos | Search device photos | `services/photo_index_service.dart` |
| Named Places | Save/recall named locations | `services/named_places_store.dart` |

### Adding a New Tool

1. Define the schema in `lib/config.dart:Config.tools`
2. Implement the handler in `lib/services/`
3. Register the mapping in `lib/main.dart:_tools`
4. Update the system prompt if behavior guidance is needed

---

## Follow Up Boss Integration

### Architecture

The server proxies all FUB API calls using a single admin API key set via the `FUB_API_KEY` environment variable. Agent-level scoping is done server-side using `assignedUserId`.

```
Flutter app
    ↓ GET /fub/tasks?agent=Roman+Petrov
server/followupboss.js
    ↓ resolveAgentId("Roman Petrov") → FUB user ID
    ↓ GET api.followupboss.com/v1/tasks?assignedUserId=42
    ↓ server-side date filtering + contact enrichment
Flutter app
    ← { tasks: [...] }
```

### Agent Identity

Each agent identifies themselves during onboarding by selecting their name from `/fub/users`. The name is stored in SharedPreferences and injected into the system prompt:

```
"You are agent Roman Petrov. Always pass agent_name='Roman Petrov'
to fub_get_tasks by default."
```

This means the AI always scopes queries to the correct agent without prompting.

### Server-side filtering

The FUB API silently ignores most filter parameters. All filtering (by date, by completion status) is applied server-side in `followupboss.js`. Only `assignedUserId` is reliably handled by the API.

### Routes

| Route | Description |
|-------|-------------|
| `GET /fub/me` | Returns the API key owner profile |
| `GET /fub/users` | Returns all brokerage users (cached 5 min) |
| `GET /fub/tasks` | Incomplete tasks with contact details |

`/fub/tasks` query params:
- `agent=NAME` — filter by agent (defaults to `me`)
- `dueDate=YYYY-MM-DD` — exact date filter
- `days=N` — upcoming window (default: 30)
- `all=true` — skip date filter

---

## OAuth Flow (Gmail & YouTube)

```
Flutter app → GET /gmail/auth_url?client_id=<id>
Server       → returns Google authorization URL
Flutter app → opens URL in system browser
User         → authorizes in browser
Google       → redirects to server callback
Server       → stores tokens keyed by client_id
Flutter app → API calls with X-Client-Id header
```

Each mobile install generates a unique `client_id` stored in SharedPreferences (`roadmate_client_id`). This isolates OAuth tokens per device/user on the server.

---

## State Management

No external state management library. State is managed with:

| Mechanism | Used for |
|-----------|----------|
| `StatefulWidget` | UI state |
| `SharedPreferences` | Voice preference, client ID, onboarding status, FUB agent identity |
| Local files (`path_provider`) | Memory (`memory.txt`), preferences (`preferences.txt`) |
| Singleton services | `RemindersService.instance`, `PhotoIndexService.instance`, etc. |

---

## System Prompt

`Config.systemPromptTemplate` in `lib/config.dart` contains the AI's personality and behavioral rules. Dynamic values are injected via `_applyPlaceholders()`:

| Placeholder | Replaced with |
|-------------|--------------|
| `{{CURRENT_DATE_READABLE}}` | Current date string |
| `{{FUB_AGENT_LINE}}` | Agent-specific or generic FUB instruction |

User preferences from `preferences.txt` are appended after the base prompt via `buildSystemPromptWithPreferences()`.

---

## WebRTC Setup

- Package: `flutter_webrtc`
- Offer/answer SDP exchange with OpenAI `/v1/realtime/calls`
- Local audio track from device microphone
- Remote audio track received via `onTrack` callback
- Data channel name: `oai-events`

### iOS audio

On iOS, audio output is forced to the loudspeaker on connection:
```dart
Helper.setSpeakerphoneOn(true);
```

---

## Platform Notes

### iOS
- Microphone and calendar permissions declared in `Info.plist`
- Location permission: `NSLocationWhenInUseUsageDescription` + `NSLocationAlwaysUsageDescription`

### Android
- Permissions: `RECORD_AUDIO`, `ACCESS_FINE_LOCATION`, `READ_CALENDAR`, `POST_NOTIFICATIONS`
- Navigation and phone calls via `android_intent_plus`

### macOS / Web
- Fully supported; some features (phone calls, system intents) unavailable
- Web uses relative server URLs (no hardcoded server address)

---

## Backend Deployment

The server is deployed on Render.com. Required environment variables:

| Variable | Purpose |
|----------|---------|
| `OPENAI_API_KEY` | Issues ephemeral tokens, powers web search |
| `FUB_API_KEY` | Follow Up Boss brokerage API key |
| `GOOGLE_CLIENT_ID` | OAuth for Gmail and YouTube |
| `GOOGLE_CLIENT_SECRET` | OAuth for Gmail and YouTube |

### Server routes summary

| Route | File | Purpose |
|-------|------|---------|
| `POST /token` | `server.js` | OpenAI ephemeral key |
| `POST /websearch` | `server.js` | Web search proxy |
| `GET /fub/*` | `followupboss.js` | CRM proxy |
| `GET /gmail/*` | `gmail.js` | Gmail OAuth + API |
| `GET /youtube/*` | `youtube.js` | YouTube OAuth + API |
| `GET /maps/*` | `google_maps.js` | Geocoding + directions |

---

## Configuration Reference

All client-side configuration lives in `lib/config.dart`:

| Constant | Purpose |
|----------|---------|
| `Config.model` | OpenAI model ID |
| `Config.voice` | Current TTS voice (`marin` / `echo`) |
| `Config.serverUrl` | Backend URL |
| `Config.fubAgentName` | In-memory FUB agent name |
| `Config.tools` | Tool schema list passed to OpenAI |
| `Config.systemPromptTemplate` | Base system prompt with placeholders |
