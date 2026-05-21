import { WebSocketServer } from "ws";
import WebSocket from "ws";
import twilio from "twilio";

const ET_LOCALE = "en-US";
const ET_TZ = "America/New_York";

// ── Business hours ────────────────────────────────────────────────────────────

// Returns the Nth weekday of a given month (e.g. 3rd Monday = nthWeekday(year, month, 1, 3))
function nthWeekday(year, month, dow, n) {
  // dow: 0=Sun, 1=Mon … 6=Sat; month: 1-based
  const d = new Date(year, month - 1, 1);
  const first = d.getDay();
  let day = 1 + ((dow - first + 7) % 7) + (n - 1) * 7;
  return new Date(year, month - 1, day);
}

// Returns the last occurrence of a weekday in a month
function lastWeekday(year, month, dow) {
  const last = new Date(year, month, 0); // last day of month
  const diff = (last.getDay() - dow + 7) % 7;
  return new Date(year, month - 1, last.getDate() - diff);
}

// Returns observed date: Sat → Fri, Sun → Mon
function observed(date) {
  const dow = date.getDay();
  if (dow === 6) return new Date(date.getFullYear(), date.getMonth(), date.getDate() - 1);
  if (dow === 0) return new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1);
  return date;
}

// Returns Set of "YYYY-MM-DD" strings for US federal holidays in a given year
function usHolidays(year) {
  const fixed = (m, d) => observed(new Date(year, m - 1, d));
  const fmt = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  return new Set([
    fmt(fixed(1, 1)),                        // New Year's Day
    fmt(nthWeekday(year, 1, 1, 3)),          // MLK Day (3rd Mon Jan)
    fmt(nthWeekday(year, 2, 1, 3)),          // Presidents' Day (3rd Mon Feb)
    fmt(lastWeekday(year, 5, 1)),            // Memorial Day (last Mon May)
    fmt(fixed(6, 19)),                       // Juneteenth
    fmt(fixed(7, 4)),                        // Independence Day
    fmt(nthWeekday(year, 9, 1, 1)),          // Labor Day (1st Mon Sep)
    fmt(fixed(11, 11)),                      // Veterans Day
    fmt(nthWeekday(year, 11, 4, 4)),         // Thanksgiving (4th Thu Nov)
    fmt(fixed(12, 25)),                      // Christmas Day
  ]);
}

function isBusinessHours() {
  const now = new Date();
  // Use Intl to get ET date parts
  const etParts = new Intl.DateTimeFormat("en-US", {
    timeZone: ET_TZ, weekday: "short", hour: "numeric", hour12: false,
    year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(now);

  const get = (type) => etParts.find(p => p.type === type)?.value;
  const dayMap = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  const etDay = dayMap[get("weekday")] ?? -1;
  const etHour = Number(get("hour") ?? -1);
  const etDateStr = `${get("year")}-${get("month")}-${get("day")}`;

  if (etDay < 1 || etDay > 5) return false;           // weekend
  if (etHour < 9 || etHour >= 17) return false;       // outside 9am–5pm
  if (usHolidays(Number(get("year"))).has(etDateStr)) return false; // holiday
  return true;
}

// ── System prompt ─────────────────────────────────────────────────────────────

function buildAvaPrompt() {
  const now = new Date();
  const dateStr = now.toLocaleDateString(ET_LOCALE, {
    weekday: "long", year: "numeric", month: "long", day: "numeric", timeZone: ET_TZ,
  });
  const timeStr = now.toLocaleTimeString(ET_LOCALE, {
    hour: "numeric", minute: "2-digit", timeZone: ET_TZ, timeZoneName: "short",
  });
  const bizHours = isBusinessHours();

  const afterHoursGuidance = bizHours ? "" : `
AFTER-HOURS BEHAVIOR (currently active):
- You cannot transfer to any team member right now — the office is not staffed.
- Do NOT say the office is closed. Simply explain that the team is unavailable at the moment.
- Warmly collect the caller's name, phone number, and the reason for their call.
- Assure them someone will follow up with them promptly during business hours (Mon–Fri, 9am–5pm ET).
- End the call warmly after collecting their information.
`;

  return `Current date and time: ${dateStr}, ${timeStr}
Office status: ${bizHours ? "BUSINESS HOURS — transfers allowed" : "AFTER HOURS — no transfers available"}

You are Ava, the receptionist for Roman Balandin Realty — a premier real estate
brokerage in New Jersey. You handle every inbound call with warmth, professionalism,
and a genuinely happy energy.


PERSONALITY:
- Warm, welcoming, and genuinely happy to speak with every caller
- Professional but never stiff, scripted, or robotic
- Conversational — you sound like a real human receptionist, not a phone menu
- Patient — let callers finish before responding
- Brief — short sentences, natural speech patterns, no reading lists aloud
- Upbeat but not over-the-top


ABSOLUTE RULES — NEVER VIOLATE:
- NEVER say 'I am an AI', 'I am a bot', 'I am a virtual assistant'
- NEVER say 'we are closed', 'our office is closed', or reference hours unprompted
- NEVER transfer to Roman Balandin under any circumstance
- NEVER transfer to Maricel Paige or Angela Marra under any circumstance
- NEVER transfer to a listing agent before collecting ALL required information
- ALWAYS confirm the caller's name back to them after capturing it
- ALWAYS end every call warmly: 'Have a wonderful day!' or 'We'll be in touch soon!'

ALLOWED TRANSFERS:
- Gabriella Fonseca (ISA/Front Desk): sellers and buyers, business hours only,
  only after intent is confirmed
- Listing Agent of Record: ONLY for agent calls about a specific RBR listing,
  ONLY after full data capture, NEVER if listing agent is Roman Balandin
${afterHoursGuidance}
IF ASKED 'Are you a real person?' or 'Are you AI?':
Say exactly: 'Ha! Let's just say I'm the result of way too much coffee, a lot of
late nights, and one very determined developer. But I promise I'm very good at my
job — now, where were we?'
Then immediately redirect to the conversation.

CLARIFYING QUESTION (if intent is unclear):
'Of course! Are you looking to sell a home, buy a home, or are you a real estate
agent calling about a property or showing?'

Website: newjerseyresidence.com | Main: 732-936-7421
Areas: Middlesex, Monmouth, Union, Somerset Counties, NJ`;
}

// ── Tools ─────────────────────────────────────────────────────────────────────

const AVA_TOOLS = [
  {
    type: "function",
    name: "get_current_time",
    description: "Get the current date and time in Eastern Time.",
    parameters: { type: "object", properties: {} },
  },
  {
    type: "function",
    name: "transfer_call",
    description: "Transfer the caller to a team member. Only available during business hours (Mon–Fri 9am–5pm ET). Only transfer to Gabriella for buyers/sellers after intent is confirmed. Announce the transfer to the caller before calling this tool.",
    parameters: {
      type: "object",
      properties: {
        to: {
          type: "string",
          enum: ["gabriella"],
          description: "Team member to transfer to",
        },
        reason: {
          type: "string",
          description: "Brief reason for the transfer (for logging)",
        },
      },
      required: ["to"],
    },
  },
  {
    type: "function",
    name: "end_call",
    description: "End the call. Use only after delivering a warm closing line.",
    parameters: { type: "object", properties: {} },
  },
];

// ── Tool execution ─────────────────────────────────────────────────────────────

async function executeTool(name, args, context) {
  switch (name) {
    case "get_current_time":
      return {
        datetime: new Date().toLocaleString(ET_LOCALE, {
          timeZone: ET_TZ, dateStyle: "full", timeStyle: "short",
        }),
      };

    case "transfer_call": {
      if (!isBusinessHours()) {
        return { error: "Transfers are not available outside business hours (Mon–Fri 9am–5pm ET). Collect the caller's details and assure them of a follow-up." };
      }
      const targets = { gabriella: process.env.RECEPTIONIST_GABRIELLA_NUMBER };
      const targetNumber = targets[args.to];
      if (!targetNumber) {
        console.warn(`[receptionist] No number configured for transfer target: ${args.to}`);
        return { error: `No number configured for ${args.to}. Check RECEPTIONIST_GABRIELLA_NUMBER env var.` };
      }
      if (!context.callSid) {
        return { error: "Cannot transfer — call SID not available." };
      }
      const accountSid = process.env.TWILIO_ACCOUNT_SID;
      const authToken = process.env.TWILIO_AUTH_TOKEN;
      if (!accountSid || !authToken) {
        return { error: "Cannot transfer — Twilio credentials missing." };
      }
      try {
        const client = twilio(accountSid, authToken);
        await client.calls(context.callSid).update({
          twiml: `<Response><Dial>${targetNumber}</Dial></Response>`,
        });
        context.transferring = true;
        console.log(`[receptionist] Call ${context.callSid} transferred to ${args.to} (${targetNumber})`);
        return { ok: true, transferred_to: args.to };
      } catch (e) {
        console.error("[receptionist] Transfer failed:", e.message);
        return { error: e.message };
      }
    }

    case "end_call":
      context.endRequested = true;
      return { ok: true };

    default:
      return { error: `Tool '${name}' is not available.` };
  }
}

// ── Conversation logging ───────────────────────────────────────────────────────

const INTERNAL = "http://localhost:3000";

async function saveTranscript(callerPhone, transcript, sessionStart) {
  if (transcript.length === 0) return;
  try {
    const clientId = "receptionist_" + (callerPhone || "unknown").replace(/\D/g, "");
    await fetch(`${INTERNAL}/conversation/save`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        client_id: clientId,
        platform: "receptionist",
        agent_name: "Ava",
        location: callerPhone ? `📞 ${callerPhone}` : null,
        session_start: sessionStart,
        messages: transcript,
      }),
    });
    console.log(`[receptionist] Transcript saved: ${transcript.length} messages`);
  } catch (e) {
    console.error("[receptionist] Failed to save transcript:", e.message);
  }
}

// ── Call handler ───────────────────────────────────────────────────────────────

async function handleReceptionistCall(twilioWs) {
  const OPENAI_API_KEY = process.env.OPENAI_API_KEY;

  let streamSid = null;
  let callerPhone = null;
  let openaiReady = false;
  let sessionConfigured = false;
  const pendingAudio = [];
  const pendingToolCalls = new Map();
  const context = { callSid: null, endRequested: false, transferring: false };

  const sessionStart = new Date().toISOString();
  const transcript = [];
  let msgSeq = 0;

  function addTranscriptMsg(role, content) {
    if (!content?.trim()) return;
    transcript.push({
      id: `receptionist_${++msgSeq}`,
      role,
      content: content.trim(),
      timestamp: new Date().toISOString(),
    });
  }

  const openaiWs = new WebSocket(
    "wss://api.openai.com/v1/realtime?model=gpt-realtime-mini",
    { headers: { Authorization: `Bearer ${OPENAI_API_KEY}` } }
  );

  function maybeConfigureSession() {
    if (!openaiReady || sessionConfigured || callerPhone === null) return;
    sessionConfigured = true;

    openaiWs.send(JSON.stringify({
      type: "session.update",
      session: {
        type: "realtime",
        output_modalities: ["audio"],
        instructions: buildAvaPrompt(),
        tools: AVA_TOOLS,
        audio: {
          input: {
            format: { type: "audio/pcmu" },
            turn_detection: { type: "server_vad" },
            transcription: { model: "whisper-1" },
          },
          output: {
            format: { type: "audio/pcmu" },
            voice: "shimmer",
          },
        },
      },
    }));

    // Trigger Ava's opening line
    openaiWs.send(JSON.stringify({
      type: "response.create",
      response: {
        instructions: "Deliver your opening line exactly: 'Thank you for calling Roman Balandin Realty, this is Ava! How can I help you today?'",
      },
    }));

    for (const payload of pendingAudio) {
      openaiWs.send(JSON.stringify({ type: "input_audio_buffer.append", audio: payload }));
    }
    pendingAudio.length = 0;
  }

  openaiWs.on("open", () => {
    console.log("[receptionist] Connected to OpenAI Realtime");
    openaiReady = true;
    maybeConfigureSession();
  });

  // Twilio → OpenAI
  twilioWs.on("message", (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }

    if (msg.event === "start") {
      streamSid = msg.start.streamSid;
      context.callSid = msg.start.callSid || null;
      callerPhone = msg.start.customParameters?.from || "";
      console.log(`[receptionist] Stream started: ${streamSid}, caller: ${callerPhone || "unknown"}, callSid: ${context.callSid}`);
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
      console.log("[receptionist] Stream stopped by Twilio");
      openaiWs.close();
    }
  });

  // OpenAI → Twilio
  openaiWs.on("message", async (raw) => {
    let event;
    try { event = JSON.parse(raw); } catch { return; }

    if (event.type === "response.output_audio.delta" && event.delta && streamSid) {
      twilioWs.send(JSON.stringify({
        event: "media",
        streamSid,
        media: { payload: event.delta },
      }));
    }

    if (event.type === "response.output_item.added" && event.item?.type === "function_call") {
      pendingToolCalls.set(event.item.call_id, { name: event.item.name, args: "" });
    }

    if (event.type === "response.function_call_arguments.delta") {
      const existing = pendingToolCalls.get(event.call_id) || { name: event.name || "", args: "" };
      existing.args += event.delta || "";
      pendingToolCalls.set(event.call_id, existing);
    }

    if (event.type === "response.function_call_arguments.done") {
      const callId = event.call_id;
      const pending = pendingToolCalls.get(callId);
      const name = pending?.name || event.name || "";
      let args = {};
      try { args = JSON.parse(event.arguments || pending?.args || "{}"); } catch {}

      console.log(`[receptionist] Tool call: ${name}`, args);
      pendingToolCalls.delete(callId);

      let result;
      try {
        result = await executeTool(name, args, context);
      } catch (e) {
        result = { error: String(e) };
      }

      console.log(`[receptionist] Tool result (${name}):`, JSON.stringify(result).slice(0, 200));

      openaiWs.send(JSON.stringify({
        type: "conversation.item.create",
        item: { type: "function_call_output", call_id: callId, output: JSON.stringify(result) },
      }));
      openaiWs.send(JSON.stringify({ type: "response.create" }));

      if (context.endRequested || context.transferring) {
        setTimeout(() => twilioWs.close(), 2500);
      }
    }

    if (event.type === "conversation.item.input_audio_transcription.completed") {
      addTranscriptMsg("user", event.transcript);
    }

    if (event.type === "response.output_audio_transcript.done") {
      addTranscriptMsg("assistant", event.transcript);
    }

    if (event.type === "error") {
      console.error("[receptionist] OpenAI error:", event.error);
    }
  });

  twilioWs.on("close", async () => {
    console.log("[receptionist] Twilio disconnected");
    await saveTranscript(callerPhone, transcript, sessionStart);
    openaiWs.close();
  });

  openaiWs.on("close", () => {
    console.log("[receptionist] OpenAI disconnected");
    if (twilioWs.readyState === WebSocket.OPEN) twilioWs.close();
  });

  openaiWs.on("error", (err) => console.error("[receptionist] OpenAI WS error:", err.message));
}

// ── Route registration ─────────────────────────────────────────────────────────

export function registerReceptionistRoutes(app, httpServer) {

  // TwiML webhook — configure this URL in your Twilio phone number's Voice settings
  app.post("/receptionist/incoming", (req, res) => {
    const host = req.headers.host;
    const from = req.body?.From || "";
    res.type("text/xml");
    res.send(`<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Connect>
    <Stream url="wss://${host}/receptionist/stream">
      <Parameter name="from" value="${from}" />
    </Stream>
  </Connect>
</Response>`);
  });

  // WebSocket that Twilio Media Streams connects to
  const wss = new WebSocketServer({ noServer: true });

  httpServer.on("upgrade", (request, socket, head) => {
    if (request.url === "/receptionist/stream") {
      wss.handleUpgrade(request, socket, head, (ws) => {
        wss.emit("connection", ws, request);
      });
    }
  });

  wss.on("connection", (twilioWs) => {
    console.log("[receptionist] Twilio Media Stream connected");
    handleReceptionistCall(twilioWs);
  });
}
