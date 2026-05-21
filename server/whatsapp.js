import { getAuthorizedClient } from "./gmail.js";
import { google } from "googleapis";
import { generateRprReport } from "./rpr.js";
import twilio from "twilio";
import fs from "fs";
import { adminTabBar, tabBarCss } from "./feedback.js";

const CLIENT_ID = "mtCoxfJIzGRqWaxu1V-_CQ";
const INTERNAL = "http://localhost:3000";

// ── WhatsApp config ───────────────────────────────────────────────────────────

const WA_CONFIG_FILE = "/data/whatsapp_config.json";
const WA_DEFAULT_CONFIG = {
  doc_id: "1Sze4u4xxcWZfQ2cU3WW8YFGJ3EOYIi1R7twzT-70cc0",
  rpr_enabled: true,
};

function loadWaConfig() {
  try {
    if (fs.existsSync(WA_CONFIG_FILE)) {
      return { ...WA_DEFAULT_CONFIG, ...JSON.parse(fs.readFileSync(WA_CONFIG_FILE, "utf8")) };
    }
  } catch {}
  return { ...WA_DEFAULT_CONFIG };
}

function saveWaConfig(cfg) {
  fs.mkdirSync("/data", { recursive: true });
  fs.writeFileSync(WA_CONFIG_FILE, JSON.stringify(cfg, null, 2), "utf8");
}

function escHtml(str) {
  return String(str || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

const SYSTEM_PERSONA = `You are a helpful assistant for Roman Balandin Realty. \
Answer user questions based on the provided knowledge base document. \
If a question is reasonable and related to real estate or topics covered in the document, \
you may answer from your general knowledge — but never hallucinate or make up specific details. \
If you don't know something, say so clearly and suggest the user contact the office directly. \
Never end responses with follow-up offers or suggestions like "feel free to ask" or "let me know if you need anything else" — just answer the question directly.`;

// Doc cache
let docContent = null;
let docModifiedTime = null;

function extractTextFromDocElements(elements) {
  let text = "";
  for (const el of elements ?? []) {
    if (el.paragraph) {
      for (const pe of el.paragraph.elements ?? []) {
        text += pe.textRun?.content ?? "";
      }
    } else if (el.table) {
      for (const row of el.table.tableRows ?? []) {
        const cells = [];
        for (const cell of row.tableCells ?? []) {
          cells.push(extractTextFromDocElements(cell.content).trim());
        }
        text += cells.join(" | ") + "\n";
      }
      text += "\n";
    }
  }
  return text;
}

async function fetchDocIfChanged() {
  try {
    const { doc_id } = loadWaConfig();
    const authClient = await getAuthorizedClient(CLIENT_ID);
    const drive = google.drive({ version: "v3", auth: authClient });
    const docs = google.docs({ version: "v1", auth: authClient });

    const meta = await drive.files.get({ fileId: doc_id, fields: "modifiedTime" });
    const newModifiedTime = meta.data.modifiedTime;

    if (newModifiedTime === docModifiedTime && docContent !== null) return;

    const doc = await docs.documents.get({ documentId: doc_id });
    docContent = extractTextFromDocElements(doc.data.body?.content).trim();
    docModifiedTime = newModifiedTime;
    console.log(`[whatsapp] Doc refreshed, modifiedTime=${newModifiedTime}, chars=${docContent.length}`);
  } catch (e) {
    console.error("[whatsapp] Failed to fetch doc:", e.message);
  }
}

// Per-sender conversation history, capped at 10 messages
const conversations = new Map();

function getHistory(sender) {
  if (!conversations.has(sender)) conversations.set(sender, []);
  return conversations.get(sender);
}

function addToHistory(sender, role, content) {
  const history = getHistory(sender);
  history.push({ role, content });
  if (history.length > 10) history.splice(0, history.length - 10);
}

function escapeTwiml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function twimlReply(message) {
  return `<?xml version="1.0" encoding="UTF-8"?><Response><Message>${escapeTwiml(message)}</Message></Response>`;
}

function twimlReplyWithMedia(message, mediaUrl) {
  return `<?xml version="1.0" encoding="UTF-8"?><Response><Message>${escapeTwiml(message)}<Media>${escapeTwiml(mediaUrl)}</Media></Message></Response>`;
}

async function sendOutboundWhatsApp(from, to, message, mediaUrl = null) {
  const accountSid = process.env.TWILIO_ACCOUNT_SID;
  const authToken = process.env.TWILIO_AUTH_TOKEN;
  if (!accountSid || !authToken) { console.warn("[whatsapp] Twilio creds missing, cannot send outbound"); return; }
  const client = twilio(accountSid, authToken);
  const params = { from, to, body: message };
  if (mediaUrl) params.mediaUrl = [mediaUrl];
  await client.messages.create(params).catch(e => console.error("[whatsapp] Outbound send error:", e.message));
}

const RPR_TOOL = {
  type: "function",
  function: {
    name: "generate_rpr_report",
    description: "Generate an RPR market analysis / seller report PDF for a property address. Use this when the user asks for a market analysis, property report, RPR report, or seller report for a specific address.",
    parameters: {
      type: "object",
      properties: {
        address: { type: "string", description: "Full property address including city, state and zip" },
      },
      required: ["address"],
    },
  },
};

async function saveConversation(from, messages) {
  try {
    const phone = from.replace(/^whatsapp:/, "");
    const clientId = "wa_" + phone.replace(/\D/g, "");
    const payload = {
      client_id: clientId,
      platform: "whatsapp",
      agent_name: "Roman Balandin Realty",
      location: phone,
      session_start: messages[0]?.timestamp ?? new Date().toISOString(),
      messages,
    };
    await fetch(`${INTERNAL}/conversation/save`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch (e) {
    console.error("[whatsapp] Failed to save conversation:", e.message);
  }
}

export function registerWhatsAppRoutes(app) {
  // Per-sender log of saved message objects (for conversation logging)
  const messageLogs = new Map();

  app.post("/whatsapp", async (req, res) => {
    res.set("Content-Type", "text/xml");

    const from = req.body?.From ?? "";
    const to = req.body?.To ?? "";
    const userMessage = (req.body?.Body ?? "").trim();

    if (!from || !userMessage) {
      return res.send("<Response></Response>");
    }

    await fetchDocIfChanged();

    const systemPrompt = `${SYSTEM_PERSONA}\n\n--- KNOWLEDGE BASE ---\n${docContent || "Knowledge base not available."}\n--- END ---`;

    const now = new Date().toISOString();
    addToHistory(from, "user", userMessage);

    if (!messageLogs.has(from)) messageLogs.set(from, []);
    const log = messageLogs.get(from);
    log.push({ id: `${from}-${log.length}-u`, role: "user", content: userMessage, timestamp: now });

    try {
      const r = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${process.env.OPENAI_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "gpt-4o-mini",
          messages: [
            { role: "system", content: systemPrompt },
            ...getHistory(from),
          ],
          tools: loadWaConfig().rpr_enabled ? [RPR_TOOL] : [],
          tool_choice: "auto",
          temperature: 0.4,
        }),
      });

      const data = await r.json();
      const choice = data?.choices?.[0];

      // Handle RPR tool call — reply immediately, generate async, send result via outbound message
      if (choice?.finish_reason === "tool_calls") {
        const toolCall = choice.message.tool_calls.find(tc => tc.function.name === "generate_rpr_report");
        if (toolCall) {
          const { address } = JSON.parse(toolCall.function.arguments);
          console.log(`[whatsapp] RPR report requested for: ${address}`);

          const ack = `Generating your RPR market analysis report for ${address}. This takes 1-2 minutes — I'll send you the link shortly.`;
          addToHistory(from, "assistant", ack);
          log.push({ id: `${from}-${log.length}-a`, role: "assistant", content: ack, timestamp: new Date().toISOString() });
          await saveConversation(from, log);

          // Generate report in background, send result via outbound Twilio message
          generateRprReport(address).then(async result => {
            let outboundContent;
            if (result.ok) {
              outboundContent = `Here is your RPR market analysis report for ${address}: ${result.pdfUrl}`;
              await sendOutboundWhatsApp(to, from, `Here is your RPR market analysis report for ${address}:`, result.pdfUrl);
            } else {
              outboundContent = `Sorry, I was unable to generate the RPR report for ${address}. Please try again later.`;
              await sendOutboundWhatsApp(to, from, outboundContent);
            }
            log.push({ id: `${from}-${log.length}-a`, role: "assistant", content: outboundContent, timestamp: new Date().toISOString() });
            await saveConversation(from, log);
          }).catch(e => console.error("[whatsapp] RPR background error:", e.message));

          return res.send(twimlReply(ack));
        }
      }

      const reply = choice?.message?.content ?? "Sorry, I couldn't process your request. Please try again.";

      addToHistory(from, "assistant", reply);
      log.push({ id: `${from}-${log.length}-a`, role: "assistant", content: reply, timestamp: new Date().toISOString() });

      await saveConversation(from, log);

      return res.send(twimlReply(reply));
    } catch (e) {
      console.error("[whatsapp] OpenAI error:", e.message);
      return res.send(twimlReply("Sorry, something went wrong. Please try again shortly."));
    }
  });

  // ── WhatsApp admin config UI ───────────────────────────────────────────────

  app.get("/admin/whatsapp", (req, res) => {
    const cfg = loadWaConfig();
    const saved = req.query.saved === "1";
    const docUrl = `https://docs.google.com/document/d/${escHtml(cfg.doc_id)}/edit`;
    res.send(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WhatsApp Agent — Settings</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f5f5f7; color: #1d1d1f; }
  h1 { font-size: 1.6rem; font-weight: 700; padding: 24px 32px 0; }
  .subtitle { color: #6e6e73; font-size: 0.9rem; padding: 4px 32px 16px; }
  ${tabBarCss}
  .container { padding: 24px; max-width: 600px; }
  .card { background: #fff; border-radius: 12px; padding: 24px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); margin-bottom: 20px; }
  .card h2 { font-size: 1rem; font-weight: 600; margin-bottom: 16px; }
  label { display: block; font-size: 0.85rem; font-weight: 500; color: #6e6e73; margin-bottom: 6px; margin-top: 16px; }
  label:first-of-type { margin-top: 0; }
  input[type="text"] { width: 100%; padding: 10px 12px; border: 1px solid #d1d1d6; border-radius: 8px; font-size: 0.95rem; color: #1d1d1f; background: #fafafa; }
  input:focus { outline: none; border-color: #007aff; background: #fff; }
  .hint { font-size: 0.78rem; color: #8e8e93; margin-top: 4px; }
  .doc-link { display: inline-flex; align-items: center; gap: 6px; margin-top: 10px; padding: 8px 14px; background: #f0f7ff; border: 1px solid #b3d4ff; border-radius: 8px; color: #007aff; text-decoration: none; font-size: 0.88rem; font-weight: 500; }
  .doc-link:hover { background: #e0f0ff; }
  .toggle-row { display: flex; align-items: center; justify-content: space-between; padding: 12px 0; border-bottom: 1px solid #f2f2f7; }
  .toggle-row:last-child { border-bottom: none; padding-bottom: 0; }
  .toggle-label { font-size: 0.92rem; font-weight: 500; }
  .toggle-desc { font-size: 0.78rem; color: #6e6e73; margin-top: 2px; }
  .toggle { position: relative; width: 44px; height: 26px; flex-shrink: 0; }
  .toggle input { opacity: 0; width: 0; height: 0; }
  .slider { position: absolute; inset: 0; background: #d1d1d6; border-radius: 26px; cursor: pointer; transition: background 0.2s; }
  .slider:before { content: ""; position: absolute; height: 20px; width: 20px; left: 3px; bottom: 3px; background: #fff; border-radius: 50%; transition: transform 0.2s; }
  input:checked + .slider { background: #34c759; }
  input:checked + .slider:before { transform: translateX(18px); }
  .save-btn { margin-top: 4px; padding: 10px 24px; background: #007aff; color: #fff; border: none; border-radius: 8px; font-size: 0.95rem; font-weight: 600; cursor: pointer; }
  .save-btn:hover { background: #0062cc; }
  .banner { background: #e8ffe8; border: 1px solid #a3d9a3; color: #1a7a1a; border-radius: 8px; padding: 10px 14px; font-size: 0.9rem; margin-bottom: 16px; }
</style>
</head>
<body>
<h1>RoadMate</h1>
<p class="subtitle">WhatsApp Agent — Settings</p>
${adminTabBar("whatsapp")}
<div class="container">
  ${saved ? '<div class="banner">✓ Settings saved successfully.</div>' : ""}

  <div class="card">
    <h2>💬 WhatsApp Number</h2>
    <div style="font-size:1.3rem;font-weight:700;letter-spacing:0.02em;margin-bottom:6px">+1 (415) 523-8886</div>
    <p class="hint" style="margin-bottom:10px">This is the Twilio WhatsApp Sandbox number. To use it, send the message below once from WhatsApp:</p>
    <div style="display:inline-block;background:#f2f2f7;border-radius:8px;padding:8px 14px;font-family:monospace;font-size:0.95rem;font-weight:600;color:#1d1d1f;letter-spacing:0.01em">join deer-play</div>
    <p class="hint" style="margin-top:8px">Send that message to the number above from WhatsApp to join the sandbox and start chatting.</p>
  </div>

  <form method="POST" action="/admin/whatsapp">
    <div class="card">
      <h2>📄 Knowledge Base</h2>
      <label>Google Doc ID</label>
      <input type="text" name="doc_id" value="${escHtml(cfg.doc_id)}" placeholder="Google Doc ID" />
      <p class="hint">The document ID from the Google Doc URL. The agent fetches this doc as its knowledge base.</p>
      <a class="doc-link" href="${docUrl}" target="_blank" rel="noopener">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg>
        Open in Google Docs
      </a>
    </div>

    <div class="card">
      <h2>🛠️ Tools</h2>
      <div class="toggle-row">
        <div>
          <div class="toggle-label">RPR Market Report</div>
          <div class="toggle-desc">Generates a PDF market analysis report for a property address when requested.</div>
        </div>
        <label class="toggle">
          <input type="checkbox" name="rpr_enabled" value="1" ${cfg.rpr_enabled ? "checked" : ""}>
          <span class="slider"></span>
        </label>
      </div>
    </div>

    <button type="submit" class="save-btn">Save Settings</button>
  </form>
</div>
</body>
</html>`);
  });

  app.post("/admin/whatsapp", (req, res) => {
    const cfg = loadWaConfig();
    const body = req.body || {};
    cfg.doc_id = (body.doc_id || "").trim() || cfg.doc_id;
    cfg.rpr_enabled = body.rpr_enabled === "1";
    saveWaConfig(cfg);
    console.log("[whatsapp] Config saved:", cfg);
    res.redirect("/admin/whatsapp?saved=1");
  });
}
