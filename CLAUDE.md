# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RoadMate is a cross-platform Flutter voice assistant app designed for drivers, using OpenAI's Realtime API with WebRTC for real-time voice interaction. The app includes a Node.js backend server that provides ephemeral tokens and OAuth integrations.

## Development Commands

### Flutter App

```bash
# Run the app (development)
flutter run

# Build for specific platforms
flutter build apk          # Android
flutter build ios          # iOS (requires macOS)
flutter build macos        # macOS desktop

# Run tests
flutter test

# Generate app icons
flutter pub run flutter_launcher_icons

# Analyze code
flutter analyze

# Format code
dart format lib/
```

### Backend Server

The Node.js server must be running for the app to function. It provides OpenAI ephemeral tokens and OAuth endpoints.

```bash
cd server
npm install
export OPENAI_API_KEY=<your_key>  # Required
node server.js                     # Starts on port 3000
```

The server is deployed at `https://roadmate-flutter.onrender.com` (see `lib/config.dart`).

## Architecture

### Voice Interaction Flow

1. **Connection**: App establishes WebRTC peer connection via OpenAI Realtime API
2. **Audio**: Microphone input sent directly to OpenAI; assistant audio streamed back
3. **Tool Calls**: OpenAI model calls functions via data channel events
4. **Execution**: App executes tools locally and returns results to continue conversation

Key files:
- `lib/main.dart:68-594` - Main WebRTC connection logic, tool execution, and UI
- `lib/config.dart:1-475` - System prompt, tool definitions, and configuration

### Tool System

Tools are defined in `lib/config.dart:105-356` and executed in `lib/main.dart:380-445`. Each tool:
- Has a schema definition passed to OpenAI
- Maps to a Dart function that returns `Map<String, dynamic>`
- Receives events via data channel (`conversation.item.create` with type `function_call`)
- Returns output via `function_call_output` event

Tool categories:
- **Location**: GPS, navigation, traffic ETA
- **Memory**: Long-term fact storage (local file)
- **Calendar**: Read device calendar events
- **Web Search**: OpenAI web search via `/websearch` endpoint
- **Gmail**: OAuth-based email search and reading
- **YouTube**: OAuth-based subscriptions feed and video playback
- **Reminders**: Local notifications scheduled with `flutter_local_notifications`
- **Phone**: Initiate calls with contact resolution

### Service Layer

All tool implementations live in `lib/services/`:
- `geo_time_tools.dart` - Location, time/date utilities
- `memory_store.dart` - User preferences and long-term memory (local files)
- `calendar.dart` - Device calendar integration
- `web_search.dart` - HTTP client for `/websearch` endpoint
- `gmail_client.dart` - OAuth flow and Gmail API calls via server
- `youtube_client.dart` - OAuth flow and YouTube API calls via server
- `map_navigation.dart` - Open navigation in Maps apps
- `phone_call.dart` - Phone dialer integration
- `reminders.dart` - Local notification scheduling

### Backend Server

`server/server.js` provides:
- `/token` - Issues OpenAI ephemeral keys (requires `OPENAI_API_KEY` env var)
- `/websearch` - Proxies web search requests to OpenAI Responses API
- Gmail OAuth routes (`gmail.js`) - Token storage keyed by client ID
- YouTube OAuth routes (`youtube.js`) - Token storage keyed by client ID
- Google Maps routes (`google_maps.js`) - Geocoding and directions
- User location routes (`user_location.js`) - Firebase push notifications (currently disabled)

Each mobile install generates a unique `client_id` stored in SharedPreferences. This ID is used server-side to isolate OAuth tokens per user.

### State Management

No external state management library. State is managed with:
- `StatefulWidget` for UI state
- `SharedPreferences` for persistence (voice preference, client ID)
- Local files for memory and preferences (`MemoryStore`, `PreferencesStore`)
- Singleton services (e.g., `RemindersService.instance`)

### Configuration

`lib/config.dart` centralizes:
- System prompt template with personality and instructions
- Tool definitions (JSON schemas)
- Model selection (`gpt-realtime-mini-2025-12-15`)
- Voice options (marin, echo)
- Server URL
- Preferences injection into system prompt

When modifying tool behavior, update both the schema in `Config.tools` and the handler in `_tools` map in `main.dart`.

## Key Implementation Details

### WebRTC Setup

- Uses `flutter_webrtc` package
- Offer/answer SDP exchange with OpenAI `/v1/realtime/calls` endpoint
- Microphone audio added as local track
- Assistant audio received via `onTrack` event
- Data channel (`oai-events`) for function calls and session updates

### Tool Call Deduplication

OpenAI may emit duplicate events (e.g., `in_progress` + `completed` with same `call_id`). The app:
- Only processes `status: completed` events
- Tracks handled IDs in `_handledToolCallIds` set
- Clears set on disconnect

### OAuth Flow

Gmail and YouTube use device-based OAuth:
1. Flutter app requests auth URL from server (`/gmail/auth_url` or `/youtube/auth_url`)
2. Server generates state token, returns authorization URL
3. App opens URL in system browser
4. User authorizes, redirected to server callback
5. Server stores tokens keyed by `client_id`
6. App polls or receives confirmation, then makes API calls with `client_id` header

### Memory and Preferences

- **Memory** (`memory.txt`): User-specific facts appended via `memory_append` tool
- **Preferences** (`preferences.txt`): User-editable preferences injected into system prompt
- Both stored in app documents directory via `path_provider`

## Platform-Specific Notes

### iOS
- Requires microphone and calendar permissions in `Info.plist`
- Audio output forced to loudspeaker on connection (`Helper.setSpeakerphoneOn(true)`)

### Android
- Requires permissions: microphone, location, calendar, notifications
- Intent-based navigation and phone calls via `android_intent_plus`

### macOS/Linux/Web
- Desktop platforms supported but primary focus is mobile
- Some features (phone calls, system intents) may not work on desktop

## Common Patterns

### Adding a New Tool

1. Define schema in `lib/config.dart:tools`
2. Implement handler function in `lib/services/`
3. Add mapping in `lib/main.dart:_tools`
4. Update system prompt if needed

### Modifying System Prompt

Edit `Config.systemPromptTemplate` in `lib/config.dart`. Use `{{CURRENT_DATE_READABLE}}` placeholder for dynamic date injection.

### Changing Voice

Voice selection persists in SharedPreferences:
- `Config.voice` - Current voice (default: `marin`)
- `Config.setVoice(newVoice)` - Update and persist
- Supported: `marin` (female), `echo` (male)

### Server Deployment

Server expects:
- `OPENAI_API_KEY` environment variable
- Node.js runtime

Current production deployment: Render.com at `https://roadmate-flutter.onrender.com`
