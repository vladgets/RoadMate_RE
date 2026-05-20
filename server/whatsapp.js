import { getAuthorizedClient } from "./gmail.js";
import { google } from "googleapis";
import { generateRprReport } from "./rpr.js";
import twilio from "twilio";

const DOC_ID = "1Sze4u4xxcWZfQ2cU3WW8YFGJ3EOYIi1R7twzT-70cc0";
const CLIENT_ID = "mtCoxfJIzGRqWaxu1V-_CQ";
const INTERNAL = "http://localhost:3000";

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
    const authClient = await getAuthorizedClient(CLIENT_ID);
    const drive = google.drive({ version: "v3", auth: authClient });
    const docs = google.docs({ version: "v1", auth: authClient });

    const meta = await drive.files.get({ fileId: DOC_ID, fields: "modifiedTime" });
    const newModifiedTime = meta.data.modifiedTime;

    if (newModifiedTime === docModifiedTime && docContent !== null) return;

    const doc = await docs.documents.get({ documentId: DOC_ID });
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
    const toNumber = req.body?.To ?? process.env.TWILIO_WHATSAPP_NUMBER ?? "whatsapp:+14155238886";
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
          tools: [RPR_TOOL],
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
            if (result.ok) {
              await sendOutboundWhatsApp(toNumber, from, `Here is your RPR market analysis report for ${address}:`, result.pdfUrl);
            } else {
              await sendOutboundWhatsApp(toNumber, from, `Sorry, I was unable to generate the RPR report for ${address}. Please try again later.`);
            }
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
}
