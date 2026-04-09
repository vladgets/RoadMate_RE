import 'dart:math';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'services/geo_time_tools.dart';
import 'services/memory_store.dart';


class Config {
  static const String systemPromptTemplate = '''
Realtime voice assistant for users on the go.

Personality: warm, witty, quick, conversational.
Language: mirror user (default: US English).
Responses: <5s; stop on user audio (barge-in).
Session: say a warm goodbye, then call stop_session when user says goodbye/bye/stop/that's all/stop listening or similar.
Tools: use when faster/accurate; summarize output.

Memory (CRITICAL):
- ALWAYS call memory_fetch FIRST before asking for phone numbers, addresses, contacts, or personal info
- Never ask for info that could be in memory without checking
- Only ask user if not in memory
- Save with memory_append when requested

WebSearch: for up-to-date/verifiable facts only. Use open_url to open any link the user asks to visit.

Calendar (syncs to Google): create_calendar_event = new events only. To change existing: get_calendar_data first (get event_id) → update_calendar_event. To remove: delete_calendar_event.
Calendar attachments: events may include an attachments array. Use read_drive_file with the file_id to read PDFs, Google Docs, or spreadsheets attached to events.

Reminders:
- One-shot: "Remind me at 3pm to call dentist" → reminder_create with text + when_iso
- Daily: "Remind me every morning at 7am to drink water" → recurrence='daily'
- Weekly: "Remind me every Monday at 8am" → recurrence='weekly', day_of_week=1

FUB CRM: {{FUB_AGENT_LINE}}
FUB contacts: always use person_id when calling fub_create_note or fub_send_text. If you don't have it yet, call fub_search_contacts first to resolve the client, then use the returned id. 
Never pass client_name alone when you can get the id first. Once resolved, remember person_id for the rest of the conversation.

Date: {{CURRENT_DATE_READABLE}}
''';

  static const String model = "gpt-realtime-mini-2025-12-15";

  static const String maleVoice = "echo"; // default male voice
  static const String femaleVoice = "marin"; // default female voice 
  static const List<String> supportedVoices = [femaleVoice, maleVoice];
  static bool get isMaleVoice => voice == maleVoice;
  static bool get isFemaleVoice => voice == femaleVoice;
  static String voice = femaleVoice;

  // Our server URL and preference keys.
  // On web, use empty string so all API paths are relative to the page origin
  // (works both locally and on Render without rebuilding).
  // On mobile, use the absolute production URL.
  static final serverUrl = kIsWeb ? '' : 'https://roadmate-flutter.onrender.com';
  // static final serverUrl = kIsWeb ? '' : 'http://10.0.0.219:3000'; // local test
  static const prefKeyClientId = 'roadmate_client_id';
  static const prefKeyVoice = 'roadmate_voice';
static const prefKeyFubAgentName = 'fub_agent_name';
  static const prefKeyFubAgentId = 'fub_agent_id';

  /// Currently identified FUB agent name (in-memory, loaded at startup).
  static String? fubAgentName;

  /// Currently identified FUB agent ID (in-memory, loaded at startup).
  static int? fubAgentId;

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

  /// Load the saved FUB agent name from SharedPreferences into [fubAgentName].
  static Future<void> loadFubAgent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      fubAgentName = prefs.getString(prefKeyFubAgentName);
      final savedId = prefs.getInt(prefKeyFubAgentId);
      fubAgentId = savedId;
    } catch (_) {}
  }

  /// Persist the selected FUB agent and update the in-memory value.
  static Future<void> setFubAgent(String name, int id) async {
    fubAgentName = name;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefKeyFubAgentName, name);
      await prefs.setInt(prefKeyFubAgentId, id);
    } catch (_) {}
  }

  /// Clear the stored FUB agent identity.
  static Future<void> clearFubAgent() async {
    fubAgentName = null;
    fubAgentId = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefKeyFubAgentName);
      await prefs.remove(prefKeyFubAgentId);
    } catch (_) {}
  }

  /// Returns the FUB CRM instruction line based on whether an agent is identified.
  static String _fubAgentLine() {
    if (fubAgentName != null && fubAgentName!.isNotEmpty) {
      return "You are agent $fubAgentName. Always pass agent_name='$fubAgentName' to all fub_ tools. Only omit agent_name when the user explicitly asks for the whole team.";
    }
    return "agent_name is required for all fub_ tools. Use 'me' unless the user specifies a different agent or the whole team.";
  }

  static String _applyPlaceholders(String template) {
    return template
        .replaceAll('{{CURRENT_DATE_READABLE}}', getCurrentReadableDate())
        .replaceAll('{{FUB_AGENT_LINE}}', _fubAgentLine());
  }

  /// Build the system prompt with the current readable date
  static String buildSystemPrompt() {
    return _applyPlaceholders(systemPromptTemplate);
  }

  /// Build the system prompt with current readable date + user preferences (preferences.txt).
  /// Preferences are optional and may be empty.
  static Future<String> buildSystemPromptWithPreferences() async {
    final base = _applyPlaceholders(systemPromptTemplate);

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
    {
      "type": "function",
      "name": "read_drive_file",
      "description": "Read the text content of a Google Drive file (PDF, Google Doc, or Google Sheet) attached to a calendar event. Use the file_id from the event's attachments array.",
      "parameters": {
        "type": "object",
        "properties": {
          "file_id": {
            "type": "string",
            "description": "Google Drive file ID from the calendar event attachment."
          }
        },
        "required": ["file_id"]
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
        },
        "required": ["contact_name", "message"]
      }
    },
    {
      "type": "function",
      "name": "stop_session",
      "description": "Stop the voice session and disconnect the microphone. Call this when the user says goodbye, bye, stop listening, that's all, stop, or any similar phrase that signals they want to end the conversation.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    },

    // Follow Up Boss CRM tools
    {
      "type": "function",
      "name": "fub_get_tasks",
      "description": "Get incomplete tasks from Follow Up Boss CRM including contact details (name, phone, email, address). agent_name is required — always pass the agent's name from your identity or 'me'. For 'today's meetings/tasks/clients', pass due_date=today's date in YYYY-MM-DD format. Summarize by grouping overdue vs upcoming.",
      "parameters": {
        "type": "object",
        "properties": {
          "due_date": {
            "type": "string",
            "description": "Filter tasks by due date in YYYY-MM-DD format. Omit to get all tasks."
          },
          "agent_name": {
            "type": "string",
            "description": "Agent to fetch tasks for. Use the agent's name from your identity (e.g. 'Roman') or 'me'. Use 'all' only when user explicitly asks for the whole team's tasks."
          }
        },
        "required": ["agent_name"]
      }
    },
    {
      "type": "function",
      "name": "fub_search_contacts",
      "description": "Search for FUB contacts by partial name (case-insensitive), scoped to the agent. Use when user asks to find or look up a client by name (e.g. 'find all my Johns', 'look up Smith', 'search for William'). Returns full contact details including person id. IMPORTANT: store the returned person_id and use it in all subsequent fub_create_note/fub_send_text calls — do NOT re-resolve or ask the user which client again.",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent whose contacts to search. Use the agent's name from your identity or 'me'."
          },
          "query": {
            "type": "string",
            "description": "Partial or full name to search for. Case-insensitive."
          },
          "limit": {
            "type": "number",
            "description": "Max number of results to return (default 10)."
          }
        },
        "required": ["agent_name", "query"]
      }
    },
    {
      "type": "function",
      "name": "fub_create_note",
      "description": "Create an internal note on a FUB client's timeline on behalf of the agent. Notes are not sent to the client — they are private CRM records. Use when the agent wants to log something about a client (e.g. 'note that John called about pricing'). ALWAYS pass person_id when the client was already resolved in this conversation (from search or task list) — never re-ask the user which client.",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent creating the note. Use the agent's name from your identity (e.g. 'Roman') or 'me'."
          },
          "body": {
            "type": "string",
            "description": "The note content to save."
          },
          "person_id": {
            "type": "number",
            "description": "FUB person ID of the contact. Use this when the contact was already resolved in this conversation."
          },
          "client_name": {
            "type": "string",
            "description": "Full or partial name of the client to look up. Used when person_id is not already known."
          }
        },
        "required": ["agent_name", "body"]
      }
    },
    {
      "type": "function",
      "name": "fub_send_text",
      "description": "Send a text message to a FUB client on behalf of the agent. IMPORTANT: Always read the message back to the user and get explicit confirmation ('yes', 'send it', etc.) before calling this tool — it sends a real message to a real client. Prefer person_id when the client was already resolved in this conversation (from fub_get_recent_contacts or fub_get_tasks). Use client_name when referring to someone by name for the first time.",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent sending the message. Use the agent's name from your identity (e.g. 'Roman') or 'me'."
          },
          "message": {
            "type": "string",
            "description": "The text message to send."
          },
          "person_id": {
            "type": "number",
            "description": "FUB person ID of the recipient. Use this when the contact was already resolved in this conversation."
          },
          "client_name": {
            "type": "string",
            "description": "Full or partial name of the client to look up. Used when person_id is not already known."
          }
        },
        "required": ["agent_name", "message"]
      }
    },
    {
      "type": "function",
      "name": "fub_get_stages",
      "description": "Get all available lead stages from Follow Up Boss CRM. Use when the user asks what stages are available, or before updating a stage to confirm the exact stage name.",
      "parameters": {
        "type": "object",
        "properties": {},
        "required": []
      }
    },
    {
      "type": "function",
      "name": "fub_update_stage",
      "description": "Update the stage of a FUB contact (e.g. 'move John to Hot Lead', 'set RoadMate stage to Active Buyer'). ALWAYS pass person_id when the client was already resolved in this conversation. If you are unsure of the exact stage name, call fub_get_stages first.",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent performing the update. Use the agent's name from your identity or 'me'."
          },
          "stage": {
            "type": "string",
            "description": "The stage name to set (must match exactly a stage from FUB, e.g. 'Hot Lead', 'Active Buyer')."
          },
          "person_id": {
            "type": "number",
            "description": "FUB person ID of the contact. Use this when the contact was already resolved in this conversation."
          },
          "client_name": {
            "type": "string",
            "description": "Full or partial name of the client. Used when person_id is not already known."
          }
        },
        "required": ["agent_name", "stage"]
      }
    },
    {
      "type": "function",
      "name": "fub_get_recent_contacts",
      "description": "Get the most recently contacted clients for an agent from Follow Up Boss CRM, sorted by last activity date with most recent first. Use when the user asks 'who are my latest clients', 'recent contacts', 'who did I work with recently', or similar. Always include lastActivityDate in your response for each contact.",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent whose contacts to fetch. Use the agent's name from your identity (e.g. 'Roman') or 'me'. Use 'all' only when user explicitly asks for the whole team."
          },
          "limit": {
            "type": "number",
            "description": "Number of contacts to return. Default is 5 if not specified by the user."
          },
          "days": {
            "type": "number",
            "description": "Only include contacts active within the last N days. Omit to return the most recent regardless of timeframe."
          }
        },
        "required": ["agent_name"]
      }
    },
    {
      "type": "function",
      "name": "fub_get_tags",
      "description": "Read the tags on a FUB contact. Use when the user asks 'what tags does [client] have', 'show me [client]'s tags', or similar. Returns the current list of tags. ALWAYS pass person_id when the client was already resolved in this conversation.",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent name (e.g. 'Roman') or 'me'. Required to scope contact lookup."
          },
          "person_id": {
            "type": "number",
            "description": "FUB person ID of the contact. Use this when the contact was already resolved in this conversation."
          },
          "client_name": {
            "type": "string",
            "description": "Full or partial name of the client to look up. Used when person_id is not already known."
          }
        },
        "required": ["agent_name"]
      }
    },
    {
      "type": "function",
      "name": "fub_update_tags",
      "description": "Add, remove, or replace tags on a FUB contact. Use when the user says 'add tag [X] to [client]', 'remove tag [X] from [client]', 'set [client]'s tags to [X, Y]', etc. ALWAYS pass person_id when the client was already resolved in this conversation. Confirm with the user before calling when removing all tags (set with empty-ish list).",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent name (e.g. 'Roman') or 'me'. Required to scope contact lookup."
          },
          "mode": {
            "type": "string",
            "enum": ["add", "remove", "set"],
            "description": "'add' appends tags without removing existing ones. 'remove' deletes specific tags. 'set' replaces all tags with the provided list."
          },
          "tags": {
            "type": "array",
            "items": { "type": "string" },
            "description": "List of tag strings to add, remove, or set."
          },
          "person_id": {
            "type": "number",
            "description": "FUB person ID of the contact. Use this when the contact was already resolved in this conversation."
          },
          "client_name": {
            "type": "string",
            "description": "Full or partial name of the client. Used when person_id is not already known."
          }
        },
        "required": ["agent_name", "mode", "tags"]
      }
    },
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