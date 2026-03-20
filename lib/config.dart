import 'dart:math';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/geo_time_tools.dart';
import 'services/memory_store.dart';


class Config {
  static const String systemPromptTemplate = '''
Realtime voice assistant for users on the go.

Personality: warm, witty, quick, conversational.
Language: mirror user (default: US English).
Responses: <5s; stop on user audio (barge-in).
Tools: use when faster/accurate; summarize output.

Memory (CRITICAL):
- ALWAYS call memory_fetch FIRST before asking for phone numbers, addresses, contacts, or personal info
- Never ask for info that could be in memory without checking
- Only ask user if not in memory
- Save with memory_append when requested

Voice Notes vs Memory:
- memory_append/fetch = short facts
- save_voice_note = longer stories (auto-captures location/time)
- search_voice_notes = search by text/location/time

Photos: search_photos by location/time. Reply with just "Here are X photos" — no descriptions, no locations, no lists. Thumbnails show all details.
WebSearch: for up-to-date/verifiable facts only. Use open_url to open any link the user asks to visit.

Calendar (syncs to Google): create_calendar_event = new events only. To change existing: get_calendar_data first (get event_id) → update_calendar_event. To remove: delete_calendar_event.
Reminders (local notifications only, no calendar sync): reminder_create.
Rule: other person or named event → calendar. Personal nudge → reminder.

Reminders:
- One-shot: "Remind me at 3pm to call dentist" → reminder_create with text + when_iso
- Daily: "Remind me every morning at 7am to drink water" → recurrence='daily'
- Weekly: "Remind me every Monday at 8am" → recurrence='weekly', day_of_week=1
- AI content: "Send me an inspiring quote every day at 6am" → recurrence='daily', ai_prompt='inspiring quote, 1-2 sentences', text='Morning quote'
- AI + style: "Inspiring quote every Monday at 8am in style of Jensen Huang" → recurrence='weekly', day_of_week=1, ai_prompt='inspiring quote in style of Jensen Huang, 1-2 sentences', text='Monday inspiration'

Date: {{CURRENT_DATE_READABLE}}
''';

  static const String model = "gpt-realtime-mini-2025-12-15";

  static const String maleVoice = "echo"; // default male voice
  static const String femaleVoice = "marin"; // default female voice 
  static const List<String> supportedVoices = [femaleVoice, maleVoice];
  static bool get isMaleVoice => voice == maleVoice;
  static bool get isFemaleVoice => voice == femaleVoice;
  static String voice = femaleVoice;

  // Our server URL and preference keys
  static const serverUrl = "https://roadmate-flutter.onrender.com";
  // static const serverUrl = "http://10.0.0.219:3000"; // local test   
  static const prefKeyClientId = 'roadmate_client_id';
  static const prefKeyVoice = 'roadmate_voice';
  static const prefKeyInitialGreetingEnabled = 'roadmate_initial_greeting_enabled';
  static const prefKeyInitialGreetingPhrase = 'roadmate_initial_greeting_phrase';

  /// Read saved voice from SharedPreferences (call during app startup).
  static Future<void> loadSavedVoice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(prefKeyVoice);
      if (saved != null && supportedVoices.contains(saved)) {
        voice = saved;
      }
    } catch (_) {
      // Keep default voice if prefs are unavailable.
    }
  }

  /// Persist and update current voice selection.
  static Future<void> setVoice(String newVoice) async {
    if (!supportedVoices.contains(newVoice)) return;
    voice = newVoice;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefKeyVoice, newVoice);
    } catch (_) {
      // Ignore persistence errors; voice stays updated for this session.
    }
  }

  /// Get whether initial greeting is enabled (default: false)
  static Future<bool> getInitialGreetingEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(prefKeyInitialGreetingEnabled) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Set whether initial greeting is enabled
  static Future<void> setInitialGreetingEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKeyInitialGreetingEnabled, enabled);
    } catch (_) {
      // Ignore persistence errors
    }
  }

  /// Get the initial greeting phrase (default: "Hello, how can I help you?")
  static Future<String> getInitialGreetingPhrase() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(prefKeyInitialGreetingPhrase) ?? "Hello, how can I help you?";
    } catch (_) {
      return "Hello, how can I help you?";
    }
  }

  /// Set the initial greeting phrase
  static Future<void> setInitialGreetingPhrase(String phrase) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefKeyInitialGreetingPhrase, phrase);
    } catch (_) {
      // Ignore persistence errors
    }
  }

  /// Build the system prompt with the current readable date
  static String buildSystemPrompt() {
    return systemPromptTemplate.replaceAll('{{CURRENT_DATE_READABLE}}', getCurrentReadableDate());
  }

  /// Build the system prompt with current readable date + user preferences (preferences.txt).
  /// Preferences are optional and may be empty.
  static Future<String> buildSystemPromptWithPreferences() async {
    final base = systemPromptTemplate.replaceAll(
      '{{CURRENT_DATE_READABLE}}',
      getCurrentReadableDate(),
    );

    // Read local preferences file (may be empty / missing).
    final prefs = await PreferencesStore.readAll();

    // Safety: avoid injecting unbounded text into the system prompt.
    const maxChars = 5000;
    final trimmedPrefs = prefs.length > maxChars ? prefs.substring(0, maxChars) : prefs;

    if (trimmedPrefs.trim().isEmpty) return base;

    return '''$base

User Preferences:
$trimmedPrefs''';
  }


  // Tool definitions exposed to the Realtime model.
  // The model may call these by name; your app must execute them and send back
  // a `function_call_output` event with the returned JSON.
  static const List<Map<String, dynamic>> tools = [
    // location related tool
    {
      "type": "function",
      "name": "get_current_location",
      "description": "Get current GPS location.",
      "parameters": {"type": "object", "properties": {}}
    },
    // memory related tools
    {
      "type": "function",
      "name": "memory_append",
      "description": "Save a fact to long-term memory.",
      "parameters": {
        "type": "object",
        "properties": {
          "text": {"type": "string", "description": "Fact to remember."}
        },
        "required": ["text"]
      }
    },
    {
      "type": "function",
      "name": "memory_fetch",
      "description": "Fetch all long-term memory. Use automatically before asking for phone numbers, addresses, contacts, or personal info.",
      "parameters": {"type": "object", "properties": {}}
    },
    // calendar related tools
    {
      "type": "function",
      "name": "get_calendar_data",
      "description": "Fetch calendar events. If the user asks about a specific date or range, pass start_date and end_date (ISO 8601, e.g. '2026-03-19'). If omitted, defaults to 7 days back and 7 days forward.",
      "parameters": {
        "type": "object",
        "properties": {
          "start_date": {
            "type": "string",
            "description": "Start of the date range (ISO 8601, e.g. '2026-03-19'). Defaults to 7 days ago."
          },
          "end_date": {
            "type": "string",
            "description": "End of the date range (ISO 8601, e.g. '2026-03-25'). Defaults to 7 days from now."
          }
        }
      }
    },
    // time and date
    {
      "type": "function",
      "name": "get_current_time",
      "description": "Get current local date and time.",
      "parameters": {"type": "object", "properties": {}}
    },
    // web search tool
    {
      "type": "function",
      "name": "web_search",
      "description": "Search web for up-to-date info.",
      "parameters": {
        "type": "object",
        "properties": {"query": {"type": "string"}},
        "required": ["query"]
      }
    },
    {
      "type": "function",
      "name": "open_url",
      "description": "Open a URL in the device's default browser. Use when the user asks to open, visit, or follow a link mentioned in conversation.",
      "parameters": {
        "type": "object",
        "properties": {
          "url": {
            "type": "string",
            "description": "The full URL to open, including https://"
          }
        },
        "required": ["url"]
      }
    },
    // gmail tools
    {
      "type": "function",
      "name": "gmail_search",
      "description": "Search Gmail. Returns from/subject/date/snippet.",
      "parameters": {
        "type": "object",
        "properties": {
          "text": { "type": "string", "description": "Keywords to search for." },
          "from": { "type": "string", "description": "Sender name or email (optional)." },
          "subject": { "type": "string", "description": "Subject keywords (optional)." },
          "unread_only": { "type": "boolean", "description": "If true, only unread emails." },
          "in_inbox": { "type": "boolean", "description": "If true, search inbox only." },
          "newer_than_days": { "type": "integer", "minimum": 1, "maximum": 365, "description": "Limit to recent emails." },
          "max_results": { "type": "integer", "minimum": 1, "maximum": 10, "description": "How many emails to return." }
        },
        "required": []
      }
    },
    {
      "type": "function",
      "name": "gmail_read_email",
      "description": "Read full email by ID.",
      "parameters": {
        "type": "object",
        "properties": {
          "message_id": { "type": "string", "description": "Unique message id." }
        },
        "required": ["message_id"]
      }
    },
    // traffic ETA tool
    {
      "type": "function",
      "name": "traffic_eta",
      "description": "Get ETA and traffic to destination.",
      "parameters": {
        "type": "object",
        "properties": {
          "destination": {
            "type": "string",
            "description":
                "Destination address",
          },
          "route_type": {
            "type": "string",
            "enum": ["by_car", "on_foot"],
            "description": "Route type, defaults to by_car.",
            "default": "by_car",
          },
          "units": {
            "type": "string",
            "enum": ["metric", "imperial"],
            "description": "Distance units, defaults to imperial.",
            "default": "imperial",
          },
        },
        "required": ["destination"],
      }
    },
    // navigation using existing maps apps
    {
      "type": "function",
      "name": "navigate_to_destination",
      "description": "Open Maps app with route to destination.",
      "parameters": {
        "type": "object",
        "properties": {
          "destination": {
            "type": "string",
            "description": "Destination address.",
          },
          "route_type": {
            "type": "string",
            "enum": ["by_car", "on_foot"],
            "default": "by_car",
          },
          "nav_app": {
            "type": "string",
            "enum": ["system", "apple", "google", "waze"],
            "description": "Which navigation app to open. system=platform default.",
            "default": "system"
          },
        },
        "required": ["destination"],
      }
    },
  // phone call tool
    {
      "type": "function",
      "name": "call_phone",
      "description": "Place call. MUST call memory_fetch first if only contact name provided.",
      "parameters": {
        "type": "object",
        "properties": {
          "phone_number": {
            "type": "string",
            "description": "Phone number, e.g. +14085551234",
          },
          "contact_name": {
            "type": "string",
            "description": "Contact name",
          },
        },
        "required": ["contact_name", "phone_number"],
      },
    },
    // ---------------- Reminders tools ----------------
    {
      "type": "function",
      "name": "reminder_create",
      "description": "Create a reminder with a local notification. Supports one-shot, recurring (daily/weekly), and AI-generated content. For recurring: set recurrence='daily' or 'weekly' (+ day_of_week for weekly). For AI-generated content: set ai_prompt with the instruction; text becomes a short label.",
      "parameters": {
        "type": "object",
        "properties": {
          "text": {
            "type": "string",
            "description": "What to remind the user about. For AI reminders, this is a short human-readable label (e.g. 'Morning inspiration')."
          },
          "when_iso": {
            "type": "string",
            "description": "Local date/time in ISO 8601 format, e.g. 2026-01-28T07:00:00. For recurring reminders this sets the time-of-day."
          },
          "recurrence": {
            "type": "string",
            "enum": ["daily", "weekly"],
            "description": "How often to repeat. Omit for a one-time reminder."
          },
          "day_of_week": {
            "type": "integer",
            "description": "Day of week for weekly recurrence: 1=Monday, 2=Tuesday, ..., 7=Sunday."
          },
          "ai_prompt": {
            "type": "string",
            "description": "If provided, AI generates the notification content at fire time using this instruction. Example: 'inspiring quote in style of Jensen Huang, 1-2 sentences'. Android only; iOS falls back to text label."
          }
        },
        "required": ["when_iso"]
      },
    },
    {
      "type": "function",
      "name": "reminder_list",
      "description": "List upcoming reminders.",
      "parameters": {"type": "object", "properties": {}}
    },
    {
      "type": "function",
      "name": "reminder_cancel",
      "description": "Cancel reminder by ID.",
      "parameters": {
        "type": "object",
        "properties": {
          "id": {
            "type": "integer",
            "description": "Reminder id returned when the reminder was created."
          }
        },
        "required": ["id"]
      },
    },    
    /// YouTube tools
    {
      "type": "function",
      "name": "youtube_subscriptions_feed",
      "description": "Get latest videos from YouTube subscriptions.",
      "parameters": {"type": "object", "properties": {}}
    },
    {
      "type": "function",
      "name": "youtube_open_video",
      "description": "Open a YouTube video.",
      "parameters": {
        "type": "object",
        "properties": {
          "url": {
            "type": "string",
            "description": "video URL"
          },
          "startSeconds": {
            "type": "integer",
            "description": "Optional start time in seconds. Defaults to 0."
          }
        },
        "required": ["url"]
      }
    },
    // Photo album search tool
    {
      "type": "function",
      "name": "search_photos",
      "description": "Search photos by location/time.",
      "parameters": {
        "type": "object",
        "properties": {
          "location": {
            "type": "string",
            "description": "Location name or address to search for (e.g., 'San Francisco', 'Paris', 'home')"
          },
          "time_period": {
            "type": "string",
            "description": "Time period description (e.g., 'last week', 'yesterday', 'January 2024', 'last summer')"
          },
          "limit": {
            "type": "integer",
            "description": "Maximum number of photos to return (default: 10)"
          }
        }
      }
    },
    {
      "type": "function",
      "name": "rebuild_photo_index",
      "description": "Rebuild the photo index from scratch. Use when the user says photos are missing or the index seems outdated.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    },
    // Voice note tools (separate from memory_append/memory_fetch)
    {
      "type": "function",
      "name": "save_voice_note",
      "description": "Save story/narrative (auto-captures location/time).",
      "parameters": {
        "type": "object",
        "properties": {
          "text": {
            "type": "string",
            "description": "The narrative or story text to save as a voice note."
          }
        },
        "required": ["text"]
      }
    },
    {
      "type": "function",
      "name": "search_voice_notes",
      "description": "Search voice notes by text/location/time.",
      "parameters": {
        "type": "object",
        "properties": {
          "text": {
            "type": "string",
            "description": "Keywords to search for in note content."
          },
          "location": {
            "type": "string",
            "description": "Location name or address to filter by."
          },
          "time_period": {
            "type": "string",
            "description": "Time period (e.g., 'today', 'last week', 'last month')."
          },
          "limit": {
            "type": "integer",
            "description": "Maximum number of notes to return (default: 5)."
          }
        }
      }
    },
    {
      "type": "function",
      "name": "send_whatsapp_message",
      "description": "Send WhatsApp message (contact must be in memory). Can include one or more photos.",
      "parameters": {
        "type": "object",
        "properties": {
          "contact_name": {
            "type": "string",
            "description": "Name of the contact (will be looked up in memory)"
          },
          "message": {
            "type": "string",
            "description": "Text message to send"
          },
          "photo_location": {
            "type": "string",
            "description": "Optional: location to find photo(s) (e.g., 'Paris', 'home')"
          },
          "photo_time": {
            "type": "string",
            "description": "Optional: time period (e.g., 'yesterday', 'last week')"
          },
          "photo_limit": {
            "type": "integer",
            "description": "Optional: number of photos to include (default: 1, max: 10). Use when user says 'send 3 photos' or 'send a few photos'."
          },
          "include_sender_name": {
            "type": "boolean",
            "description": "If true, prepend 'From [Your Name]:' to message"
          },
          "screenshot_path": {
            "type": "string",
            "description": "Optional: file path returned by take_screenshot. Use when the user wants to send a screenshot."
          }
        },
        "required": ["contact_name", "message"]
      }
    },
    {
      "type": "function",
      "name": "take_screenshot",
      "description": "Take a screenshot of the current phone screen and save it as a PNG file. Returns the file path. Call this first, then pass the path to send_whatsapp_message via screenshot_path when the user asks to screenshot and send. Android only — requires Accessibility Service enabled.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    },
    // App voice control tools (Android only) — disabled, kept for future use
    // {
    //   "type": "function",
    //   "name": "tap_ui_button",
    //   "description": "Tap a button in the currently active foreground app by its visible text label.",
    //   ...
    // },
    // {
    //   "type": "function",
    //   "name": "get_foreground_app",
    //   "description": "Get the currently active foreground app and what's visible on screen.",
    //   ...
    // },
    // {
    //   "type": "function",
    //   "name": "launch_app",
    //   "description": "Open/launch an app on the device by name.",
    //   ...
    // },
    // {
    //   "type": "function",
    //   "name": "type_text",
    //   "description": "Type text into an editable text field in the currently active foreground app.",
    //   ...
    // },
    {
      "type": "function",
      "name": "get_driving_log",
      "description": "Get recent driving events (trip starts and parks) with location and time. Use when the user asks about recent drives, where they parked, or trip history.",
      "parameters": {
        "type": "object",
        "properties": {
          "limit": {
            "type": "integer",
            "description": "Maximum number of events to return (default 10, max 50)."
          }
        }
      }
    },
    {
      "type": "function",
      "name": "get_place_visits",
      "description": "Get recent place visits — locations where the user spent 10+ minutes. Use when the user asks 'where have I been today?', 'where did I spend most time this week?', 'did I go to work yesterday?', or wants to review their daily locations.",
      "parameters": {
        "type": "object",
        "properties": {
          "limit": {
            "type": "integer",
            "description": "Maximum number of visits to return (default 10, max 50)."
          }
        }
      }
    },
    {
      "type": "function",
      "name": "save_named_place",
      "description": "Save the user's current location with a name (e.g. 'Home', 'Work', 'Gym'). Call this when the user says 'save this as my home', 'remember this place as work', 'this is my gym', etc. The location is auto-detected from GPS.",
      "parameters": {
        "type": "object",
        "properties": {
          "label": {
            "type": "string",
            "description": "Name for this place, e.g. 'Home', 'Work', 'Gym', 'Mom\\'s house'."
          }
        },
        "required": ["label"]
      }
    }
  ];



  // Deprecated or currently unused tool definitions.
  static const List<Map<String, dynamic>> notUsedTools = [
    // calendar event management tools
    {
      "type": "function",
      "name": "create_calendar_event",
      "description": "Create a NEW calendar event that does not exist yet. For modifying an existing event use update_calendar_event instead. Use calendar_id from writable_calendars in get_calendar_data response.",
      "parameters": {
        "type": "object",
        "properties": {
          "title": {
            "type": "string",
            "description": "Event title"
          },
          "start": {
            "type": "string",
            "description": "Start date and time in ISO 8601 format"
          },
          "end": {
            "type": "string",
            "description": "End date and time in ISO 8601 format (optional, defaults to 1 hour after start)"
          },
          "description": {
            "type": "string",
            "description": "Event description (optional)"
          },
          "location": {
            "type": "string",
            "description": "Event location (optional)"
          },
          "calendar_id": {
            "type": "string",
            "description": "ID of the calendar to create the event in (optional). Use writable_calendars from get_calendar_data to find the right ID."
          }
        },
        "required": ["title", "start"]
      }
    },
    {
      "type": "function",
      "name": "update_calendar_event",
      "description": "Update an existing calendar event. Verbally confirm the change with the user before calling. Always prefer event_id from a prior get_calendar_data call — only fall back to title + start_date if event_id is unavailable.",
      "parameters": {
        "type": "object",
        "properties": {
          "event_id": {
            "type": "string",
            "description": "Event ID to update. Use this when you already know the ID from a prior get_calendar_data call."
          },
          "title": {
            "type": "string",
            "description": "Current event title, used to find the event (required if event_id not provided)."
          },
          "start_date": {
            "type": "string",
            "description": "Current start date (ISO 8601) to help find the event (required if event_id not provided)."
          },
          "new_title": {
            "type": "string",
            "description": "New title to rename the event to (optional)."
          },
          "start": {
            "type": "string",
            "description": "New start date and time (ISO 8601, optional)."
          },
          "end": {
            "type": "string",
            "description": "New end date and time (ISO 8601, optional)."
          },
          "description": {
            "type": "string",
            "description": "New event description (optional)."
          },
          "location": {
            "type": "string",
            "description": "New event location (optional)."
          }
        },
        "required": []
      }
    },
    {
      "type": "function",
      "name": "delete_calendar_event",
      "description": "Delete a calendar event. Verbally confirm with the user before calling. Always prefer event_id from a prior get_calendar_data call — only fall back to title + start_date if event_id is unavailable.",
      "parameters": {
        "type": "object",
        "properties": {
          "event_id": {
            "type": "string",
            "description": "Event ID to delete. Use this when you already know the ID from a prior get_calendar_data call."
          },
          "title": {
            "type": "string",
            "description": "Event title to search for (required if event_id not provided)."
          },
          "start_date": {
            "type": "string",
            "description": "Start date (ISO 8601, required if event_id not provided)."
          }
        },
        "required": []
      }
    },
  ];
}

/// Persistent per-install client id used for server-side token partitioning (Gmail, etc.).
/// No extra deps: uses Random.secure + base64url.
class ClientIdStore {
  static Future<String> getOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(Config.prefKeyClientId);
    if (existing != null && existing.isNotEmpty) return existing;

    // 16 bytes -> 22 chars base64url without padding (roughly)
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    final cid = base64UrlEncode(bytes).replaceAll('=', '');

    await prefs.setString(Config.prefKeyClientId, cid);
    return cid;
  }
}