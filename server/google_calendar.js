import fs from "fs";
import path from "path";
import { google } from "googleapis";

const SCOPES = ["https://www.googleapis.com/auth/calendar"];
const TOKEN_DIR =
  process.env.CALENDAR_TOKEN_DIR || "/data/calendar_tokens";

const GOOGLE_CLIENT_ID = process.env.GOOGLE_CLIENT_ID;
const GOOGLE_CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET;
const BASE_URL = process.env.BASE_URL;
const REDIRECT_URI = BASE_URL
  ? `${BASE_URL}/oauth/google/calendar/callback`
  : null;

// ---------------------------------------------------------------------------
// Helpers (mirrors gmail.js pattern)
// ---------------------------------------------------------------------------

function sanitizeClientId(v) {
  if (typeof v !== "string") return null;
  const cid = v.trim();
  if (!cid) return null;
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

function ensureTokenDir() {
  if (!fs.existsSync(TOKEN_DIR))
    fs.mkdirSync(TOKEN_DIR, { recursive: true });
}

function tokenPathFor(clientId) {
  ensureTokenDir();
  return path.join(TOKEN_DIR, `${clientId}.json`);
}

function saveToken(clientId, token) {
  if (!clientId) throw new Error("saveToken: missing clientId");
  if (!token || typeof token !== "object")
    throw new Error(`saveToken: missing token for client_id=${clientId}`);
  fs.writeFileSync(tokenPathFor(clientId), JSON.stringify(token, null, 2), "utf-8");
}

function loadToken(clientId) {
  const p = tokenPathFor(clientId);
  if (!fs.existsSync(p)) return null;
  return JSON.parse(fs.readFileSync(p, "utf-8"));
}

function assertConfig() {
  const missing = [];
  if (!GOOGLE_CLIENT_ID) missing.push("GOOGLE_CLIENT_ID");
  if (!GOOGLE_CLIENT_SECRET) missing.push("GOOGLE_CLIENT_SECRET");
  if (!BASE_URL) missing.push("BASE_URL");
  if (missing.length) throw new Error(`Missing env vars: ${missing.join(", ")}`);
}

function makeOAuth2Client() {
  assertConfig();
  return new google.auth.OAuth2(GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, REDIRECT_URI);
}

async function getAuthorizedClient(clientId) {
  const oauth2 = makeOAuth2Client();
  const token = loadToken(clientId);
  if (!token) {
    throw new Error(
      `Not authorized for client_id=${clientId}. Open /oauth/google/calendar/start?client_id=${clientId} first.`
    );
  }
  oauth2.setCredentials(token);
  await oauth2.getAccessToken(); // auto-refresh if expired
  const updated = oauth2.credentials;
  if (updated && Object.keys(updated).length > 0) saveToken(clientId, updated);
  return oauth2;
}

function parseDate(str, fallback) {
  if (!str) return fallback;
  const d = new Date(str);
  return isNaN(d.getTime()) ? fallback : d;
}

// ---------------------------------------------------------------------------
// Route registration
// ---------------------------------------------------------------------------

export function registerCalendarRoutes(app) {
  // ── OAuth: start ──────────────────────────────────────────────────────────
  app.get("/oauth/google/calendar/start", (req, res) => {
    const clientId = getClientIdFromReq(req);
    if (!clientId)
      return res.status(400).json({ ok: false, error: "Missing client_id" });

    try {
      const oauth2 = makeOAuth2Client();
      const url = oauth2.generateAuthUrl({
        access_type: "offline",
        prompt: "consent",
        scope: SCOPES,
        state: clientId,
      });
      res.redirect(url);
    } catch (e) {
      res.status(500).json({ ok: false, error: e.message });
    }
  });

  // ── OAuth: callback ───────────────────────────────────────────────────────
  app.get("/oauth/google/calendar/callback", async (req, res) => {
    const { code, state: rawClientId, error } = req.query;

    if (error) {
      return res
        .status(400)
        .send(`<p>Authorization denied: ${error}. You can close this tab.</p>`);
    }

    if (!code || !rawClientId)
      return res.status(400).json({ ok: false, error: "Missing code or state" });

    const clientId = sanitizeClientId(rawClientId);
    if (!clientId)
      return res.status(400).json({ ok: false, error: "Invalid client_id in state" });

    try {
      const oauth2 = makeOAuth2Client();
      const { tokens } = await oauth2.getToken(code);
      saveToken(clientId, tokens);
      console.log(`[calendar] OAuth token saved for client_id=${clientId}, scopes=${tokens.scope}`);
      res.send(
        "<p>Google Calendar connected successfully. You can close this tab and return to RoadMate.</p>"
      );
    } catch (e) {
      console.error(`[calendar] OAuth callback error for client_id=${clientId}:`, e.message);
      res.status(500).json({ ok: false, error: e.message });
    }
  });

  // ── Status ────────────────────────────────────────────────────────────────
  app.get("/calendar/status", (req, res) => {
    const clientId = getClientIdFromReq(req);
    if (!clientId)
      return res.status(400).json({ ok: false, error: "Missing client_id" });
    const token = loadToken(clientId);
    res.json({ ok: true, authorized: token !== null });
  });

  // ── Get events ────────────────────────────────────────────────────────────
  app.get("/calendar/events", async (req, res) => {
    const clientId = getClientIdFromReq(req);
    if (!clientId)
      return res.status(400).json({ ok: false, error: "Missing client_id" });

    try {
      const auth = await getAuthorizedClient(clientId);
      const calApi = google.calendar({ version: "v3", auth });

      const now = new Date();
      const defaultStart = new Date(now);
      defaultStart.setDate(defaultStart.getDate() - 7);
      const defaultEnd = new Date(now);
      defaultEnd.setDate(defaultEnd.getDate() + 7);

      const startDate = parseDate(req.query.start_date, defaultStart);
      const endDate = parseDate(req.query.end_date, defaultEnd);

      console.log(`[calendar] fetching events for client_id=${clientId}, range=${startDate.toISOString()} → ${endDate.toISOString()}`);

      const calListRes = await calApi.calendarList.list({ minAccessRole: "reader" });
      const calendars = calListRes.data.items || [];

      const allEvents = [];

      for (const cal of calendars) {
        try {
          const eventsRes = await calApi.events.list({
            calendarId: cal.id,
            timeMin: startDate.toISOString(),
            timeMax: endDate.toISOString(),
            singleEvents: true,
            orderBy: "startTime",
            maxResults: 100,
          });

          for (const evt of eventsRes.data.items || []) {
            allEvents.push({
              event_id: evt.id || "",
              title: evt.summary || "",
              start: evt.start?.dateTime || evt.start?.date || "",
              end: evt.end?.dateTime || evt.end?.date || "",
              description: evt.description || "",
              location: evt.location || "",
              calendar: cal.summary || "",
              calendar_id: cal.id || "",
            });
          }
        } catch (e) {
          console.warn(`[calendar] skip cal "${cal.summary}": ${e.message}`);
        }
      }

      allEvents.sort((a, b) => a.start.localeCompare(b.start));

      const writableCalendars = calendars
        .filter((c) => c.accessRole === "owner" || c.accessRole === "writer")
        .map((c) => ({
          id: c.id,
          name: c.summary || "",
          is_primary: c.primary === true,
        }));

      const today = new Date();
      res.json({
        ok: true,
        today: today.toISOString().split("T")[0],
        events: allEvents,
        count: allEvents.length,
        date_range: {
          start: startDate.toISOString(),
          end: endDate.toISOString(),
        },
        writable_calendars: writableCalendars,
      });
    } catch (e) {
      console.error(`[calendar] /calendar/events error for client_id=${clientId}:`, e.message);
      const status = e.message.includes("Not authorized") ? 401 : 500;
      res.status(status).json({ ok: false, error: e.message });
    }
  });

  // ── Create event ──────────────────────────────────────────────────────────
  app.post("/calendar/create", async (req, res) => {
    const clientId = getClientIdFromReq(req);
    if (!clientId)
      return res.status(400).json({ ok: false, error: "Missing client_id" });

    const { title, start, end, description, location, calendar_id } = req.body || {};
    if (!title) return res.status(400).json({ ok: false, error: "title is required" });
    if (!start) return res.status(400).json({ ok: false, error: "start is required" });

    try {
      const auth = await getAuthorizedClient(clientId);
      const calApi = google.calendar({ version: "v3", auth });

      const startDt = new Date(start);
      const endDt = end ? new Date(end) : new Date(startDt.getTime() + 3_600_000);

      const eventBody = {
        summary: title,
        start: { dateTime: startDt.toISOString() },
        end: { dateTime: endDt.toISOString() },
      };
      if (description) eventBody.description = description;
      if (location) eventBody.location = location;

      const calId = calendar_id || "primary";
      const response = await calApi.events.insert({
        calendarId: calId,
        requestBody: eventBody,
      });
      const evt = response.data;

      res.json({
        ok: true,
        event_id: evt.id || "",
        title: evt.summary || "",
        start: evt.start?.dateTime || evt.start?.date || "",
        end: evt.end?.dateTime || evt.end?.date || "",
        calendar: calId,
      });
    } catch (e) {
      const status = e.message.includes("Not authorized") ? 401 : 500;
      res.status(status).json({ ok: false, error: e.message });
    }
  });

  // ── Update event ──────────────────────────────────────────────────────────
  app.patch("/calendar/update", async (req, res) => {
    const clientId = getClientIdFromReq(req);
    if (!clientId)
      return res.status(400).json({ ok: false, error: "Missing client_id" });

    const { event_id, calendar_id, title, start, end, description, location } =
      req.body || {};
    if (!event_id)
      return res.status(400).json({ ok: false, error: "event_id is required" });

    try {
      const auth = await getAuthorizedClient(clientId);
      const calApi = google.calendar({ version: "v3", auth });

      const calId = calendar_id || "primary";

      // Fetch existing to preserve duration when only start changes
      const existing = await calApi.events.get({ calendarId: calId, eventId: event_id });
      const base = existing.data;

      const patch = {};
      if (title) patch.summary = title;
      if (start) {
        patch.start = { dateTime: new Date(start).toISOString() };
        if (!end && base.start && base.end) {
          const origDuration =
            new Date(base.end.dateTime || base.end.date).getTime() -
            new Date(base.start.dateTime || base.start.date).getTime();
          patch.end = {
            dateTime: new Date(new Date(start).getTime() + origDuration).toISOString(),
          };
        }
      }
      if (end) patch.end = { dateTime: new Date(end).toISOString() };
      if (description !== undefined) patch.description = description;
      if (location !== undefined) patch.location = location;

      const response = await calApi.events.patch({
        calendarId: calId,
        eventId: event_id,
        requestBody: patch,
      });
      const evt = response.data;

      res.json({
        ok: true,
        event_id: evt.id || "",
        title: evt.summary || "",
        start: evt.start?.dateTime || evt.start?.date || "",
        end: evt.end?.dateTime || evt.end?.date || "",
      });
    } catch (e) {
      const status = e.message.includes("Not authorized") ? 401 : 500;
      res.status(status).json({ ok: false, error: e.message });
    }
  });

  // ── Delete event ──────────────────────────────────────────────────────────
  app.delete("/calendar/delete", async (req, res) => {
    const clientId = getClientIdFromReq(req);
    if (!clientId)
      return res.status(400).json({ ok: false, error: "Missing client_id" });

    const event_id = req.body?.event_id || req.query.event_id;
    const calendar_id = req.body?.calendar_id || req.query.calendar_id;

    if (!event_id)
      return res.status(400).json({ ok: false, error: "event_id is required" });

    try {
      const auth = await getAuthorizedClient(clientId);
      const calApi = google.calendar({ version: "v3", auth });

      const calId = calendar_id || "primary";
      await calApi.events.delete({ calendarId: calId, eventId: event_id });

      res.json({ ok: true, event_id, message: "Event deleted successfully." });
    } catch (e) {
      const status = e.message.includes("Not authorized") ? 401 : 500;
      res.status(status).json({ ok: false, error: e.message });
    }
  });
}
