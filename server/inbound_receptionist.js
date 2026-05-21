import { WebSocketServer } from "ws";
import WebSocket from "ws";
import twilio from "twilio";
import fs from "fs";
import { adminTabBar, tabBarCss } from "./feedback.js";

const ET_LOCALE = "en-US";
const ET_TZ = "America/New_York";
const INTERNAL = "http://localhost:3000";

// ── Config ────────────────────────────────────────────────────────────────────

const CONFIG_FILE = "/data/receptionist_config.json";

const DEFAULT_CONFIG = {
  gabriella_number: process.env.RECEPTIONIST_GABRIELLA_NUMBER || "",
  ring_timeout_seconds: 30,
  voice: "marin",
};

// Voices confirmed available on the OpenAI Realtime API, curated for a receptionist persona
const REALTIME_VOICES = [
  { id: "marin",   label: "Marin",   desc: "Warm, professional female — current default" },
  { id: "coral",   label: "Coral",   desc: "Friendly, conversational female" },
  { id: "shimmer", label: "Shimmer", desc: "Bright, upbeat female" },
  { id: "sage",    label: "Sage",    desc: "Calm, measured female" },
  { id: "alloy",   label: "Alloy",   desc: "Neutral, clear — gender-neutral" },
  { id: "ash",     label: "Ash",     desc: "Warm, conversational — gender-neutral" },
  { id: "echo",    label: "Echo",    desc: "Neutral male" },
  { id: "verse",   label: "Verse",   desc: "Expressive, dynamic male" },
];

function loadConfig() {
  try {
    if (fs.existsSync(CONFIG_FILE)) {
      return { ...DEFAULT_CONFIG, ...JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8")) };
    }
  } catch {}
  return { ...DEFAULT_CONFIG };
}

function saveConfig(cfg) {
  fs.mkdirSync("/data", { recursive: true });
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2), "utf8");
}

// ── Business hours + holidays ─────────────────────────────────────────────────

function nthWeekday(year, month, dow, n) {
  const d = new Date(year, month - 1, 1);
  const first = d.getDay();
  const day = 1 + ((dow - first + 7) % 7) + (n - 1) * 7;
  return new Date(year, month - 1, day);
}

function lastWeekday(year, month, dow) {
  const last = new Date(year, month, 0);
  const diff = (last.getDay() - dow + 7) % 7;
  return new Date(year, month - 1, last.getDate() - diff);
}

function observed(date) {
  const dow = date.getDay();
  if (dow === 6) return new Date(date.getFullYear(), date.getMonth(), date.getDate() - 1);
  if (dow === 0) return new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1);
  return date;
}

function usHolidays(year) {
  const fixed = (m, d) => observed(new Date(year, m - 1, d));
  const fmt = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  return new Set([
    fmt(fixed(1, 1)),
    fmt(nthWeekday(year, 1, 1, 3)),
    fmt(nthWeekday(year, 2, 1, 3)),
    fmt(lastWeekday(year, 5, 1)),
    fmt(fixed(6, 19)),
    fmt(fixed(7, 4)),
    fmt(nthWeekday(year, 9, 1, 1)),
    fmt(fixed(11, 11)),
    fmt(nthWeekday(year, 11, 4, 4)),
    fmt(fixed(12, 25)),
  ]);
}

function isBusinessHours() {
  const now = new Date();
  const etParts = new Intl.DateTimeFormat("en-US", {
    timeZone: ET_TZ, weekday: "short", hour: "numeric", hour12: false,
    year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(now);
  const get = (type) => etParts.find(p => p.type === type)?.value;
  const dayMap = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  const etDay = dayMap[get("weekday")] ?? -1;
  const etHour = Number(get("hour") ?? -1);
  const etDateStr = `${get("year")}-${get("month")}-${get("day")}`;
  if (etDay < 1 || etDay > 5) return false;
  if (etHour < 9 || etHour >= 17) return false;
  if (usHolidays(Number(get("year"))).has(etDateStr)) return false;
  return true;
}

// ── System prompt ─────────────────────────────────────────────────────────────

// sessionCtx: { noAnswer, callerName, callerIntent }
function buildAvaPrompt(sessionCtx = {}) {
  const now = new Date();
  const dateStr = now.toLocaleDateString(ET_LOCALE, {
    weekday: "long", year: "numeric", month: "long", day: "numeric", timeZone: ET_TZ,
  });
  const timeStr = now.toLocaleTimeString(ET_LOCALE, {
    hour: "numeric", minute: "2-digit", timeZone: ET_TZ, timeZoneName: "short",
  });
  const bizHours = isBusinessHours();

  // Injected when Gabriella didn't answer and the caller was returned to Ava
  const noAnswerBlock = sessionCtx.noAnswer ? `
CURRENT SITUATION — TRANSFER FAILED (no answer):
You just tried to connect ${sessionCtx.callerName || "the caller"} (a ${sessionCtx.callerIntent || "caller"}) to Gabriella but got no answer.
Open with exactly: 'Hey, sorry about that — looks like the team is tied up with another client right now. No worries at all, I've got you! Let me grab your info and we'll make sure someone reaches out to you as soon as possible!'
Then proceed immediately to the ${sessionCtx.callerIntent || "buyer/seller"} qualification script below.
Do NOT attempt another transfer.
` : "";

  const transferBlock = bizHours && !sessionCtx.noAnswer ? `
TRANSFER FLOW (business hours, buyer or seller only):
1. Confirm the caller's name and intent (buyer / seller).
2. Say exactly: 'Perfect! Let me connect you with one of our team members right now — one moment!'
3. Call the transfer_call tool with caller_name, caller_intent, and a brief caller_reason.
4. Do not say anything else after announcing the transfer — the tool handles the rest.
` : "";

  const qualificationGuide = `
QUALIFICATION SCRIPTS (use after failed transfer, after hours, or for agents):

BUYER — first determine which sub-branch applies, then follow that path conversationally:

Detect intent early: is the caller asking about a SPECIFIC property, or doing a GENERAL search?
Listen for mentions of an address, MLS number, or "I saw a listing" → Sub-Branch 2A.
If they say they're looking to buy but haven't found a property yet → Sub-Branch 2B.

SUB-BRANCH 2A — Specific Property Inquiry (conversational goals, not a checklist):
1. Full name — 'What's your name?'
2. Best callback number — 'And the best number to reach you?'
3. Email — 'Perfect — and an email address?'
4. Source — 'Is this a property listed through Roman Balandin Realty, or did you find it on Zillow or another site?'
5. Property address or MLS — 'What's the address, or do you have the MLS number?'
6. Showing availability — 'When would you be available for a showing — any days or times in mind?'
7. Pre-approval — 'Have you been pre-approved for a mortgage yet, or is that still in the works?'
8. Close — 'Perfect [Name]! Our team will be in touch with you shortly. Have a wonderful day!'

SUB-BRANCH 2B — General Buyer Search (conversational goals, not a checklist):
1. Full name — 'What's your name?'
2. Best callback number — 'And the best number to reach you?'
3. Email — 'Great — and a good email address?'
4. Location / towns — 'What area or towns in New Jersey are you focusing on?'
5. Bedrooms — 'How many bedrooms are you looking for?'
6. Bathrooms — 'And bathrooms?'
7. Price range — 'What's your budget — do you have a price range in mind?'
8. Pre-approval — 'Are you already pre-approved for a mortgage, or is that still something you're working on?'
9. Timeline — 'When are you hoping to be in a new home — any specific timeframe?'
10. Close — 'Perfect [Name]! Our team will reach out to you soon with some options. Have a wonderful day!'

Keep both paths warm and conversational. If the caller volunteers info, acknowledge it and skip that question. Do not read these as a list.

SELLER — conversational flow, not a checklist. Weave questions naturally into the conversation. Goals to cover:
1. Full name — ask 'What's your name — first and last?' then confirm: 'Great, nice to meet you [First Name]!'
2. Best callback number — 'And the best number to reach you — is this the number you're calling from?' If yes, confirm it back.
3. Email — 'Perfect! And what's a good email address for you?' Spell it back if at all unclear.
4. Property address — 'And what's the address of the home you're thinking about selling?'
5. Beds and baths — 'Just so I can pass the full picture along — how many bedrooms and bathrooms does it have?'
6. Additional features — 'Anything else worth mentioning — finished basement, pool, garage, or a rough square footage?' Keep this casual, not a list.
7. Timeline — 'And roughly, what's your timeline — are you thinking of making a move soon, or still in the early stages?'
8. Close — 'Perfect, [First Name]! I have everything I need. Our team will be reaching out to you very shortly — you're in great hands! Is there anything else?'

Do NOT robotically go through these in order — listen and adapt. If the caller volunteers info, acknowledge it and skip that question. Keep it warm and conversational throughout.

AGENT — CRITICAL RULES (never violate):
- NEVER transfer an agent call to Gabriella under any circumstance.
- Collect ALL information below FIRST, before any routing decision.
- Only after full data capture may Ava transfer to the listing agent of record — NEVER if that agent is Roman Balandin.
- If Roman Balandin is the listing agent: complete the call warmly, collect everything, and close. The team will follow up.

AGENT DATA CAPTURE (conversational goals, collect in natural order):
1. Agent name — 'What's your name?'
2. Brokerage — 'And what brokerage are you calling from?'
3. Best callback number — 'Best callback number for you?'
4. Email — 'And an email address?'
5. Purpose — 'Got it! What can I help you with — is this about a showing, a listing, an offer, or a transaction?'
6. Property address — 'What's the property address this is regarding?'
7. Details — 'Tell me a little more — I want to make sure the right person has everything they need.'
8. Urgency — 'Is this time-sensitive, or can our team follow up within a few hours?'

After collecting everything, close warmly: 'Perfect! I've got all the details. The right person will be reaching out to you shortly — thanks so much for calling Roman Balandin Realty!'
Do not rush. Keep it professional and warm. Never mention Roman Balandin by name unprompted.

After completing qualification: summarize what you collected, thank them warmly, and assure them the team will follow up promptly. Then use end_call.
`;

  return `Current date and time: ${dateStr}, ${timeStr}
Office status: ${bizHours ? "BUSINESS HOURS" : "AFTER HOURS"}
${noAnswerBlock}
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
- NEVER mention office hours or availability unprompted
- NEVER transfer to Roman Balandin under any circumstance
- NEVER transfer to Maricel Paige or Angela Marra under any circumstance
- ALWAYS confirm the caller's name back to them after capturing it
- ALWAYS end every call warmly: 'Have a wonderful day!' or 'We'll be in touch soon!'
${transferBlock}${qualificationGuide}
IF ASKED 'Are you a real person?' or 'Are you AI?':
Say exactly: 'Ha! Let's just say I'm the result of way too much coffee, a lot of late nights, and one very determined developer. But I promise I'm very good at my job — now, where were we?'
Then immediately redirect to the conversation.

CLARIFYING QUESTION (if intent is unclear):
'Of course! Are you looking to sell a home, buy a home, or are you a real estate agent calling about a property or showing?'

Website: newjerseyresidence.com | Main: 732-936-7421
Areas: Middlesex, Monmouth, Union, Somerset Counties, NJ`;
}

// ── Tools ─────────────────────────────────────────────────────────────────────

// transfer_call is only offered when business hours and not a reconnect session
function buildAvaTools({ bizHours, isReconnect }) {
  const tools = [
    {
      type: "function",
      name: "get_current_time",
      description: "Get the current date and time in Eastern Time.",
      parameters: { type: "object", properties: {} },
    },
    {
      type: "function",
      name: "end_call",
      description: "End the call. Use only after delivering a warm closing line.",
      parameters: { type: "object", properties: {} },
    },
  ];

  if (bizHours && !isReconnect) {
    tools.push({
      type: "function",
      name: "transfer_call",
      description: "Warm-transfer a buyer or seller to Gabriella. Collect their name, intent, and reason first. Announce the transfer before calling this tool. Only available during business hours.",
      parameters: {
        type: "object",
        properties: {
          caller_name: { type: "string", description: "Confirmed caller name" },
          caller_intent: { type: "string", enum: ["buyer", "seller"], description: "Whether the caller is buying or selling" },
          caller_reason: { type: "string", description: "Brief reason for calling (one sentence)" },
        },
        required: ["caller_name", "caller_intent"],
      },
    });
  }

  return tools;
}

// ── Tool execution ─────────────────────────────────────────────────────────────

function esc(str) {
  return String(str || "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

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
        return { error: "Outside business hours — collect caller details instead." };
      }
      const config = loadConfig();
      const targetNumber = config.gabriella_number;
      if (!targetNumber) return { error: "Gabriella's number not configured. Set it in /admin/receptionist." };
      if (!context.callSid) return { error: "Call SID not available." };
      if (!context.host) return { error: "Host not available." };

      const accountSid = process.env.TWILIO_ACCOUNT_SID;
      const authToken = process.env.TWILIO_AUTH_TOKEN;
      if (!accountSid || !authToken) return { error: "Twilio credentials missing." };

      const callerName = args.caller_name || "";
      const callerIntent = args.caller_intent || "";
      const callerReason = args.caller_reason || "";
      const timeout = config.ring_timeout_seconds || 30;
      const host = context.host;

      const whisperUrl = `https://${host}/receptionist/whisper?name=${encodeURIComponent(callerName)}&intent=${encodeURIComponent(callerIntent)}&reason=${encodeURIComponent(callerReason)}`;
      const actionUrl = `https://${host}/receptionist/transfer-result?from=${encodeURIComponent(context.callerPhone || "")}&name=${encodeURIComponent(callerName)}&intent=${encodeURIComponent(callerIntent)}`;

      const twiml = `<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Dial timeout="${timeout}" action="${esc(actionUrl)}">
    <Number url="${esc(whisperUrl)}">${esc(targetNumber)}</Number>
  </Dial>
</Response>`;

      try {
        const client = twilio(accountSid, authToken);
        await client.calls(context.callSid).update({ twiml });
        context.transferring = true;
        console.log(`[receptionist] Warm transfer → Gabriella (${targetNumber}), timeout=${timeout}s`);
        return { ok: true };
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
  let sessionCtx = {};   // populated on reconnect
  let openaiReady = false;
  let sessionConfigured = false;
  const pendingAudio = [];
  const pendingToolCalls = new Map();
  const context = { callSid: null, host: null, callerPhone: null, endRequested: false, transferring: false };

  const sessionStart = new Date().toISOString();
  const sessionId = sessionStart.replace(/[:.]/g, "-").substring(0, 19);
  const transcript = [];
  let msgSeq = 0;

  function addTranscriptMsg(role, content) {
    if (!content?.trim()) return;
    transcript.push({
      id: `receptionist_${sessionId}_${++msgSeq}`,
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

    const bizHours = isBusinessHours();
    const isReconnect = !!sessionCtx.noAnswer;
    const cfg = loadConfig();
    const voice = REALTIME_VOICES.find(v => v.id === cfg.voice) ? cfg.voice : DEFAULT_CONFIG.voice;

    openaiWs.send(JSON.stringify({
      type: "session.update",
      session: {
        type: "realtime",
        output_modalities: ["audio"],
        instructions: buildAvaPrompt(sessionCtx),
        tools: buildAvaTools({ bizHours, isReconnect }),
        audio: {
          input: {
            format: { type: "audio/pcmu" },
            turn_detection: { type: "server_vad" },
            transcription: { model: "whisper-1" },
          },
          output: {
            format: { type: "audio/pcmu" },
            voice,
          },
        },
      },
    }));

    // Opening instruction depends on whether this is a reconnect after failed transfer
    const openingInstruction = isReconnect
      ? `Say exactly: 'Hey, sorry about that — looks like the team is tied up with another client right now. No worries at all, I've got you! Let me grab your info and we'll make sure someone reaches out to you as soon as possible!' Then proceed to the ${sessionCtx.callerIntent || "buyer/seller"} qualification script.`
      : "Deliver your opening line exactly: 'Thank you for calling Roman Balandin Realty, this is Ava! How can I help you today?'";

    openaiWs.send(JSON.stringify({
      type: "response.create",
      response: { instructions: openingInstruction },
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
      context.host = msg.start.customParameters?.host || "";
      callerPhone = msg.start.customParameters?.from || "";
      context.callerPhone = callerPhone;

      // Reconnect context — set when Gabriella didn't answer
      if (msg.start.customParameters?.reconnect === "true") {
        sessionCtx = {
          noAnswer: true,
          callerName: msg.start.customParameters?.caller_name || "",
          callerIntent: msg.start.customParameters?.caller_intent || "",
        };
        console.log(`[receptionist] Reconnect after no-answer — name: ${sessionCtx.callerName}, intent: ${sessionCtx.callerIntent}`);
      }

      console.log(`[receptionist] Stream started: ${streamSid}, caller: ${callerPhone || "unknown"}, callSid: ${context.callSid}${sessionCtx.noAnswer ? " (RECONNECT)" : ""}`);
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
      const toolName = pending?.name || event.name || "";
      let args = {};
      try { args = JSON.parse(event.arguments || pending?.args || "{}"); } catch {}

      console.log(`[receptionist] Tool call: ${toolName}`, args);
      pendingToolCalls.delete(callId);

      let result;
      try { result = await executeTool(toolName, args, context); }
      catch (e) { result = { error: String(e) }; }

      console.log(`[receptionist] Tool result (${toolName}):`, JSON.stringify(result).slice(0, 200));

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

  // TwiML webhook — point your Twilio number's Voice webhook here
  app.post("/receptionist/incoming", (req, res) => {
    const host = req.headers.host;
    const from = req.body?.From || "";
    res.type("text/xml");
    res.send(`<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Connect>
    <Stream url="wss://${host}/receptionist/stream">
      <Parameter name="from" value="${esc(from)}" />
      <Parameter name="host" value="${esc(host)}" />
    </Stream>
  </Connect>
</Response>`);
  });

  // Whisper TwiML — played to Gabriella before being connected to the caller
  app.all("/receptionist/whisper", (req, res) => {
    const p = { ...req.query, ...req.body };
    const callerName = p.name || "the caller";
    const intent = p.intent === "seller" ? "seller" : "buyer";
    const reason = p.reason ? ` They mentioned: ${p.reason}.` : "";
    const msg = `You have a ${intent} on the line. Their name is ${callerName}.${reason} Connecting now.`;
    res.type("text/xml");
    res.send(`<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Say>${esc(msg)}</Say>
</Response>`);
  });

  // Transfer result — Twilio POSTs here when the Dial completes (answered or no-answer)
  app.post("/receptionist/transfer-result", (req, res) => {
    const dialStatus = req.body?.DialCallStatus || "";
    const p = { ...req.query, ...req.body };
    const from = p.from || "";
    const callerName = p.name || "";
    const callerIntent = p.intent || "";
    const host = req.headers.host;

    console.log(`[receptionist] Transfer result: DialCallStatus=${dialStatus}, caller=${from}`);

    // Call was answered and completed — nothing more to do
    if (dialStatus === "completed") {
      res.type("text/xml");
      res.send(`<?xml version="1.0" encoding="UTF-8"?><Response></Response>`);
      return;
    }

    // No answer / busy / failed — reconnect caller back to Ava
    console.log(`[receptionist] No answer — reconnecting caller to Ava`);
    res.type("text/xml");
    res.send(`<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Connect>
    <Stream url="wss://${esc(host)}/receptionist/stream">
      <Parameter name="from" value="${esc(from)}" />
      <Parameter name="host" value="${esc(host)}" />
      <Parameter name="reconnect" value="true" />
      <Parameter name="caller_name" value="${esc(callerName)}" />
      <Parameter name="caller_intent" value="${esc(callerIntent)}" />
    </Stream>
  </Connect>
</Response>`);
  });

  // ── Config UI ──────────────────────────────────────────────────────────────

  app.get("/admin/receptionist", (req, res) => {
    const cfg = loadConfig();
    const saved = req.query.saved === "1";
    res.send(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ava Receptionist — Settings</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f5f5f7; color: #1d1d1f; }
  h1 { font-size: 1.6rem; font-weight: 700; padding: 24px 32px 0; }
  .subtitle { color: #6e6e73; font-size: 0.9rem; padding: 4px 32px 16px; }
  ${tabBarCss}
  .container { padding: 24px; max-width: 600px; }
  .card { background: #fff; border-radius: 12px; padding: 24px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); margin-bottom: 20px; }
  .card h2 { font-size: 1rem; font-weight: 600; margin-bottom: 16px; color: #1d1d1f; }
  label { display: block; font-size: 0.85rem; font-weight: 500; color: #6e6e73; margin-bottom: 6px; margin-top: 16px; }
  label:first-of-type { margin-top: 0; }
  input[type="text"], input[type="number"] {
    width: 100%; padding: 10px 12px; border: 1px solid #d1d1d6; border-radius: 8px;
    font-size: 0.95rem; color: #1d1d1f; background: #fafafa;
  }
  input:focus { outline: none; border-color: #007aff; background: #fff; }
  .hint { font-size: 0.78rem; color: #8e8e93; margin-top: 4px; }
  .save-btn {
    margin-top: 20px; padding: 10px 24px; background: #007aff; color: #fff;
    border: none; border-radius: 8px; font-size: 0.95rem; font-weight: 600; cursor: pointer;
  }
  .save-btn:hover { background: #0062cc; }
  .banner { background: #e8ffe8; border: 1px solid #a3d9a3; color: #1a7a1a; border-radius: 8px; padding: 10px 14px; font-size: 0.9rem; margin-bottom: 16px; }
  .voice-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 8px; }
  .voice-option { display: flex; flex-direction: column; gap: 2px; padding: 10px 12px; border: 1.5px solid #d1d1d6; border-radius: 8px; cursor: pointer; transition: border-color 0.15s; }
  .voice-option input[type="radio"] { display: none; }
  .voice-option.selected { border-color: #007aff; background: #f0f7ff; }
  .voice-option:hover:not(.selected) { border-color: #aeaeb2; }
  .voice-name { font-size: 0.9rem; font-weight: 600; color: #1d1d1f; }
  .voice-desc { font-size: 0.75rem; color: #6e6e73; }
  .status-row { display: flex; align-items: center; gap: 10px; margin-top: 8px; }
  .badge { display: inline-block; padding: 3px 10px; border-radius: 20px; font-size: 0.8rem; font-weight: 600; }
  .badge.open { background: #e8ffe8; color: #1a7a1a; }
  .badge.closed { background: #fee2e2; color: #b91c1c; }
</style>
</head>
<body>
<h1>RoadMate</h1>
<p class="subtitle">Ava Receptionist — Settings</p>
${adminTabBar("receptionist")}
<div class="container">
  ${saved ? '<div class="banner">✓ Settings saved successfully.</div>' : ""}

  <div class="card">
    <h2>📞 Inbound Call Number</h2>
    <div style="font-size:1.3rem;font-weight:700;letter-spacing:0.02em;margin-bottom:6px">+1 (978) 396-5164</div>
    <p class="hint">This is the Twilio number callers dial to reach Ava. Configure the Voice webhook in Twilio to point to <code style="background:#f2f2f7;padding:2px 5px;border-radius:4px">/receptionist/incoming</code>.</p>
  </div>

  <div class="card">
    <h2>📊 Current Status</h2>
    <div class="status-row">
      Office hours right now:
      <span class="badge ${isBusinessHours() ? "open" : "closed"}">${isBusinessHours() ? "✓ Open — transfers enabled" : "✗ After hours — qualification only"}</span>
    </div>
    <p class="hint" style="margin-top:8px">Mon–Fri 9am–5pm ET, excluding US federal holidays.</p>
  </div>

  <form method="POST" action="/admin/receptionist">
    <div class="card">
      <h2>📞 Transfer Settings</h2>
      <label>Gabriella's Phone Number</label>
      <input type="text" name="gabriella_number" value="${esc(cfg.gabriella_number)}" placeholder="+17321234567" />
      <p class="hint">E.164 format. Buyers and sellers are warm-transferred here during business hours.</p>

      <label>Ring Timeout (seconds)</label>
      <input type="number" name="ring_timeout_seconds" value="${cfg.ring_timeout_seconds}" min="10" max="120" step="5" />
      <p class="hint">How long to wait before returning the caller to Ava (~5 seconds per ring). Default: 30s (≈6 rings).</p>
    </div>

    <div class="card">
      <h2>🎙️ Ava's Voice</h2>
      <label>Voice</label>
      <div class="voice-grid">
        ${REALTIME_VOICES.map(v => `
        <label class="voice-option ${v.id === cfg.voice ? "selected" : ""}">
          <input type="radio" name="voice" value="${v.id}" ${v.id === cfg.voice ? "checked" : ""} onchange="this.closest('.voice-grid').querySelectorAll('.voice-option').forEach(el=>el.classList.remove('selected')); this.closest('.voice-option').classList.add('selected')">
          <span class="voice-name">${v.label}</span>
          <span class="voice-desc">${v.desc}</span>
        </label>`).join("")}
      </div>
      <p class="hint" style="margin-top:12px">Takes effect on the next incoming call.</p>
    </div>

    <button type="submit" class="save-btn">Save Settings</button>
  </form>
</div>
</body>
</html>`);
  });

  app.post("/admin/receptionist", (req, res) => {
    const cfg = loadConfig();
    const body = req.body || {};
    cfg.gabriella_number = (body.gabriella_number || "").trim();
    cfg.ring_timeout_seconds = Math.max(10, Math.min(120, Number(body.ring_timeout_seconds) || 30));
    cfg.voice = REALTIME_VOICES.find(v => v.id === body.voice) ? body.voice : DEFAULT_CONFIG.voice;
    saveConfig(cfg);
    console.log("[receptionist] Config saved:", cfg);
    res.redirect("/admin/receptionist?saved=1");
  });

  // ── WebSocket ──────────────────────────────────────────────────────────────

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
