import { google } from "googleapis";
import {
  loadToken,
  getAuthorizedClient,
  getClientIdFromReq,
} from "./gmail.js";

// OAuth and token storage are handled by gmail.js (shared token, combined scopes).
// This module only registers the Calendar API proxy routes.

function parseDate(str, fallback, endOfDay = false) {
  if (!str) return fallback;
  const d = new Date(str);
  if (isNaN(d.getTime())) return fallback;
  // Date-only strings (YYYY-MM-DD) are parsed as UTC midnight by JS.
  // When used as an end boundary, push to 23:59:59 UTC so the full day is included.
  if (endOfDay && /^\d{4}-\d{2}-\d{2}$/.test(str)) {
    d.setUTCHours(23, 59, 59, 999);
  }
  return d;
}

export function registerCalendarRoutes(app) {
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
      const endDate = parseDate(req.query.end_date, defaultEnd, true);

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
            supportsAttachments: true,
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
              attachments: (evt.attachments || []).map((a) => ({
                file_id: a.fileId || "",
                title: a.title || "",
                mime_type: a.mimeType || "",
              })),
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
      const response = await calApi.events.insert({ calendarId: calId, requestBody: eventBody });
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

    const { event_id, calendar_id, title, start, end, description, location } = req.body || {};
    if (!event_id)
      return res.status(400).json({ ok: false, error: "event_id is required" });

    try {
      const auth = await getAuthorizedClient(clientId);
      const calApi = google.calendar({ version: "v3", auth });

      const calId = calendar_id || "primary";
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
