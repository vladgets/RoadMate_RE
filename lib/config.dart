import 'dart:math';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'services/geo_time_tools.dart';
import 'services/memory_store.dart';


class Config {
  static const String systemPromptTemplate = '''
You are a voice assistant for real estate agents.

Personality: warm, witty, quick, conversational.
Language: mirror user (default: US English).
Responses: <5s; stop on user audio (barge-in).
Session: say a warm goodbye, then call stop_session when user says goodbye/bye/stop/that's all/stop listening or similar.
Tools: use when faster/accurate; summarize output.
Execution: act immediately — do not ask for confirmation before executing. Only pause if a required parameter is genuinely missing or the request is ambiguous (e.g. multiple contacts match). Never say "shall I?" or "do you want me to?" — just do it.

WebSearch: for up-to-date/verifiable facts only. Use open_url to open any link the user asks to visit.

Calendar: create_appointment = schedule a new meeting with a FUB client (syncs to Google Calendar). Always ask who the appointment is with if not already known. To read events: get_calendar_data. To change existing: get_calendar_data first (get event_id) → update_calendar_event. To remove: delete_calendar_event.
Calendar attachments: events may include an attachments array. Use read_drive_file with the file_id to read PDFs, Google Docs, or spreadsheets attached to events.

Reminders:
- One-shot: "Remind me at 3pm to call dentist" → reminder_create with text + when_iso
- Daily: "Remind me every morning at 7am to drink water" → recurrence='daily'
- Weekly: "Remind me every Monday at 8am" → recurrence='weekly', day_of_week=1

FUB CRM: {{FUB_AGENT_LINE}}
FUB IDs: agent_id (your identity as an agent) and person_id (a contact's ID) are DIFFERENT ID spaces. NEVER use agent_id as person_id.
FUB contacts: person_id comes ONLY from fub_search_contacts, fub_get_tasks, or fub_get_recent_contacts results. If you don't have it, call fub_search_contacts first — never guess or reuse the agent ID.
Once person_id is resolved, remember it for the rest of the conversation.
{{LAST_CLIENT_LINE}}
fub_update_person: use whenever the user says "update", "change", "set", "add a phone/email/address", or "move to [stage]". Examples: "update John's address", "change Sarah's phone", "move to Hot Lead" → always fub_update_person, never fub_create_note.
fub_create_note: only for free-text observations the user explicitly wants logged for a given client.
Confirmations: when the user says "yes", "go ahead", "do it", or similar — execute ONLY the single action proposed in your immediately preceding response. Never infer or execute additional unrelated actions from prior context.

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

  /// FUB account subdomain — used to build deep links into the FUB mobile app.
  /// Format: https://{fubSubdomain}.followupboss.com/2/people/view/{personId}
  static const fubSubdomain = 'newjerseyresidence';

  static const prefKeyClientId = 'roadmate_client_id';
  static const prefKeyVoice = 'roadmate_voice';
  static const prefKeyFubAgentName = 'fub_agent_name';
  static const prefKeyFubAgentId = 'fub_agent_id';
  static const prefKeyLastClientId = 'fub_last_client_id';
  static const prefKeyLastClientName = 'fub_last_client_name';
  static const prefKeyLastClientTs = 'fub_last_client_ts';

  /// Currently identified FUB agent name (in-memory, loaded at startup).
  static String? fubAgentName;

  /// Currently identified FUB agent ID (in-memory, loaded at startup).
  static int? fubAgentId;

  /// Last resolved FUB contact (in-memory, loaded at startup).
  static String? lastClientName;
  static int? lastClientId;
  static int? lastClientTs; // Unix milliseconds

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

  /// Load the last resolved FUB client from SharedPreferences.
  static Future<void> loadLastClient() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      lastClientName = prefs.getString(prefKeyLastClientName);
      lastClientId = prefs.getInt(prefKeyLastClientId);
      lastClientTs = prefs.getInt(prefKeyLastClientTs);
    } catch (_) {}
  }

  /// Persist the last resolved FUB client and update in-memory values.
  static Future<void> setLastClient(String name, int id) async {
    lastClientName = name;
    lastClientId = id;
    lastClientTs = DateTime.now().millisecondsSinceEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefKeyLastClientName, name);
      await prefs.setInt(prefKeyLastClientId, id);
      await prefs.setInt(prefKeyLastClientTs, lastClientTs!);
    } catch (_) {}
  }

  /// Returns the FUB CRM instruction line based on whether an agent is identified.
  static String _fubAgentLine() {
    if (fubAgentName != null && fubAgentName!.isNotEmpty) {
      return "You are agent $fubAgentName. Always pass agent_name='$fubAgentName' to all fub_ tools. Only omit agent_name when the user explicitly asks for the whole team.";
    }
    return "agent_name is required for all fub_ tools. Use 'me' unless the user specifies a different agent or the whole team.";
  }

  /// Returns a system prompt hint about the last active client if within 1 hour,
  /// empty string otherwise.
  static String _lastClientLine() {
    if (lastClientId == null || lastClientName == null || lastClientTs == null) return '';
    final ageMs = DateTime.now().millisecondsSinceEpoch - lastClientTs!;
    if (ageMs > 3600000) return ''; // older than 1 hour — ignore
    final ageMin = (ageMs / 60000).round();
    return "Recent client from previous session: $lastClientName (person_id=$lastClientId, ~${ageMin}m ago). "
        "Use this person_id directly if the user refers to this client without asking to search.";
  }

  static String _applyPlaceholders(String template) {
    final lastClientLine = _lastClientLine();
    return template
        .replaceAll('{{CURRENT_DATE_READABLE}}', getCurrentReadableDate())
        .replaceAll('{{FUB_AGENT_LINE}}', _fubAgentLine())
        .replaceAll(
          '{{LAST_CLIENT_LINE}}',
          lastClientLine.isNotEmpty ? '$lastClientLine\n' : '',
        );
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
    {
      "type": "function",
      "name": "create_appointment",
      "description": "Create a new appointment in FUB CRM linked to a client. FUB syncs it to Google Calendar. Always use this for scheduling meetings — never create_calendar_event. Requires a client (person_id or client_name). If neither is known, ask the user who the appointment is with before calling.",
      "parameters": {
        "type": "object",
        "properties": {
          "title": {
            "type": "string",
            "description": "Appointment title."
          },
          "start": {
            "type": "string",
            "description": "Start date and time (ISO 8601)."
          },
          "location": {
            "type": "string",
            "description": "Meeting location."
          },
          "end": {
            "type": "string",
            "description": "End date and time (ISO 8601). Defaults to 30 minutes after start."
          },
          "description": {
            "type": "string",
            "description": "Optional notes or agenda."
          },
          "person_id": {
            "type": "integer",
            "description": "FUB contact ID (preferred, from fub_search_contacts)."
          },
          "client_name": {
            "type": "string",
            "description": "Client name to resolve (fallback if person_id unavailable)."
          },
          "agent_name": {
            "type": "string",
            "description": "Agent name or 'me'. Always pass the current agent."
          }
        },
        "required": ["title", "start", "location"]
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
      "description": "Open a URL in the browser.",
      "parameters": {
        "type": "object",
        "properties": {
          "url": {
            "type": "string",
            "description": "Full URL including https://"
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
      "description": "Read a Google Drive file (PDF/Doc/Sheet) attached to a calendar event.",
      "parameters": {
        "type": "object",
        "properties": {
          "file_id": {
            "type": "string",
            "description": "Drive file ID from the calendar event attachment."
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
      "description": "Place a call. For FUB contacts pass person_id — opens FUB app with calling ready. For others pass phone_number for native dialer.",
      "parameters": {
        "type": "object",
        "properties": {
          "phone_number": {
            "type": "string",
            "description": "Phone number e.g. +14085551234. Required when person_id unavailable.",
          },
          "contact_name": {
            "type": "string",
            "description": "Contact name.",
          },
          "person_id": {
            "type": "integer",
            "description": "FUB contact ID — opens FUB app for calling with transcription.",
          },
        },
        "required": ["contact_name"],
      },
    },
    // ---------------- Reminders tools ----------------
    {
      "type": "function",
      "name": "reminder_create",
      "description": "Create a reminder. For recurring: recurrence='daily'/'weekly' + day_of_week. For AI content at fire time: set ai_prompt.",
      "parameters": {
        "type": "object",
        "properties": {
          "text": {
            "type": "string",
            "description": "Reminder label. For AI reminders, a short label (e.g. 'Morning inspiration')."
          },
          "when_iso": {
            "type": "string",
            "description": "ISO 8601 datetime, e.g. 2026-01-28T07:00:00."
          },
          "recurrence": {
            "type": "string",
            "enum": ["daily", "weekly"],
            "description": "Omit for one-time."
          },
          "day_of_week": {
            "type": "integer",
            "description": "1=Mon … 7=Sun. Required for weekly."
          },
          "ai_prompt": {
            "type": "string",
            "description": "Instruction to generate notification content at fire time (Android only)."
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
      "description": "Send WhatsApp message (contact must be in memory). Can include photos.",
      "parameters": {
        "type": "object",
        "properties": {
          "contact_name": {
            "type": "string",
            "description": "Contact name (looked up in memory)."
          },
          "message": {
            "type": "string",
            "description": "Text message."
          },
          "photo_location": {
            "type": "string",
            "description": "Location to find photos (e.g. 'Paris')."
          },
          "photo_time": {
            "type": "string",
            "description": "Time period for photos (e.g. 'yesterday')."
          },
          "photo_limit": {
            "type": "integer",
            "description": "Number of photos (default 1, max 10)."
          },
          "include_sender_name": {
            "type": "boolean",
            "description": "Prepend 'From [Name]:' to message."
          },
        },
        "required": ["contact_name", "message"]
      }
    },
    {
      "type": "function",
      "name": "stop_session",
      "description": "End the voice session.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    },

    // Follow Up Boss CRM tools
    {
      "type": "function",
      "name": "fub_create_task",
      "description": "Create a task for a FUB contact ('add a task', 'follow up', 'schedule a call'). Pass person_id when already resolved.",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent name or 'me'."
          },
          "person_id": {
            "type": "number",
            "description": "FUB contact ID (not agent_id)."
          },
          "client_name": {
            "type": "string",
            "description": "Partial name; only when person_id unknown."
          },
          "description": {
            "type": "string",
            "description": "Task description / title."
          },
          "due_date": {
            "type": "string",
            "description": "YYYY-MM-DD. Defaults to today."
          },
          "task_type": {
            "type": "string",
            "enum": ["Follow Up", "Call", "Email", "Text", "Showing", "Closing", "Open House", "Thank You"],
            "description": "Task type."
          }
        },
        "required": ["agent_name", "description", "task_type"]
      }
    },
    {
      "type": "function",
      "name": "fub_update_task",
      "description": "Edit or complete/reopen a FUB task. task_id from fub_get_person_tasks.",
      "parameters": {
        "type": "object",
        "properties": {
          "task_id": {
            "type": "number",
            "description": "Task ID from fub_get_person_tasks."
          },
          "is_completed": {
            "type": "boolean",
            "description": "true=complete, false=reopen."
          },
          "description": {
            "type": "string",
            "description": "New description. Omit if unchanged."
          },
          "due_date": {
            "type": "string",
            "description": "New due date YYYY-MM-DD. Omit if unchanged."
          },
          "task_type": {
            "type": "string",
            "enum": ["Follow Up", "Call", "Email", "Text", "Showing", "Closing", "Open House", "Thank You"],
            "description": "New type. Omit if unchanged."
          }
        },
        "required": ["task_id"]
      }
    },
    {
      "type": "function",
      "name": "fub_get_person_tasks",
      "description": "Fetch tasks for a FUB contact. Pass person_id when already resolved.",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent name or 'me'."
          },
          "person_id": {
            "type": "number",
            "description": "FUB contact ID (not agent_id)."
          },
          "client_name": {
            "type": "string",
            "description": "Partial name; only when person_id unknown."
          },
          "status": {
            "type": "string",
            "enum": ["open", "completed", "all"],
            "description": "Defaults to 'all'."
          }
        },
        "required": ["agent_name"]
      }
    },
    {
      "type": "function",
      "name": "fub_get_tasks",
      "description": "Get agent's incomplete tasks with contact details. For 'today's tasks' pass due_date. Group overdue vs upcoming in response.",
      "parameters": {
        "type": "object",
        "properties": {
          "due_date": {
            "type": "string",
            "description": "YYYY-MM-DD. Omit for all tasks."
          },
          "agent_name": {
            "type": "string",
            "description": "Agent name or 'me'. 'all' for whole team."
          }
        },
        "required": ["agent_name"]
      }
    },
    {
      "type": "function",
      "name": "fub_search_contacts",
      "description": "Search FUB contacts by name. Returns id (=person_id) — store and reuse it.",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent name or 'me'."
          },
          "query": {
            "type": "string",
            "description": "Partial or full name."
          },
          "limit": {
            "type": "number",
            "description": "Max results (default 10)."
          }
        },
        "required": ["agent_name", "query"]
      }
    },
    {
      "type": "function",
      "name": "fub_create_note",
      "description": "Log a note on a FUB contact timeline. ONLY for 'add a note'/'log that' — not for field updates (those go to fub_update_person).",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent name or 'me'."
          },
          "body": {
            "type": "string",
            "description": "Note content."
          },
          "person_id": {
            "type": "number",
            "description": "FUB contact ID (not agent_id)."
          },
          "client_name": {
            "type": "string",
            "description": "Partial name; only when person_id unknown."
          }
        },
        "required": ["agent_name", "body"]
      }
    },
    {
      "type": "function",
      "name": "fub_open_contact",
      "description": "Open a FUB contact page in the app ('open', 'pull up', 'show me' a client).",
      "parameters": {
        "type": "object",
        "properties": {
          "person_id": {
            "type": "integer",
            "description": "FUB contact ID (not agent_id).",
          },
          "contact_name": {
            "type": "string",
            "description": "Contact name for response confirmation.",
          },
        },
        "required": ["person_id"],
      },
    },
    {
      "type": "function",
      "name": "fub_send_text",
      "description": "Send a text to a FUB client. Prefer person_id when already resolved.",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent name or 'me'."
          },
          "message": {
            "type": "string",
            "description": "Text message."
          },
          "person_id": {
            "type": "number",
            "description": "FUB contact ID (not agent_id)."
          },
          "client_name": {
            "type": "string",
            "description": "Partial name; only when person_id unknown."
          }
        },
        "required": ["agent_name", "message"]
      }
    },
    {
      "type": "function",
      "name": "fub_get_stages",
      "description": "List FUB lead stages. Call before updating stage if name uncertain.",
      "parameters": {
        "type": "object",
        "properties": {},
        "required": []
      }
    },
    {
      "type": "function",
      "name": "fub_get_lenders",
      "description": "List FUB lenders. Use when asked about lenders ('who are the lenders', 'known lenders', 'list lenders') or before assigning one.",
      "parameters": {
        "type": "object",
        "properties": {},
        "required": []
      }
    },
    {
      "type": "function",
      "name": "fub_update_person",
      "description": "Update FUB contact fields: stage, tags, phones, emails, address, name, background, source, lender, assigned agent, collaborators. Pass person_id when resolved. Call fub_get_stages before updating stage, fub_get_lenders before assigning lender, fub_get_sources before updating source — only if name is uncertain.",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent name or 'me'."
          },
          "person_id": {
            "type": "number",
            "description": "FUB contact ID (not agent_id)."
          },
          "client_name": {
            "type": "string",
            "description": "Partial name; only when person_id unknown."
          },
          "stage": {
            "type": "string",
            "description": "Stage name — call fub_get_stages if unsure."
          },
          "name": {
            "type": "string",
            "description": "Full name."
          },
          "background_info": {
            "type": "string",
            "description": "Background / bio text."
          },
          "source": {
            "type": "string",
            "description": "Lead source — call fub_get_sources if unsure."
          },
          "lender": {
            "type": "string",
            "description": "Lender name — call fub_get_lenders if unsure. Empty string to remove."
          },
          "assigned_to": {
            "type": "string",
            "description": "Agent name to assign contact to."
          },
          "collaborators": {
            "type": "object",
            "description": "mode: add/remove/set. agents: list of names.",
            "properties": {
              "mode": {"type": "string", "enum": ["add", "remove", "set"]},
              "agents": {"type": "array", "items": {"type": "string"}}
            },
            "required": ["mode", "agents"]
          },
          "tags": {
            "type": "object",
            "description": "mode: add/remove/set. values: list of tag strings.",
            "properties": {
              "mode": {"type": "string", "enum": ["add", "remove", "set"]},
              "values": {"type": "array", "items": {"type": "string"}}
            },
            "required": ["mode", "values"]
          },
          "phones": {
            "type": "array",
            "description": "Phone changes. Each: {number, type, action}. action omit/'set' to add; 'remove' to delete.",
            "items": {
              "type": "object",
              "properties": {
                "number": {"type": "string"},
                "type": {"type": "string", "enum": ["mobile", "home", "work", "fax", "other"]},
                "action": {"type": "string", "enum": ["set", "remove"]}
              },
              "required": ["type"]
            }
          },
          "emails": {
            "type": "array",
            "description": "Email changes. Each: {address, type, action}.",
            "items": {
              "type": "object",
              "properties": {
                "address": {"type": "string"},
                "type": {"type": "string", "enum": ["personal", "work", "other"]},
                "action": {"type": "string", "enum": ["set", "remove"]}
              },
              "required": ["type"]
            }
          },
          "address": {
            "type": "object",
            "description": "Address. type: home/work/selling/other. action: set/remove.",
            "properties": {
              "street": {"type": "string"},
              "city": {"type": "string"},
              "state": {"type": "string"},
              "zip": {"type": "string"},
              "country": {"type": "string"},
              "type": {"type": "string", "enum": ["home", "work", "selling", "other"]},
              "action": {"type": "string", "enum": ["set", "remove"]}
            }
          }
        },
        "required": ["agent_name"]
      }
    },
    {
      "type": "function",
      "name": "fub_get_recent_contacts",
      "description": "Get agent's most recently active FUB contacts. Include lastActivityDate in response.",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent name or 'me'. 'all' for whole team."
          },
          "limit": {
            "type": "number",
            "description": "Number to return (default 5)."
          },
          "days": {
            "type": "number",
            "description": "Only contacts active within last N days."
          }
        },
        "required": ["agent_name"]
      }
    },
    {
      "type": "function",
      "name": "fub_get_person_details",
      "description": "Read FUB contact fields: tags, background, source, stage, lender, collaborators.",
      "parameters": {
        "type": "object",
        "properties": {
          "agent_name": {
            "type": "string",
            "description": "Agent name or 'me'."
          },
          "person_id": {
            "type": "number",
            "description": "FUB contact ID (not agent_id)."
          },
          "client_name": {
            "type": "string",
            "description": "Partial name; only when person_id unknown."
          }
        },
        "required": ["agent_name"]
      }
    },
    {
      "type": "function",
      "name": "fub_get_sources",
      "description": "List FUB lead sources. Call before updating source if name uncertain.",
      "parameters": {
        "type": "object",
        "properties": {},
        "required": []
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
      "description": "Update an existing calendar event. Execute immediately. Always prefer event_id from a prior get_calendar_data call — only fall back to title + start_date if event_id is unavailable.",
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
      "description": "Delete a calendar event. Execute immediately. Always prefer event_id from a prior get_calendar_data call — only fall back to title + start_date if event_id is unavailable.",
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