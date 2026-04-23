import fs from "fs";
import { google } from "googleapis";
import { processShowingTimeEmail } from "./showingtime_automation.js";

const SCOPES = [
  "https://www.googleapis.com/auth/gmail.readonly",
  "https://www.googleapis.com/auth/gmail.send",
  "https://www.googleapis.com/auth/calendar",
  "https://www.googleapis.com/auth/drive",
];
const TOKEN_DIR = process.env.GOOGLE_TOKEN_DIR || "/data/gmail_tokens";
const PUBSUB_TOPIC = process.env.PUBSUB_TOPIC;
const SHOWINGTIME_SENDER = "callcenter@showingtime.com";
const SHOWINGTIME_FORWARD_TO = process.env.SHOWINGTIME_FORWARD_TO || "vladgets@gmail.com";

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


function buildRawEmail({ to, subject, bodyText, attachmentText, attachmentFilename }) {
  const hasAttachment = attachmentText && attachmentFilename;
  const boundary = `rm_boundary_${Date.now()}_${Math.random().toString(36).slice(2)}`;

  let mime;
  if (!hasAttachment) {
    mime = [
      `To: ${to}`,
      `Subject: ${subject}`,
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=utf-8",
      "",
      bodyText,
    ].join("\r\n");
  } else {
    const attachB64 = Buffer.from(attachmentText, "utf-8").toString("base64");
    mime = [
      `To: ${to}`,
      `Subject: ${subject}`,
      "MIME-Version: 1.0",
      `Content-Type: multipart/mixed; boundary="${boundary}"`,
      "",
      `--${boundary}`,
      "Content-Type: text/plain; charset=utf-8",
      "",
      bodyText,
      "",
      `--${boundary}`,
      `Content-Type: text/plain; charset=utf-8; name="${attachmentFilename}"`,
      `Content-Disposition: attachment; filename="${attachmentFilename}"`,
      "Content-Transfer-Encoding: base64",
      "",
      attachB64,
      "",
      `--${boundary}--`,
    ].join("\r\n");
  }

  // Gmail API requires base64url encoding (no padding).
  return Buffer.from(mime).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

function buildRawEmailWithBuffer({ to, subject, bodyText, attachmentBuffer, attachmentFilename, contentType = "application/octet-stream" }) {
  const boundary = `rm_boundary_${Date.now()}_${Math.random().toString(36).slice(2)}`;
  // MIME requires base64 lines ≤76 chars
  const raw64 = attachmentBuffer.toString("base64").replace(/(.{76})/g, "$1\r\n");
  const mime = [
    `To: ${to}`,
    `Subject: ${subject}`,
    "MIME-Version: 1.0",
    `Content-Type: multipart/mixed; boundary="${boundary}"`,
    "",
    `--${boundary}`,
    "Content-Type: text/plain; charset=utf-8",
    "",
    bodyText,
    "",
    `--${boundary}`,
    `Content-Type: ${contentType}; name="${attachmentFilename}"`,
    `Content-Disposition: attachment; filename="${attachmentFilename}"`,
    "Content-Transfer-Encoding: base64",
    "",
    raw64,
    "",
    `--${boundary}--`,
  ].join("\r\n");
  return Buffer.from(mime).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

function findClientIdByEmail(email) {
  ensureTokenDir();
  try {
    const files = fs.readdirSync(TOKEN_DIR);
    for (const file of files) {
      if (!file.endsWith(".json")) continue;
      try {
        const data = JSON.parse(fs.readFileSync(`${TOKEN_DIR}/${file}`, "utf-8"));
        if (data.email_address && data.email_address.toLowerCase() === email.toLowerCase()) {
          return file.replace(".json", "");
        }
      } catch {}
    }
  } catch {}
  return null;
}

async function forwardEmail(gmail, msg, to) {
  const h = headerMap(msg);
  const originalSubject = h["subject"] || "(no subject)";
  const bodyText = extractBodyTextFromMessage(msg);

  const fwdBody = [
    "---------- Forwarded message ----------",
    `From: ${h["from"] || ""}`,
    `Date: ${h["date"] || ""}`,
    `Subject: ${originalSubject}`,
    "",
    bodyText,
  ].join("\n");

  const raw = buildRawEmail({ to, subject: `Fwd: ${originalSubject}`, bodyText: fwdBody });
  await gmail.users.messages.send({ userId: "me", requestBody: { raw } });
}

async function renewWatchIfNeeded(clientId, gmail) {
  if (!PUBSUB_TOPIC) return;
  const token = loadToken(clientId);
  if (!token) return;
  const expiry = Number(token.watch_expiry || 0);
  const twoDaysMs = 2 * 24 * 60 * 60 * 1000;
  if (expiry && Date.now() < expiry - twoDaysMs) return;

  const result = await gmail.users.watch({
    userId: "me",
    requestBody: { topicName: PUBSUB_TOPIC, labelIds: ["INBOX"] },
  });
  saveToken(clientId, { ...token, watch_expiry: Number(result.data.expiration) });
  console.log(`[gmail/watch] Renewed for client_id=${clientId}, expires=${new Date(Number(result.data.expiration)).toISOString()}`);
}

// Shared helpers exported for use by other Google service modules.
export { loadToken, getAuthorizedClient, sanitizeClientId, getClientIdFromReq, TOKEN_DIR, buildRawEmailWithBuffer };

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

      // Save tokens (covers Gmail + Calendar — both scopes requested)
      saveToken(clientId, tokens);
      console.log(`[google] OAuth token saved for client_id=${clientId}, scopes=${tokens.scope}`);

      // Cache the user's email address in the token file so we don't need to fetch it later.
      try {
        oauth2.setCredentials(tokens);
        const gmail = google.gmail({ version: "v1", auth: oauth2 });
        const profile = await gmail.users.getProfile({ userId: "me" });
        const emailAddress = profile.data.emailAddress;
        if (emailAddress) {
          const updated = { ...tokens, email_address: emailAddress };
          saveToken(clientId, updated);
          console.log(`[google] Cached email for client_id=${clientId}: ${emailAddress}`);
        }
      } catch (profileErr) {
        console.warn(`[google] Could not fetch profile email: ${profileErr.message}`);
      }

      // Auto-register Gmail push watch if Pub/Sub is configured.
      if (PUBSUB_TOPIC) {
        try {
          const gmailForWatch = google.gmail({ version: "v1", auth: oauth2 });
          const watchResult = await gmailForWatch.users.watch({
            userId: "me",
            requestBody: { topicName: PUBSUB_TOPIC, labelIds: ["INBOX"] },
          });
          const savedToken = loadToken(clientId);
          saveToken(clientId, {
            ...savedToken,
            history_id: String(watchResult.data.historyId),
            watch_expiry: Number(watchResult.data.expiration),
          });
          console.log(`[gmail/watch] Auto-registered for client_id=${clientId}, historyId=${watchResult.data.historyId}`);
        } catch (watchErr) {
          console.warn(`[gmail/watch] Auto-register failed: ${watchErr.message}`);
        }
      }

      return res.send("<p>Google account connected successfully. You can close this tab and return to RoadMate.</p>");
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });

  // Google account connection status (covers Gmail + Calendar — shared token)
  app.get("/oauth/google/status", (req, res) => {
    const clientId = getClientIdFromReq(req);
    if (!clientId)
      return res.status(400).json({ ok: false, error: "Missing client_id" });
    const token = loadToken(clientId);
    res.json({ ok: true, authorized: token !== null });
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

  // Get the authenticated user's Gmail profile (primarily to retrieve their email address).
  app.get("/gmail/profile", async (req, res) => {
    try {
      const clientId = getClientIdFromReq(req);
      if (!clientId) {
        return res.status(400).json({ ok: false, error: "Missing or invalid client_id." });
      }

      const token = loadToken(clientId);
      if (!token) {
        return res.status(401).json({ ok: false, error: "Not authorized. Complete Google OAuth first." });
      }

      // Return cached email if available.
      if (token.email_address) {
        return res.json({ ok: true, email_address: token.email_address });
      }

      // Fetch from Gmail API and cache it.
      const auth = await getAuthorizedClient(clientId);
      const gmail = google.gmail({ version: "v1", auth });
      const profile = await gmail.users.getProfile({ userId: "me" });
      const emailAddress = profile.data.emailAddress || null;

      if (emailAddress) {
        const updated = { ...token, email_address: emailAddress };
        saveToken(clientId, updated);
      }

      return res.json({ ok: true, email_address: emailAddress });
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });

  // Send an email via the authenticated Gmail account.
  app.post("/gmail/send", async (req, res) => {
    try {
      const clientId = getClientIdFromReq(req);
      if (!clientId) {
        return res.status(400).json({ ok: false, error: "Missing or invalid client_id." });
      }

      const body = req.body || {};
      const subject = cleanText(body.subject);
      const emailBody = typeof body.body === "string" ? body.body.trim() : "";
      const attachmentText = typeof body.attachment_text === "string" ? body.attachment_text.trim() : null;
      const attachmentFilename = typeof body.attachment_filename === "string" ? body.attachment_filename.trim() : null;

      if (!subject) {
        return res.status(400).json({ ok: false, error: "Missing required field: subject" });
      }
      if (!emailBody) {
        return res.status(400).json({ ok: false, error: "Missing required field: body" });
      }

      // Resolve recipient — default to the authenticated user's own email.
      let to = typeof body.to === "string" ? body.to.trim() : "";
      if (!to || to.toLowerCase() === "self" || to.toLowerCase() === "me") {
        const token = loadToken(clientId);
        to = token?.email_address || "";

        if (!to) {
          // Fetch from API as fallback.
          const authTemp = await getAuthorizedClient(clientId);
          const gmailTemp = google.gmail({ version: "v1", auth: authTemp });
          const profile = await gmailTemp.users.getProfile({ userId: "me" });
          to = profile.data.emailAddress || "";
          if (to) {
            const updated = { ...token, email_address: to };
            saveToken(clientId, updated);
          }
        }

        if (!to) {
          return res.status(400).json({ ok: false, error: "Could not determine recipient email. Please provide 'to' field." });
        }
      }

      const auth = await getAuthorizedClient(clientId);
      const gmail = google.gmail({ version: "v1", auth });

      const raw = buildRawEmail({ to, subject, bodyText: emailBody, attachmentText, attachmentFilename });

      const result = await gmail.users.messages.send({
        userId: "me",
        requestBody: { raw },
      });

      return res.json({ ok: true, message_id: result.data.id, to, subject });
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });

  // Register Gmail push notifications for a client.
  app.post("/gmail/watch", async (req, res) => {
    try {
      if (!PUBSUB_TOPIC) {
        return res.status(500).json({ ok: false, error: "PUBSUB_TOPIC env var not set on server" });
      }
      const clientId = getClientIdFromReq(req);
      if (!clientId) return res.status(400).json({ ok: false, error: "Missing client_id" });

      const auth = await getAuthorizedClient(clientId);
      const gmail = google.gmail({ version: "v1", auth });

      const result = await gmail.users.watch({
        userId: "me",
        requestBody: { topicName: PUBSUB_TOPIC, labelIds: ["INBOX"] },
      });

      const token = loadToken(clientId);
      const updated = {
        ...token,
        history_id: String(result.data.historyId),
        watch_expiry: Number(result.data.expiration),
      };

      // Backfill email_address if missing — needed for webhook routing.
      if (!updated.email_address) {
        try {
          const profile = await gmail.users.getProfile({ userId: "me" });
          if (profile.data.emailAddress) updated.email_address = profile.data.emailAddress;
        } catch {}
      }

      saveToken(clientId, updated);
      console.log(`[gmail/watch] Registered for client_id=${clientId}, historyId=${result.data.historyId}, email=${updated.email_address || "unknown"}`);
      return res.json({
        ok: true,
        historyId: result.data.historyId,
        expiration: result.data.expiration,
        expires_at: new Date(Number(result.data.expiration)).toISOString(),
      });
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });

  // Test endpoint: simulates a ShowingTime confirmation email and forwards it.
  app.post("/gmail/test_showingtime", async (req, res) => {
    try {
      const clientId = getClientIdFromReq(req);
      if (!clientId) return res.status(400).json({ ok: false, error: "Missing client_id" });

      const auth = await getAuthorizedClient(clientId);
      const gmail = google.gmail({ version: "v1", auth });

      const fakeSubject = "Showing Confirmed - 123 Main St, Springfield NJ 07081";
      const fakeBody = [
        "---------- Forwarded message ----------",
        "From: ShowingTime <callcenter@showingtime.com>",
        "Date: " + new Date().toUTCString(),
        "Subject: " + fakeSubject,
        "",
        "Your showing has been confirmed.",
        "",
        "Property: 123 Main St, Springfield NJ 07081",
        "Date: Friday, May 2, 2026",
        "Time: 2:00 PM - 2:30 PM",
        "Buyer Agent: Test Agent",
        "",
        "This is a test message generated by RoadMate.",
      ].join("\n");

      const raw = buildRawEmail({
        to: SHOWINGTIME_FORWARD_TO,
        subject: `Fwd: ${fakeSubject}`,
        bodyText: fakeBody,
      });

      await gmail.users.messages.send({ userId: "me", requestBody: { raw } });
      console.log(`[showingtime/test] Sent test forward to ${SHOWINGTIME_FORWARD_TO}`);
      return res.json({ ok: true, sent_to: SHOWINGTIME_FORWARD_TO, subject: `Fwd: ${fakeSubject}` });
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });

  // Gmail Pub/Sub push webhook — called by Google when new mail arrives.
  app.post("/gmail/webhook", async (req, res) => {
    // Respond 200 immediately so Pub/Sub doesn't retry.
    res.sendStatus(200);

    try {
      const message = req.body?.message;
      if (!message?.data) return;

      let decoded;
      try {
        decoded = JSON.parse(Buffer.from(message.data, "base64").toString("utf-8"));
      } catch {
        console.warn("[gmail/webhook] Failed to decode Pub/Sub message");
        return;
      }

      const emailAddress = decoded.emailAddress;
      const newHistoryId = decoded.historyId ? String(decoded.historyId) : null;
      if (!emailAddress || !newHistoryId) return;

      const clientId = findClientIdByEmail(emailAddress);
      if (!clientId) {
        console.warn(`[gmail/webhook] No client found for email: ${emailAddress}`);
        return;
      }

      const token = loadToken(clientId);
      const lastHistoryId = token?.history_id;

      if (!lastHistoryId) {
        // No baseline yet — save newHistoryId so next notification works.
        saveToken(clientId, { ...token, history_id: newHistoryId });
        console.warn(`[gmail/webhook] No history_id for client_id=${clientId}, saved baseline`);
        return;
      }

      const auth = await getAuthorizedClient(clientId);
      const gmail = google.gmail({ version: "v1", auth });

      let historyRes;
      try {
        historyRes = await gmail.users.history.list({
          userId: "me",
          startHistoryId: lastHistoryId,
          historyTypes: ["messageAdded"],
          labelId: "INBOX",
        });
      } catch (e) {
        // historyId too old or invalid — reset cursor and skip this notification.
        console.warn(`[gmail/webhook] history.list failed for client_id=${clientId}, resetting cursor: ${e.message}`);
        saveToken(clientId, { ...token, history_id: newHistoryId });
        return;
      }

      // Always advance the cursor.
      saveToken(clientId, { ...token, history_id: newHistoryId });

      const records = historyRes.data.history || [];
      for (const record of records) {
        for (const added of (record.messagesAdded || [])) {
          const msgId = added.message?.id;
          if (!msgId) continue;

          const msgRes = await gmail.users.messages.get({ userId: "me", id: msgId, format: "full" });
          const msg = msgRes.data;
          const from = (headerMap(msg)["from"] || "").toLowerCase();

          if (from.includes(SHOWINGTIME_SENDER)) {
            await forwardEmail(gmail, msg, SHOWINGTIME_FORWARD_TO);
            console.log(`[showingtime] Forwarded "${headerMap(msg)["subject"]}" → ${SHOWINGTIME_FORWARD_TO}`);

            // Async: parse email, fetch MLS PDF, create/update Calendar event.
            const bodyText = extractBodyTextFromMessage(msg);
            const clientAuth = await getAuthorizedClient(clientId);
            processShowingTimeEmail(clientAuth, bodyText).catch((e) =>
              console.error("[showingtime] Automation error:", e.message)
            );
          }
        }
      }

      // Renew watch subscription if close to expiry (auto-maintains the 7-day window).
      await renewWatchIfNeeded(clientId, gmail);

    } catch (e) {
      console.error("[gmail/webhook] Error:", e.message);
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