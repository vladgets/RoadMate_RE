# RoadMate

**RoadMate** is a hands-free AI voice assistant built for real estate agents — designed to be used safely while driving between showings, client meetings, and the office.

Real estate agents spend hours in the car every day. RoadMate turns that windshield time into productive time: check your CRM tasks, review your schedule, respond to leads, and navigate to your next showing — all by voice, without touching your phone.

---

## Who It's For

Real estate agents and brokerages who want to:
- Stay on top of Follow Up Boss tasks and leads while driving
- Handle emails, calendar, and reminders hands-free
- Reduce the time between a lead appearing and a first contact
- Eliminate the distraction of checking a phone at the wheel

---

## Core Capabilities

### CRM Integration (Follow Up Boss)
Ask about your tasks, overdue follow-ups, and today's client list. RoadMate fetches your assigned tasks and reads them aloud with contact details — name, phone, email, address — so you can act immediately.

> *"What do I need to do today?"*
> *"Who do I need to follow up with this week?"*

Each agent in a brokerage identifies themselves during onboarding. RoadMate scopes all CRM queries to that agent automatically.

### Navigation & Traffic
Get real-time traffic conditions and open turn-by-turn navigation to any address — including client addresses pulled directly from your CRM.

> *"Navigate to my next client."*
> *"What's the traffic like to the office?"*

### Calendar & Schedule
Read and create calendar events synced with Google Calendar. Know what's coming up without ever unlocking your phone.

> *"What's on my calendar this afternoon?"*
> *"Schedule a showing at 123 Main Street tomorrow at 2pm."*

### Email (Gmail)
Search and read emails by voice. Useful for quickly checking if a client responded before you pull up to their driveway.

> *"Do I have any emails from Sarah?"*
> *"Read my latest unread emails."*

### Reminders
Set voice reminders that fire as local notifications — no calendar sync required.

> *"Remind me in 30 minutes to call the listing agent."*
> *"Set a daily reminder at 8am to check my leads."*

### Memory
Tell RoadMate facts to remember across sessions — client preferences, property notes, personal context.

> *"Remember that John Smith prefers the north side of town."*
> *"What do you know about the Millers?"*

### Web Search
Ask factual questions or look up current information on the fly.

> *"What's the current mortgage rate?"*
> *"Search for open houses in Westside this weekend."*

### Phone Calls
Initiate calls to contacts by name. RoadMate resolves the contact and dials.

> *"Call my client Mike Johnson."*

---

## How It Works

RoadMate uses a direct **WebRTC voice connection** to OpenAI's Realtime API — audio goes straight from your microphone to the model and back, with near-zero latency. There is no push-to-talk; the assistant listens continuously and you can interrupt it mid-sentence.

When the assistant needs real-world data (your tasks, your calendar, your location), it calls tools that run locally on the device or via the RoadMate backend server. Results are spoken back in a natural, concise summary.

```
You (voice)
    ↓ WebRTC audio
OpenAI Realtime API
    ↓ tool call
RoadMate app / server
    ↓ result
OpenAI Realtime API
    ↓ WebRTC audio
You (spoken response)
```

The backend server handles OAuth tokens (Gmail, YouTube), Follow Up Boss API proxying, and ephemeral OpenAI key issuance. It runs on Render.com and requires no setup from agents.

---

## Agent Onboarding

On first launch, agents:
1. Grant device permissions (microphone required; location, calendar, notifications optional)
2. Select their name from the brokerage's FUB user list — this scopes all CRM data to them
3. Start talking

Identity can be changed at any time under **Settings → CRM Identity**.

---

## Platform Support

| Platform | Status |
|----------|--------|
| iOS | Primary |
| Android | Primary |
| macOS | Supported |
| Web | Supported |

---

## Brokerage Setup

RoadMate is configured per brokerage by setting a Follow Up Boss API key on the backend server. Agents do not need to manage API keys themselves — they simply identify themselves by name during onboarding.

See [Technical Architecture](docs/TECHNICAL_ARCHITECTURE.md) for deployment and configuration details.

---

## Documentation

- [Technical Architecture](docs/TECHNICAL_ARCHITECTURE.md) — system design, tool system, WebRTC setup, adding features, deployment
- [Background Driving Detection](docs/BACKGROUND_DRIVING_DETECTION.md)
- [MLS / Spark API Integration](docs/MLS_SPARK_API_INTEGRATION.md)
- [ShowingTime Access](docs/SHOWINGTIME_ACCESS.md)
- [Voice App Control](docs/VOICE_APP_CONTROL.md)
- [Quick Settings Tile](docs/QS_TILE_VOICE_TRIGGER.md)
- [Photo Collage Feature](docs/PHOTO_COLLAGE_FEATURE.md)

---

## License

[Add your license here]
