import fs from "fs";
import { google } from "googleapis";

const SCOPES = ["https://www.googleapis.com/auth/gmail.readonly"];
const TOKEN_DIR = process.env.GOOGLE_TOKEN_DIR || "/data/gmail_tokens";

// GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, BASE_URL
const GOOGLE_CLIENT_ID = process.env.GOOGLE_CLIENT_ID;
const GOOGLE_CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET;
const BASE_URL = process.env.BASE_URL; // e.g. https://roadmate-flutter.onrender.com
const REDIRECT_URI = BASE_URL ? `${BASE_URL}/oauth/google/callback` : null;

function ensureTokenDir() {
  if (!fs.existsSync(TOKEN_DIR)) {
    fs.mkdirSync(TOKEN_DIR, { recursive: true });
  }
}

function sanitizeClientId(v) {
  if (typeof v !== "string") return null;
  const cid = v.trim();
  if (!cid) return null;
  // Allow only safe filename characters
  if (!/^[a-zA-Z0-9_-]{4,80}$/.test(cid)) return null;
  return cid;
}

function getClientIdFromReq(req) {
  return (
    sanitizeClientId(req.get("X-Client-Id")) ||
    sanitizeClientId(req.query.client_id) ||
    sanitizeClientId(req.body?.client_id)
  );
}

function tokenPathFor(clientId) {
  ensureTokenDir();
  return `${TOKEN_DIR}/${clientId}.json`;
}

// REQUIRED env vars for production (don't hardcode these):
function assertConfig() {
  const missing = [];
  if (!GOOGLE_CLIENT_ID) missing.push("GOOGLE_CLIENT_ID");
  if (!GOOGLE_CLIENT_SECRET) missing.push("GOOGLE_CLIENT_SECRET");
  if (!BASE_URL) missing.push("BASE_URL");
  if (missing.length) {
    throw new Error(`Missing env vars: ${missing.join(", ")}`);
  }
}

function makeOAuth2Client() {
  assertConfig();
  return new google.auth.OAuth2(GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, REDIRECT_URI);
}

function saveToken(clientId, token) {
  if (!clientId) {
    throw new Error("saveToken: missing clientId");
  }
  if (!token || typeof token !== "object") {
    throw new Error(`saveToken: missing token for client_id=${clientId}`);
  }  
  const p = tokenPathFor(clientId);
  fs.writeFileSync(p, JSON.stringify(token, null, 2), "utf-8");
}

function loadToken(clientId) {
  const p = tokenPathFor(clientId);
  if (!fs.existsSync(p)) return null;

  const raw = fs.readFileSync(p, "utf-8");
  return JSON.parse(raw);
}

async function getAuthorizedClient(clientId) {
  const oauth2 = makeOAuth2Client();
  const token = loadToken(clientId);
  if (!token) {
    throw new Error(`Not authorized for client_id=${clientId}. Visit /oauth/google/start?client_id=${clientId} first.`);
  }
  oauth2.setCredentials(token);

  // Ensure access token is valid / refresh if needed.
  await oauth2.getAccessToken();

  // Save updated tokens (sometimes Google returns a new access token).
  const updated = oauth2.credentials;
  if (updated && Object.keys(updated).length > 0) {
    saveToken(clientId, updated);
  }

  return oauth2;
}

function parseMaxResults(v, fallback = 5) {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.min(n, 50);
}

function clampInt(v, { min, max }) {
  const n = Number(v);
  if (!Number.isFinite(n)) return null;
  const i = Math.trunc(n);
  if (i < min || i > max) return null;
  return i;
}

function cleanText(v) {
  if (typeof v !== "string") return "";
  return v.replace(/\s+/g, " ").trim();
}

function buildGmailQuery({ text, from, subject, unread_only, in_inbox, newer_than_days }) {
  const parts = [];

  // Default not to inbox for voice use
  if (in_inbox == true) parts.push("in:inbox");
  if (unread_only === true) parts.push("is:unread");

  const fromText = cleanText(from);
  if (fromText) parts.push(`from:${fromText}`);

  const subjectText = cleanText(subject);
  if (subjectText) parts.push(`subject:(${subjectText})`);

  const nd = clampInt(newer_than_days, { min: 1, max: 365 });
  if (nd != null) 
    parts.push(`newer_than:${nd}d`);
  else
    parts.push(`newer_than:7d`); // default to recent emails

  const free = cleanText(text);
  if (free) parts.push(free);

  return parts.join(" ").trim();
}

function headerMap(msg) {
  const headers = msg.payload?.headers || [];
  return Object.fromEntries(headers.map((x) => [String(x.name || "").toLowerCase(), x.value || ""]));
}

function compactSnippet(s, maxLen = 180) {
  const t = String(s || "").replace(/\s+/g, " ").trim();
  if (t.length <= maxLen) return t;
  return t.slice(0, maxLen - 1) + "…";
}

function b64urlToString(data) {
  if (!data || typeof data !== "string") return "";
  // Gmail uses base64url without padding.
  const b64 = data.replace(/-/g, "+").replace(/_/g, "/");
  const padLen = (4 - (b64.length % 4)) % 4;
  const padded = b64 + "=".repeat(padLen);
  return Buffer.from(padded, "base64").toString("utf-8");
}

function stripHtml(html) {
  const s = String(html || "");
  // Very simple HTML to text: remove script/style, tags, decode common entities.
  const noScripts = s
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ");
  const noTags = noScripts.replace(/<[^>]+>/g, " ");
  return noTags
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}

function collectParts(payload, out = []) {
  if (!payload) return out;
  out.push(payload);
  const parts = payload.parts || [];
  for (const p of parts) collectParts(p, out);
  return out;
}

function extractBodyTextFromMessage(msg, maxChars = 12000) {
  const payload = msg?.payload;
  if (!payload) return "";

  const parts = collectParts(payload);

  // Prefer text/plain
  for (const p of parts) {
    if (p?.mimeType === "text/plain" && p?.body?.data) {
      const t = b64urlToString(p.body.data);
      if (t) return t.length > maxChars ? t.slice(0, maxChars) + "…" : t;
    }
  }

  // Fallback to text/html
  for (const p of parts) {
    if (p?.mimeType === "text/html" && p?.body?.data) {
      const html = b64urlToString(p.body.data);
      const txt = stripHtml(html);
      if (txt) return txt.length > maxChars ? txt.slice(0, maxChars) + "…" : txt;
    }
  }

  // Last resort: top-level body
  if (payload?.body?.data) {
    const t = b64urlToString(payload.body.data);
    if (t) return t.length > maxChars ? t.slice(0, maxChars) + "…" : t;
  }

  return "";
}


//
// Exposed APIs
export function registerGmailRoutes(app) {
  // Start OAuth
  app.get("/oauth/google/start", (req, res) => {
    try {
      const oauth2 = makeOAuth2Client();

      const clientId = getClientIdFromReq(req);
      if (!clientId) {
        return res.status(400).json({ ok: false, error: "Missing or invalid client_id. Provide ?client_id=XXXX (4-80 chars: letters/digits/_/-) or header X-Client-Id." });
      }

      // prompt=consent ensures you get refresh_token (often only on first consent)
      const authUrl = oauth2.generateAuthUrl({
        access_type: "offline",
        scope: SCOPES,
        include_granted_scopes: true,
        prompt: "consent",
        state: clientId,        
      });

      console.log("REDIRECT_URI =", REDIRECT_URI);
      console.log("AUTH_URL =", authUrl);

      return res.redirect(authUrl);
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });

  // OAuth callback
  app.get("/oauth/google/callback", async (req, res) => {
    try {
      const code = req.query.code;
      if (!code || typeof code !== "string") {
        return res.status(400).json({ ok: false, error: "Missing code" });
      }

      const state = req.query.state;
      const clientId = sanitizeClientId(typeof state === "string" ? state : "");
      if (!clientId) {
        return res.status(400).json({ ok: false, error: "Missing or invalid state (client_id)." });
      }

      const oauth2 = makeOAuth2Client();
      const { tokens } = await oauth2.getToken(code);
      oauth2.setCredentials(tokens);

      // Save tokens for later Gmail calls
      saveToken(clientId, tokens);

      return res.json({ ok: true, client_id: clientId, message: "Gmail authorized. You can close this tab." });
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });

  // Search Gmail
  app.get("/gmail/search", async (req, res) => {
    try {
      const clientId = getClientIdFromReq(req);
      if (!clientId) {
        return res.status(400).json({ ok: false, error: "Missing or invalid client_id. Provide header X-Client-Id or ?client_id=..." });
      }

      const q = req.query.q;
      if (!q || typeof q !== "string") {
        return res.status(400).json({ ok: false, error: "Missing required query param: q" });
      }
      const maxResults = parseMaxResults(req.query.max_results, 5);

      const auth = await getAuthorizedClient(clientId);
      const gmail = google.gmail({ version: "v1", auth });

      const r = await gmail.users.messages.list({
        userId: "me",
        q,
        maxResults,
      });

      const msgs = r.data.messages || [];
      return res.json({ ok: true, message_ids: msgs.map((m) => m.id) });
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });

  // Search Gmail with structured parameters (voice-friendly)
  app.post("/gmail/search_structured", async (req, res) => {
    try {
      const clientId = getClientIdFromReq(req);
      if (!clientId) {
        return res.status(400).json({ ok: false, error: "Missing or invalid client_id. Provide header X-Client-Id or body.client_id." });
      }

      const body = req.body || {};

      const q = buildGmailQuery({
        text: body.text,
        from: body.from,
        subject: body.subject,
        unread_only: body.unread_only,
        in_inbox: body.in_inbox,
        newer_than_days: body.newer_than_days,
      });

      const maxResults = parseMaxResults(body.max_results, 5);

      if (!q) {
        return res.status(400).json({ ok: false, error: "Empty search. Provide at least one of: text, from, subject, unread_only, newer_than_days." });
      }

      const auth = await getAuthorizedClient(clientId);
      const gmail = google.gmail({ version: "v1", auth });

      const list = await gmail.users.messages.list({
        userId: "me",
        q,
        maxResults,
      });

      const ids = (list.data.messages || []).map((m) => m.id).filter(Boolean);
      if (ids.length === 0) {
        return res.json({ ok: true, query: q, results: [] });
      }

      const cards = await Promise.all(
        ids.map(async (id) => {
          const r = await gmail.users.messages.get({
            userId: "me",
            id,
            format: "metadata",
            metadataHeaders: ["From", "Subject", "Date"],
          });

          const msg = r.data;
          const h = headerMap(msg);

          return {
            messageId: msg.id,
            threadId: msg.threadId,
            internalDate: Number(msg.internalDate || 0),
            subject: h["subject"] || "",
            from: h["from"] || "",
            date: h["date"] || "",
            snippet: compactSnippet(msg.snippet || ""),
          };
        })
      );

      // Collapse to one candidate per thread: pick the latest message among matches.
      const byThread = new Map();
      for (const c of cards) {
        const key = c.threadId || c.id;
        const prev = byThread.get(key);
        if (!prev) {
          byThread.set(key, { best: c, count: 1 });
        } else {
          prev.count += 1;
          const prevDate = Number(prev.best.internalDate || 0);
          const curDate = Number(c.internalDate || 0);
          if (curDate >= prevDate) {
            prev.best = c;
          }
        }
      }

      const collapsed = Array.from(byThread.values())
        .map(({ best, count }) => ({
          messageId: best.messageId,
          threadId: best.threadId,
          subject: best.subject,
          from: best.from,
          date: best.date,
          // Thread "summary": show how many matched messages we saw, plus the latest snippet.
          matched_count: count,
          snippet: count > 1 ? `(${count} msgs) ${best.snippet}` : best.snippet,
        }))
        // Sort newest first (best-effort using internalDate we captured)
        .sort((a, b) => {
          const ad = Number((cards.find((x) => x.id === a.id)?.internalDate) || 0);
          const bd = Number((cards.find((x) => x.id === b.id)?.internalDate) || 0);
          return bd - ad;
        });

      // Respect maxResults as a limit on threads returned.
      const results = collapsed.slice(0, maxResults);

      return res.json({ ok: true, query: q, results });
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });

  // Read Gmail (metadata)
  app.get("/gmail/read", async (req, res) => {
    try {
      const clientId = getClientIdFromReq(req);
      if (!clientId) {
        return res.status(400).json({ ok: false, error: "Missing or invalid client_id. Provide header X-Client-Id or ?client_id=..." });
      }

      const id = req.query.id;
      if (!id || typeof id !== "string") {
        return res.status(400).json({ ok: false, error: "Missing required query param: id" });
      }

      const auth = await getAuthorizedClient(clientId);
      const gmail = google.gmail({ version: "v1", auth });

      const r = await gmail.users.messages.get({
        userId: "me",
        id,
        format: "metadata",
      });

      const msg = r.data;
      const headers = msg.payload?.headers || [];
      const h = Object.fromEntries(headers.map((x) => [String(x.name || "").toLowerCase(), x.value || ""]));

      return res.json({
        ok: true,
        id: msg.id,
        threadId: msg.threadId,
        snippet: msg.snippet || "",
        subject: h["subject"] || "",
        from: h["from"] || "",
        date: h["date"] || "",
      });
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });

  // Read Gmail (full body text)
  app.get("/gmail/read_full", async (req, res) => {
    try {
      const clientId = getClientIdFromReq(req);
      if (!clientId) {
        return res.status(400).json({ ok: false, error: "Missing or invalid client_id. Provide header X-Client-Id or ?client_id=..." });
      }

      const id = req.query.id;
      if (!id || typeof id !== "string") {
        return res.status(400).json({ ok: false, error: "Missing required query param: id" });
      }

      const auth = await getAuthorizedClient(clientId);
      const gmail = google.gmail({ version: "v1", auth });

      const r = await gmail.users.messages.get({
        userId: "me",
        id,
        format: "full",
      });

      const msg = r.data;
      const headers = msg.payload?.headers || [];
      const h = Object.fromEntries(headers.map((x) => [String(x.name || "").toLowerCase(), x.value || ""]));

      const body_text = extractBodyTextFromMessage(msg);

      return res.json({
        ok: true,
        id: msg.id,
        threadId: msg.threadId,
        subject: h["subject"] || "",
        from: h["from"] || "",
        date: h["date"] || "",
        snippet: msg.snippet || "",
        body_text,
      });
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });

  // Read Gmail thread (whole conversation)
  app.get("/gmail/thread", async (req, res) => {
    try {
      const clientId = getClientIdFromReq(req);
      if (!clientId) {
        return res.status(400).json({ ok: false, error: "Missing or invalid client_id. Provide header X-Client-Id or ?client_id=..." });
      }

      const id = req.query.id;
      if (!id || typeof id !== "string") {
        return res.status(400).json({ ok: false, error: "Missing required query param: id (threadId)" });
      }

      const auth = await getAuthorizedClient(clientId);
      const gmail = google.gmail({ version: "v1", auth });

      const r = await gmail.users.threads.get({
        userId: "me",
        id,
        format: "full",
      });

      const thread = r.data;
      const messages = thread.messages || [];

      const items = messages.map((m) => {
        const headers = m.payload?.headers || [];
        const h = Object.fromEntries(headers.map((x) => [String(x.name || "").toLowerCase(), x.value || ""]));
        return {
          id: m.id,
          threadId: m.threadId,
          subject: h["subject"] || "",
          from: h["from"] || "",
          date: h["date"] || "",
          snippet: m.snippet || "",
          body_text: extractBodyTextFromMessage(m, 6000),
        };
      });

      return res.json({
        ok: true,
        threadId: thread.id,
        historyId: thread.historyId || null,
        message_count: items.length,
        messages: items,
      });
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });


}