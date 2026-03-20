# RoadMate

A cross-platform Flutter voice assistant app designed for drivers, powered by OpenAI's Realtime API with WebRTC for real-time voice interaction.

## Features

- **Real-time Voice Interaction**: Direct WebRTC connection to OpenAI for natural conversations
- **Hands-free Operation**: Designed specifically for safe use while driving
- **Rich Tool Integration**:
  - Location & Navigation (GPS, traffic, ETA)
  - Calendar integration
  - Gmail (OAuth-based email search and reading)
  - YouTube (OAuth-based subscriptions and playback)
  - Web search capabilities
  - Reminders with local notifications
  - Phone calls with contact resolution
  - Long-term memory and user preferences
- **Multi-platform**: iOS, Android, macOS, Linux, Web
- **Onboarding Flow**: First-time user tutorial with permission requests

## Quick Start

### Prerequisites

- Flutter SDK
- Node.js (for backend server)
- OpenAI API key

### Backend Server

The Node.js server must be running for the app to function. It provides ephemeral tokens and OAuth endpoints.

```bash
cd server
npm install
export OPENAI_API_KEY=<your_key>  # Required
node server.js                     # Starts on port 3000
```

Production server: `https://roadmate-flutter.onrender.com`

### Flutter App

```bash
# Install dependencies
flutter pub get

# Run the app
flutter run

# Build for specific platforms
flutter build apk          # Android
flutter build ios          # iOS (requires macOS)

# Run tests
flutter test

# Analyze code
flutter analyze
```

## Architecture

### Voice Interaction Flow

1. **Connection**: WebRTC peer connection established via OpenAI Realtime API
2. **Audio Streaming**: Microphone input sent to OpenAI; assistant audio streamed back
3. **Tool Calls**: OpenAI model executes function calls via WebRTC data channel
4. **Local Execution**: App executes tools and returns results to continue conversation

### Key Components

- **`lib/main.dart`**: WebRTC connection logic, tool execution, UI
- **`lib/config.dart`**: System prompt, tool definitions, configuration
- **`lib/services/`**: Tool implementations (location, calendar, Gmail, YouTube, etc.)
- **`lib/ui/`**: UI screens (main app, settings, onboarding)
- **`server/`**: Node.js backend for tokens, OAuth, and API proxying

### Tool System

Tools are defined in `lib/config.dart` with JSON schemas and executed in `lib/main.dart`. Each tool:
- Has a schema passed to OpenAI
- Maps to a Dart function returning `Map<String, dynamic>`
- Receives events via WebRTC data channel
- Returns results to continue the conversation

### State Management

- `StatefulWidget` for UI state
- `SharedPreferences` for persistence (voice preference, client ID, onboarding)
- Local files for memory and preferences
- Singleton services (e.g., `RemindersService.instance`)

## Tech Stack

- **Frontend**: Flutter (Dart)
- **Backend**: Node.js + Express
- **Voice AI**: OpenAI Realtime API (gpt-realtime-mini-2025-12-15)
- **Communication**: WebRTC via `flutter_webrtc`
- **OAuth**: Google APIs (Gmail, YouTube)
- **Notifications**: `flutter_local_notifications`
- **Permissions**: `permission_handler`

## Configuration

Edit `lib/config.dart` to modify:
- System prompt and personality
- Tool definitions
- Voice selection (marin, echo)
- Server URL
- Model selection

## Development

### Adding a New Tool

1. Define schema in `lib/config.dart:tools`
2. Implement handler function in `lib/services/`
3. Add mapping in `lib/main.dart:_tools`
4. Update system prompt if needed

### Permissions

The app requires:
- **Microphone** (required): Voice input
- **Location** (optional): Navigation and traffic
- **Calendar** (optional): Schedule queries
- **Notifications** (optional): Reminders

### OAuth Setup

Gmail and YouTube use device-based OAuth flow:
1. App requests auth URL from server
2. Opens system browser for user authorization
3. Server stores tokens keyed by unique `client_id`
4. App makes API calls with `client_id` header

## Project Structure

```
lib/
├── main.dart                      # App entry point, WebRTC logic
├── config.dart                    # Configuration, tools, prompts
├── services/                      # Tool implementations
│   ├── geo_time_tools.dart       # Location, time/date
│   ├── memory_store.dart         # Long-term memory
│   ├── calendar.dart             # Calendar integration
│   ├── gmail_client.dart         # Gmail OAuth & API
│   ├── youtube_client.dart       # YouTube OAuth & API
│   ├── web_search.dart           # Web search
│   ├── reminders.dart            # Local notifications
│   └── ...
└── ui/                           # User interface screens
    ├── onboarding_screen.dart    # First-time tutorial
    ├── main_settings_menu.dart   # Settings menu
    └── ...

server/
├── server.js                     # Main server
├── gmail.js                      # Gmail OAuth routes
├── youtube.js                    # YouTube OAuth routes
└── ...
```

## License

[Add your license here]

## Contributing

[Add contribution guidelines here]
