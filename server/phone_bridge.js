import { WebSocketServer } from "ws";
import WebSocket from "ws";
import fs from "fs";

const INTERNAL = "http://localhost:3000"; // server always binds on 3000
const PHONE_REG_FILE = "/data/phone_registrations.json";
const PHONE_MEMORY_DIR = "/data/phone_memory";

// ── Phone registration storage ────────────────────────────────────────────────

function loadRegistrations() {
  try {
    if (fs.existsSync(PHONE_REG_FILE)) return JSON.parse(fs.readFileSync(PHONE_REG_FILE, "utf8"));
  } catch {}
  return {};
}

function saveRegistrations(data) {
  fs.mkdirSync("/data", { recursive: true });
  fs.writeFileSync(PHONE_REG_FILE, JSON.stringify(data, null, 2), "utf8");
}

function lookupRegistration(phoneNumber) {
  if (!phoneNumber) return null;
  const entry = loadRegistrations()[phoneNumber];
  if (!entry) return null;
  // Support both old string format and new object format
  if (typeof entry === "string") return { client_id: entry, agent_name: null };
  return entry;
}

function lookupClientId(phoneNumber) {
  return lookupRegistration(phoneNumber)?.client_id || null;
}

// ── Server-side memory (per clientId) ────────────────────────────────────────

function memoryPath(clientId) {
  fs.mkdirSync(PHONE_MEMORY_DIR, { recursive: true });
  return `${PHONE_MEMORY_DIR}/${clientId || "anonymous"}.txt`;
}

function memoryFetch(clientId) {
  try {
    const p = memoryPath(clientId);
    return fs.existsSync(p) ? fs.readFileSync(p, "utf8") : "";
  } catch { return ""; }
}

function memoryAppend(clientId, text) {
  fs.appendFileSync(memoryPath(clientId), `\n[${new Date().toISOString()}] ${text}`, "utf8");
}

// ── System prompt matching lib/config.dart ────────────────────────────────────

function buildSystemPrompt(callerInfo = {}) {
  const dateStr = new Date().toLocaleDateString("en-US", {
    weekday: "long", year: "numeric", month: "long", day: "numeric",
  });

  const fubAgentLine = callerInfo.fubAgentName
    ? `You are agent ${callerInfo.fubAgentName}. Always pass agent_name='${callerInfo.fubAgentName}' to all fub_ tools. Only omit agent_name when the user explicitly asks for the whole team.`
    : "agent_name is required for all fub_ tools. Use 'me' unless the user specifies a different agent or the whole team.";

  const userIdentityLine = callerInfo.fubAgentName
    ? `You are speaking with name: ${callerInfo.fubAgentName}.\n`
    : "";

  return `You are a voice assistant for real estate agents. Warm, witty, quick. Mirror user's language (default English). Responses under 5s; stop on barge-in. Summarize tool output.
Session: warm goodbye + stop_session on goodbye/bye/stop/that's all.
Execution: act immediately, no confirmation. Pause only if a required param is missing or genuinely ambiguous. Never "shall I?" — just do it.
Confirmations: "yes/go ahead/do it" → execute only the single action from your last response, nothing else.

Calendar: create_appointment for new FUB client meetings (ask who it's with if unknown). get_calendar_data to read; fetch event_id first before update/delete.
WebSearch: up-to-date/verifiable facts only.

FUB CRM: ${fubAgentLine}
person_id ≠ agent_id — never substitute. person_id comes only from fub_search_contacts/fub_get_tasks/fub_get_recent_contacts; never guess.
fub_update_person: "update/change/set/add phone|email|address/move to [stage]" on a contact. fub_create_note: explicit free-text observations only.

Feedback: submit_feedback immediately on "feedback/suggestion/report a problem".

Date: ${dateStr}
${userIdentityLine}`;
}

// ── Phone-capable tool definitions (subset of lib/config.dart) ────────────────

const PHONE_TOOLS = [
  { type: "function", name: "get_current_time", description: "Get current local date and time.", parameters: { type: "object", properties: {} } },
  { type: "function", name: "web_search", description: "Search web for up-to-date info.", parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] } },
  { type: "function", name: "memory_fetch", description: "Fetch all long-term memory. Use automatically before asking for phone numbers, addresses, contacts, or personal info.", parameters: { type: "object", properties: {} } },
  { type: "function", name: "memory_append", description: "Save a fact to long-term memory.", parameters: { type: "object", properties: { text: { type: "string", description: "Fact to remember." } }, required: ["text"] } },
  {
    type: "function", name: "get_calendar_data",
    description: "Fetch calendar events. Pass start_date and end_date (ISO 8601) for a specific range; defaults to 7 days back and forward.",
    parameters: { type: "object", properties: { start_date: { type: "string" }, end_date: { type: "string" } } }
  },
  {
    type: "function", name: "create_appointment",
    description: "Create a new appointment in FUB CRM linked to a client. Requires a client (person_id or client_name).",
    parameters: {
      type: "object",
      properties: {
        title: { type: "string" }, start: { type: "string", description: "ISO 8601" },
        location: { type: "string" }, end: { type: "string" }, description: { type: "string" },
        person_id: { type: "integer" }, client_name: { type: "string" }, agent_name: { type: "string" }
      },
      required: ["title", "start", "location"]
    }
  },
  {
    type: "function", name: "traffic_eta",
    description: "Get ETA and traffic to destination.",
    parameters: {
      type: "object",
      properties: {
        destination: { type: "string" },
        route_type: { type: "string", enum: ["by_car", "on_foot"], default: "by_car" },
        units: { type: "string", enum: ["metric", "imperial"], default: "imperial" }
      },
      required: ["destination"]
    }
  },
  {
    type: "function", name: "gmail_search",
    description: "Search Gmail. Returns from/subject/date/snippet.",
    parameters: {
      type: "object",
      properties: {
        text: { type: "string" }, from: { type: "string" }, subject: { type: "string" },
        unread_only: { type: "boolean" }, in_inbox: { type: "boolean" },
        newer_than_days: { type: "integer", minimum: 1, maximum: 365 },
        max_results: { type: "integer", minimum: 1, maximum: 10 }
      }
    }
  },
  {
    type: "function", name: "gmail_read_email",
    description: "Read full email by ID.",
    parameters: { type: "object", properties: { message_id: { type: "string" } }, required: ["message_id"] }
  },
  {
    type: "function", name: "gmail_send_email",
    description: "Send an email via Gmail. Defaults to user's own address if 'to' is omitted.",
    parameters: {
      type: "object",
      properties: {
        subject: { type: "string" }, body: { type: "string" }, to: { type: "string" },
        attachment_text: { type: "string" }, attachment_filename: { type: "string" }
      },
      required: ["subject", "body"]
    }
  },
  {
    type: "function", name: "fub_search_contacts",
    description: "Search FUB contacts by name.",
    parameters: { type: "object", properties: { agent_name: { type: "string" }, query: { type: "string" }, limit: { type: "number" } }, required: ["agent_name", "query"] }
  },
  {
    type: "function", name: "fub_get_tasks",
    description: "Get agent's incomplete tasks with contact details.",
    parameters: { type: "object", properties: { due_date: { type: "string" }, agent_name: { type: "string" } }, required: ["agent_name"] }
  },
  {
    type: "function", name: "fub_get_person_tasks",
    description: "Fetch tasks for a FUB contact.",
    parameters: { type: "object", properties: { agent_name: { type: "string" }, person_id: { type: "number" }, client_name: { type: "string" }, status: { type: "string", enum: ["open", "completed", "all"] } }, required: ["agent_name"] }
  },
  {
    type: "function", name: "fub_create_task",
    description: "Create a task for a FUB contact.",
    parameters: {
      type: "object",
      properties: {
        agent_name: { type: "string" }, person_id: { type: "number" }, client_name: { type: "string" },
        description: { type: "string" }, due_date: { type: "string" },
        task_type: { type: "string", enum: ["Follow Up", "Call", "Email", "Text", "Showing", "Closing", "Open House", "Thank You"] }
      },
      required: ["agent_name", "description", "task_type"]
    }
  },
  {
    type: "function", name: "fub_update_task",
    description: "Edit or complete/reopen a FUB task.",
    parameters: {
      type: "object",
      properties: {
        task_id: { type: "number" }, is_completed: { type: "boolean" },
        description: { type: "string" }, due_date: { type: "string" },
        task_type: { type: "string", enum: ["Follow Up", "Call", "Email", "Text", "Showing", "Closing", "Open House", "Thank You"] }
      },
      required: ["task_id"]
    }
  },
  {
    type: "function", name: "fub_create_note",
    description: "Log a note on a FUB contact timeline.",
    parameters: { type: "object", properties: { agent_name: { type: "string" }, body: { type: "string" }, person_id: { type: "number" }, client_name: { type: "string" } }, required: ["agent_name", "body"] }
  },
  {
    type: "function", name: "fub_update_person",
    description: "Update FUB contact fields: stage, tags, phones, emails, address, name, background, source, lender.",
    parameters: {
      type: "object",
      properties: {
        agent_name: { type: "string" }, person_id: { type: "number" }, client_name: { type: "string" },
        stage: { type: "string" }, name: { type: "string" }, background_info: { type: "string" },
        source: { type: "string" }, lender: { type: "string" }, assigned_to: { type: "string" },
        collaborators: {
          type: "object",
          properties: {
            mode: { type: "string", enum: ["add", "remove", "set"] },
            agents: { type: "array", items: { type: "string" } }
          },
          required: ["mode", "agents"]
        },
        tags: {
          type: "object",
          properties: {
            mode: { type: "string", enum: ["add", "remove", "set"] },
            values: { type: "array", items: { type: "string" } }
          },
          required: ["mode", "values"]
        },
        phones: {
          type: "array",
          items: {
            type: "object",
            properties: {
              number: { type: "string" },
              type: { type: "string", enum: ["mobile", "home", "work", "fax", "other"] },
              action: { type: "string", enum: ["set", "remove"] }
            },
            required: ["type"]
          }
        },
        emails: {
          type: "array",
          items: {
            type: "object",
            properties: {
              address: { type: "string" },
              type: { type: "string", enum: ["personal", "work", "other"] },
              action: { type: "string", enum: ["set", "remove"] }
            },
            required: ["type"]
          }
        },
        address: {
          type: "object",
          properties: {
            street: { type: "string" }, city: { type: "string" }, state: { type: "string" },
            zip: { type: "string" }, country: { type: "string" },
            type: { type: "string", enum: ["home", "work", "selling", "other"] },
            action: { type: "string", enum: ["set", "remove"] }
          }
        }
      },
      required: ["agent_name"]
    }
  },
  {
    type: "function", name: "fub_get_person_details",
    description: "Read FUB contact fields: tags, background, source, stage, lender, collaborators.",
    parameters: { type: "object", properties: { agent_name: { type: "string" }, person_id: { type: "number" }, client_name: { type: "string" } }, required: ["agent_name"] }
  },
  {
    type: "function", name: "fub_get_recent_contacts",
    description: "Get agent's most recently active FUB contacts.",
    parameters: { type: "object", properties: { agent_name: { type: "string" }, limit: { type: "number" }, days: { type: "number" } }, required: ["agent_name"] }
  },
  { type: "function", name: "fub_get_stages", description: "List FUB lead stages.", parameters: { type: "object", properties: {} } },
  { type: "function", name: "fub_get_lenders", description: "List FUB lenders.", parameters: { type: "object", properties: {} } },
  { type: "function", name: "fub_get_sources", description: "List FUB lead sources.", parameters: { type: "object", properties: {} } },
  {
    type: "function", name: "submit_feedback",
    description: "Submit user feedback about the app.",
    parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"] }
  },
  { type: "function", name: "stop_session", description: "End the voice session.", parameters: { type: "object", properties: {} } },
];

// ── Internal HTTP helper ───────────────────────────────────────────────────────

async function internalPost(path, body, clientId) {
  const headers = { "Content-Type": "application/json" };
  if (clientId) headers["X-Client-Id"] = clientId;
  const r = await fetch(`${INTERNAL}${path}`, { method: "POST", headers, body: JSON.stringify(body) });
  return r.json().catch(() => ({ ok: false, error: "parse error" }));
}

async function internalGet(path, params = {}, clientId) {
  const headers = {};
  if (clientId) headers["X-Client-Id"] = clientId;
  const q = new URLSearchParams(
    Object.fromEntries(Object.entries({ ...params, ...(clientId ? { client_id: clientId } : {}) }).filter(([, v]) => v != null))
  );
  const url = `${INTERNAL}${path}${q.toString() ? "?" + q : ""}`;
  const r = await fetch(url, { headers });
  return r.json().catch(() => ({ ok: false, error: "parse error" }));
}

// ── Tool execution ─────────────────────────────────────────────────────────────

async function executeTool(name, args, context) {
  const { clientId } = context;

  switch (name) {
    case "get_current_time":
      return { time: new Date().toLocaleString("en-US", { timeZone: "America/New_York", dateStyle: "full", timeStyle: "short" }) };

    case "web_search":
      return internalPost("/websearch", { query: args.query }, null);

    case "memory_fetch":
      return { memory: memoryFetch(clientId) || "(empty)" };

    case "memory_append":
      memoryAppend(clientId, args.text);
      return { ok: true };

    case "get_calendar_data":
      return internalGet("/calendar/events", { start_date: args.start_date, end_date: args.end_date }, clientId);

    case "create_appointment":
      return internalPost("/fub/appointment", args, clientId);

    case "traffic_eta":
      return internalPost("/traffic_eta", args, clientId);

    case "gmail_search":
      return internalPost("/gmail/search_structured", args, clientId);

    case "gmail_read_email":
      return internalGet("/gmail/read_full", { id: args.message_id }, clientId);

    case "gmail_send_email":
      return internalPost("/gmail/send", args, clientId);

    case "fub_search_contacts":
      return internalGet("/fub/contacts/search", { search: args.query, limit: args.limit || 10, agent_name: args.agent_name }, clientId);

    case "fub_get_tasks":
      return internalGet("/fub/tasks", { agent_name: args.agent_name, due_date: args.due_date }, clientId);

    case "fub_get_person_tasks":
      return internalGet("/fub/person-tasks", { agent_name: args.agent_name, person_id: args.person_id, client_name: args.client_name, status: args.status }, clientId);

    case "fub_create_task":
      return internalPost("/fub/task", args, clientId);

    case "fub_update_task":
      return internalPost(`/fub/task/${args.task_id}`, args, clientId);

    case "fub_create_note":
      return internalPost("/fub/note", args, clientId);

    case "fub_update_person":
      return internalPost("/fub/contact/update", args, clientId);

    case "fub_get_person_details":
      return internalGet("/fub/contact/details", { person_id: args.person_id, client_name: args.client_name, agent_name: args.agent_name }, clientId);

    case "fub_get_recent_contacts":
      return internalGet("/fub/contacts/recent", { agent_name: args.agent_name, limit: args.limit, days: args.days }, clientId);

    case "fub_get_stages":
      return internalGet("/fub/stages", {}, clientId);

    case "fub_get_lenders":
      return internalGet("/fub/lenders", {}, clientId);

    case "fub_get_sources":
      return internalGet("/fub/sources", {}, clientId);

    case "submit_feedback":
      return internalPost("/feedback", { text: args.text, source: "phone_call" }, null);

    case "stop_session":
      context.stopRequested = true;
      return { ok: true };

    default:
      return { error: `Tool '${name}' is not available on phone calls.` };
  }
}

// ── Call handler ───────────────────────────────────────────────────────────────

async function handleCall(twilioWs) {
  const OPENAI_API_KEY = process.env.OPENAI_API_KEY;

  // Both OpenAI "open" and Twilio "start" must fire before we configure the session.
  // Either can arrive first — maybeConfigureSession() checks both gates.
  let streamSid = null;
  let callerPhone = null;   // set when Twilio "start" arrives
  let openaiReady = false;  // set when OpenAI WS opens
  let sessionConfigured = false;
  const pendingAudio = [];
  const pendingToolCalls = new Map();
  const context = { clientId: null, stopRequested: false };

  // Transcript collection for conversation logging
  const sessionStart = new Date().toISOString();
  const transcript = []; // { id, role, content, timestamp }
  let msgSeq = 0;
  function addTranscriptMsg(role, content) {
    if (!content?.trim()) return;
    transcript.push({ id: `phone_${++msgSeq}`, role, content: content.trim(), timestamp: new Date().toISOString() });
  }

  async function saveTranscript() {
    if (!context.clientId) {
      console.log("[phone] Transcript skipped — no client_id (unregistered caller)");
      return;
    }
    if (transcript.length === 0) {
      console.log("[phone] Transcript skipped — no messages collected");
      return;
    }
    try {
      const reg = lookupRegistration(callerPhone);
      await internalPost("/conversation/save", {
        client_id: context.clientId,
        platform: "phone",
        agent_name: reg?.agent_name || null,
        location: callerPhone ? `📞 ${callerPhone}` : null,
        session_start: sessionStart,
        messages: transcript,
      }, null);
      console.log(`[phone] Transcript saved: ${transcript.length} messages`);
    } catch (e) {
      console.error("[phone] Failed to save transcript:", e.message);
    }
  }

  const openaiWs = new WebSocket(
    "wss://api.openai.com/v1/realtime?model=gpt-realtime-mini-2025-12-15",
    {
      headers: {
        Authorization: `Bearer ${OPENAI_API_KEY}`,
        "OpenAI-Beta": "realtime=v1",
      },
    }
  );

  function maybeConfigureSession() {
    // Wait until both OpenAI is open AND we have the caller phone from Twilio "start"
    if (!openaiReady || sessionConfigured || callerPhone === null) return;
    sessionConfigured = true;

    const clientId = lookupClientId(callerPhone);
    context.clientId = clientId;
    const callerInfo = loadCallerInfo(callerPhone);

    console.log(`[phone] ${clientId
      ? `Caller identified: ${callerPhone} → client_id=${clientId}, agent: ${callerInfo.fubAgentName || "unknown"}`
      : `Unknown caller: ${callerPhone} — no client_id registered`}`);

    openaiWs.send(JSON.stringify({
      type: "session.update",
      session: {
        turn_detection: { type: "server_vad" },
        input_audio_format: "g711_ulaw",
        output_audio_format: "g711_ulaw",
        voice: "marin",
        instructions: buildSystemPrompt(callerInfo),
        modalities: ["text", "audio"],
        tools: PHONE_TOOLS,
        input_audio_transcription: { model: "whisper-1" },
      },
    }));

    // Trigger the AI to speak its greeting — the system prompt already says to greet the user
    const greetInstruction = callerInfo.fubAgentName
      ? `Greet ${callerInfo.fubAgentName} by name. Say you're RoadMate and ask how you can help.`
      : "Greet the caller warmly. Say you're RoadMate and ask how you can help.";

    openaiWs.send(JSON.stringify({
      type: "response.create",
      response: { modalities: ["text", "audio"], instructions: greetInstruction },
    }));

    for (const payload of pendingAudio) {
      openaiWs.send(JSON.stringify({ type: "input_audio_buffer.append", audio: payload }));
    }
    pendingAudio.length = 0;
  }

  openaiWs.on("open", () => {
    console.log("[phone] Connected to OpenAI Realtime");
    openaiReady = true;
    maybeConfigureSession();
  });

  // Twilio → OpenAI
  twilioWs.on("message", (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }

    if (msg.event === "start") {
      streamSid = msg.start.streamSid;
      // Caller's number arrives here via the <Parameter name="from"> in TwiML
      callerPhone = msg.start.customParameters?.from || "";
      console.log(`[phone] Stream started: ${streamSid}, caller: ${callerPhone || "unknown"}`);
      maybeConfigureSession();
    }

    if (msg.event === "media") {
      if (openaiReady) {
        openaiWs.send(JSON.stringify({ type: "input_audio_buffer.append", audio: msg.media.payload }));
      } else {
        pendingAudio.push(msg.media.payload);
      }
    }

    if (msg.event === "stop") {
      console.log("[phone] Stream stopped");
      openaiWs.close();
    }
  });

  // OpenAI → Twilio
  openaiWs.on("message", async (raw) => {
    let event;
    try { event = JSON.parse(raw); } catch { return; }

    // Audio → send back to caller
    if (event.type === "response.audio.delta" && event.delta && streamSid) {
      twilioWs.send(JSON.stringify({
        event: "media",
        streamSid,
        media: { payload: event.delta },
      }));
    }

    // Accumulate tool call arguments (streamed in deltas)
    if (event.type === "response.function_call_arguments.delta") {
      const existing = pendingToolCalls.get(event.call_id) || { name: event.name || "", args: "" };
      existing.args += event.delta || "";
      pendingToolCalls.set(event.call_id, existing);
    }

    // Tool call name arrives in response.output_item.added for function items
    if (event.type === "response.output_item.added" && event.item?.type === "function_call") {
      pendingToolCalls.set(event.item.call_id, { name: event.item.name, args: "" });
    }

    // Execute tool when arguments are complete
    if (event.type === "response.function_call_arguments.done") {
      const callId = event.call_id;
      const pending = pendingToolCalls.get(callId);
      const name = pending?.name || event.name || "";
      let args = {};
      try { args = JSON.parse(event.arguments || pending?.args || "{}"); } catch {}

      console.log(`[phone] Tool call: ${name}`, args);
      pendingToolCalls.delete(callId);

      let result;
      try {
        result = await executeTool(name, args, context);
      } catch (e) {
        result = { error: String(e) };
      }

      console.log(`[phone] Tool result (${name}):`, JSON.stringify(result).slice(0, 200));

      // Return result to OpenAI
      openaiWs.send(JSON.stringify({
        type: "conversation.item.create",
        item: {
          type: "function_call_output",
          call_id: callId,
          output: JSON.stringify(result),
        },
      }));
      openaiWs.send(JSON.stringify({ type: "response.create" }));

      // stop_session closes the call
      if (context.stopRequested) {
        setTimeout(() => twilioWs.close(), 2000);
      }
    }

    // Collect user speech transcription
    if (event.type === "conversation.item.input_audio_transcription.completed") {
      addTranscriptMsg("user", event.transcript);
    }

    // Collect assistant speech transcription (fires once per response turn with full text)
    if (event.type === "response.audio_transcript.done") {
      addTranscriptMsg("assistant", event.transcript);
    }

    if (event.type === "error") {
      console.error("[phone] OpenAI error:", event.error);
    }
  });

  twilioWs.on("close", async () => {
    console.log("[phone] Twilio disconnected");
    await saveTranscript();
    openaiWs.close();
  });

  openaiWs.on("close", () => {
    console.log("[phone] OpenAI disconnected");
    if (twilioWs.readyState === WebSocket.OPEN) twilioWs.close();
  });

  openaiWs.on("error", (err) => console.error("[phone] OpenAI WS error:", err.message));
}

// ── Caller info (from phone registrations) ────────────────────────────────────

function loadCallerInfo(callerPhone) {
  const reg = lookupRegistration(callerPhone);
  if (!reg) return {};
  return { fubAgentName: reg.agent_name || null };
}

// ── Route registration ─────────────────────────────────────────────────────────

export function registerPhoneBridgeRoutes(app, httpServer) {

  // TwiML webhook — Twilio POSTs here when someone dials the number
  app.post("/call/incoming", (req, res) => {
    const host = req.headers.host;
    const from = req.body?.From || "";
    res.type("text/xml");
    // Pass caller's number via <Parameter> — arrives in the "start" WS event
    res.send(`<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Connect>
    <Stream url="wss://${host}/call/stream">
      <Parameter name="from" value="${from}" />
    </Stream>
  </Connect>
</Response>`);
  });

  // Register a phone number → client_id mapping
  // Called from the Flutter app after the user enables phone access
  app.post("/phone/register", (req, res) => {
    const { client_id, phone_number, agent_name } = req.body || {};
    if (!client_id || !phone_number) {
      return res.status(400).json({ ok: false, error: "Missing client_id or phone_number" });
    }
    const clean = phone_number.replace(/\s/g, "");
    const regs = loadRegistrations();
    regs[clean] = { client_id, agent_name: agent_name || null };
    saveRegistrations(regs);
    console.log(`[phone] Registered ${clean} → ${client_id} (${agent_name || "no name"})`);
    return res.json({ ok: true, phone_number: clean, client_id, agent_name: agent_name || null });
  });

  // Get the registered phone number for a client
  app.get("/phone/registered_number", (req, res) => {
    const clientId = req.query.client_id;
    if (!clientId) return res.status(400).json({ ok: false, error: "Missing client_id" });
    const regs = loadRegistrations();
    const entry = Object.entries(regs).find(([, val]) => {
      const cid = typeof val === "string" ? val : val?.client_id;
      return cid === clientId;
    });
    const phone = entry ? entry[0] : null;
    const agentName = entry && typeof entry[1] === "object" ? entry[1].agent_name : null;
    return res.json({ ok: true, phone_number: phone, agent_name: agentName });
  });

  // WebSocket server that Twilio Media Streams connects to
  const wss = new WebSocketServer({ noServer: true });

  httpServer.on("upgrade", (request, socket, head) => {
    if (request.url === "/call/stream") {
      wss.handleUpgrade(request, socket, head, (ws) => {
        wss.emit("connection", ws, request);
      });
    }
  });

  wss.on("connection", (twilioWs) => {
    console.log("[phone] Twilio Media Stream connected");
    handleCall(twilioWs);
  });
}
