import { getAuthorizedClient } from "./gmail.js";
import { google } from "googleapis";

const DOC_ID = "1Sze4u4xxcWZfQ2cU3WW8YFGJ3EOYIi1R7twzT-70cc0";
const CLIENT_ID = "mtCoxfJIzGRqWaxu1V-_CQ";

const SYSTEM_PERSONA = `You are a helpful assistant for Roman Balandin Realty. \
Answer user questions based on the provided knowledge base document. \
If a question is reasonable and related to real estate or topics covered in the document, \
you may answer from your general knowledge — but never hallucinate or make up specific details. \
If you don't know something, say so clearly and suggest the user contact the office directly.`;

// Doc cache
let docContent = null;
let docModifiedTime = null;

async function fetchDocIfChanged() {
  try {
    const authClient = await getAuthorizedClient(CLIENT_ID);
    const drive = google.drive({ version: "v3", auth: authClient });
    const docs = google.docs({ version: "v1", auth: authClient });

    const meta = await drive.files.get({ fileId: DOC_ID, fields: "modifiedTime" });
    const newModifiedTime = meta.data.modifiedTime;

    if (newModifiedTime === docModifiedTime && docContent !== null) return;

    const doc = await docs.documents.get({ documentId: DOC_ID });
    const body = doc.data.body?.content ?? [];
    let text = "";
    for (const el of body) {
      if (!el.paragraph) continue;
      for (const pe of el.paragraph.elements ?? []) {
        text += pe.textRun?.content ?? "";
      }
    }
    docContent = text.trim();
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

export function registerWhatsAppRoutes(app) {
  app.post("/whatsapp", async (req, res) => {
    res.set("Content-Type", "text/xml");

    const from = req.body?.From ?? "";
    const userMessage = (req.body?.Body ?? "").trim();

    if (!from || !userMessage) {
      return res.send("<Response></Response>");
    }

    await fetchDocIfChanged();

    const systemPrompt = `${SYSTEM_PERSONA}\n\n--- KNOWLEDGE BASE ---\n${docContent || "Knowledge base not available."}\n--- END ---`;

    addToHistory(from, "user", userMessage);

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
          temperature: 0.4,
        }),
      });

      const data = await r.json();
      const reply = data?.choices?.[0]?.message?.content ?? "Sorry, I couldn't process your request. Please try again.";

      addToHistory(from, "assistant", reply);
      return res.send(twimlReply(reply));
    } catch (e) {
      console.error("[whatsapp] OpenAI error:", e.message);
      return res.send(twimlReply("Sorry, something went wrong. Please try again shortly."));
    }
  });
}
