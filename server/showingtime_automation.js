import fs from "fs";
import { google } from "googleapis";
import { mlsSearchAndCapturePdf } from "./mls.js";
import { Readable } from "stream";

const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
const EVENTS_FILE = "/data/showingtime_events.json";

// ─── State: address+date → { calendarEventId, driveFileId } ─────────────────

function loadEventsMap() {
  try {
    if (fs.existsSync(EVENTS_FILE)) return JSON.parse(fs.readFileSync(EVENTS_FILE, "utf-8"));
  } catch {}
  return {};
}

function saveEventsMap(map) {
  try {
    fs.writeFileSync(EVENTS_FILE, JSON.stringify(map, null, 2), "utf-8");
  } catch (e) {
    console.warn("[showingtime] Could not save events map:", e.message);
  }
}

function eventKey(address, dateIso) {
  return `${address.toLowerCase().trim()}|${dateIso}`;
}

// ─── Parse email with OpenAI ─────────────────────────────────────────────────

async function parseShowingTimeEmail(bodyText) {
  const resp = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      messages: [{
        role: "user",
        content: `Extract showing appointment details from this ShowingTime email. Return JSON only with these fields:
- address (string: full property address including city, state, zip)
- date_iso (string: YYYY-MM-DD)
- start_time_iso (string: full ISO 8601 datetime with timezone offset, e.g. "2026-05-02T14:00:00-05:00")
- end_time_iso (string: full ISO 8601 datetime with timezone offset, or null if not found)
- buyer_agent (string or null)
- status (string: "confirmed", "cancelled", "requested", or "unknown")

Email:
${bodyText.slice(0, 4000)}`,
      }],
      response_format: { type: "json_object" },
      temperature: 0,
    }),
  });

  if (!resp.ok) throw new Error(`OpenAI parse error: ${resp.status}`);
  const data = await resp.json();
  const content = data.choices?.[0]?.message?.content;
  if (!content) return null;
  return JSON.parse(content);
}

// ─── Upload PDF to Google Drive ───────────────────────────────────────────────

async function uploadToDrive(drive, pdfBuffer, filename) {
  const stream = Readable.from(pdfBuffer);
  const result = await drive.files.create({
    requestBody: { name: filename, mimeType: "application/pdf" },
    media: { mimeType: "application/pdf", body: stream },
    fields: "id,webViewLink",
  });

  // Make readable by anyone with link so Calendar can display it.
  await drive.permissions.create({
    fileId: result.data.id,
    requestBody: { role: "reader", type: "anyone" },
  });

  return { fileId: result.data.id, webViewLink: result.data.webViewLink };
}

// ─── Create or update Google Calendar event ───────────────────────────────────

async function upsertCalendarEvent(calApi, showing, driveFileId, driveWebViewLink) {
  const eventsMap = loadEventsMap();
  const key = eventKey(showing.address, showing.date_iso);
  let existing = eventsMap[key];

  const endTime = showing.end_time_iso
    || new Date(new Date(showing.start_time_iso).getTime() + 30 * 60_000).toISOString();

  const eventBody = {
    summary: `Showing: ${showing.address}`,
    location: showing.address,
    description: [
      "ShowingTime confirmed showing.",
      showing.buyer_agent ? `Buyer Agent: ${showing.buyer_agent}` : null,
      driveFileId ? `MLS Listing PDF attached.` : null,
    ].filter(Boolean).join("\n"),
    start: { dateTime: showing.start_time_iso },
    end: { dateTime: endTime },
  };

  if (driveFileId) {
    // Calendar API requires fileUrl in the format drive.google.com/open?id=...
    const fileUrl = `https://drive.google.com/open?id=${driveFileId}`;
    console.log(`[showingtime] Attaching Drive file: ${driveFileId}, url: ${fileUrl}`);
    eventBody.attachments = [{
      fileId: driveFileId,
      fileUrl,
      title: "MLS Listing.pdf",
      mimeType: "application/pdf",
    }];
  }

  // If not in local state, search Calendar for an existing event at the same time + location.
  if (!existing?.calendarEventId) {
    try {
      const startDt = new Date(showing.start_time_iso);
      const windowStart = new Date(startDt.getTime() - 60_000).toISOString();
      const windowEnd = new Date(startDt.getTime() + 60_000).toISOString();
      const search = await calApi.events.list({
        calendarId: "primary",
        timeMin: windowStart,
        timeMax: windowEnd,
        singleEvents: true,
        q: showing.address,
      });
      const match = (search.data.items || []).find(e =>
        (e.summary || "").includes("Showing") && (e.location || "").includes(showing.address.split(",")[0])
      );
      if (match) {
        console.log(`[showingtime] Found existing calendar event ${match.id}, will update`);
        existing = { calendarEventId: match.id };
        eventsMap[key] = existing;
      }
    } catch (e) {
      console.warn(`[showingtime] Calendar search failed: ${e.message}`);
    }
  }

  let eventId;
  if (existing?.calendarEventId) {
    try {
      const resp = await calApi.events.patch({
        calendarId: "primary",
        eventId: existing.calendarEventId,
        requestBody: eventBody,
        supportsAttachments: true,
      });
      eventId = resp.data.id;
      console.log(`[showingtime] Updated calendar event ${eventId}`);
    } catch (e) {
      console.warn(`[showingtime] Patch failed (${e.message}), creating new event`);
      existing = null;
    }
  }

  if (!existing?.calendarEventId || !eventId) {
    const resp = await calApi.events.insert({
      calendarId: "primary",
      requestBody: eventBody,
      supportsAttachments: true,
    });
    eventId = resp.data.id;
    console.log(`[showingtime] Created calendar event ${eventId}`);
  }

  eventsMap[key] = {
    calendarEventId: eventId,
    driveFileId: driveFileId || existing?.driveFileId || null,
    address: showing.address,
    date: showing.date_iso,
    updatedAt: new Date().toISOString(),
  };
  saveEventsMap(eventsMap);
  return eventId;
}

// ─── Test routes ─────────────────────────────────────────────────────────────

export function registerShowingTimeTestRoutes(app, getAuthorizedClientFn) {
  // Step 1: Parse a ShowingTime email body → structured JSON
  app.post("/showingtime/test_parse", async (req, res) => {
    const { body_text } = req.body || {};
    if (!body_text) return res.status(400).json({ ok: false, error: "Missing body_text" });
    try {
      const result = await parseShowingTimeEmail(body_text);
      return res.json({ ok: true, parsed: result });
    } catch (e) {
      return res.status(500).json({ ok: false, error: e.message });
    }
  });

  // Step 2: Search MLS for an address and capture PDF
  app.post("/showingtime/test_mls_pdf", async (req, res) => {
    const { address } = req.body || {};
    if (!address) return res.status(400).json({ ok: false, error: "Missing address" });
    try {
      const result = await mlsSearchAndCapturePdf(address);
      return res.json({
        ok: result.ok,
        error: result.error || null,
        address: result.structured?.address || null,
        pdf_bytes: result.pdfBuffer ? result.pdfBuffer.length : 0,
        raw_text_preview: result.rawText?.slice(0, 500) || null,
      });
    } catch (e) {
      return res.status(500).json({ ok: false, error: e.message });
    }
  });

  // Step 3: Upload a dummy PDF to Google Drive
  app.post("/showingtime/test_drive_upload", async (req, res) => {
    const { getClientIdFromReq } = await import("./gmail.js");
    const clientId = getClientIdFromReq(req);
    if (!clientId) return res.status(400).json({ ok: false, error: "Missing client_id" });
    try {
      const auth = await getAuthorizedClientFn(clientId);
      const drive = google.drive({ version: "v3", auth });
      const dummyPdf = Buffer.from("%PDF-1.4 test");
      const uploaded = await uploadToDrive(drive, dummyPdf, "showingtime_test_upload.pdf");
      return res.json({ ok: true, file_id: uploaded.fileId, web_view_link: uploaded.webViewLink });
    } catch (e) {
      return res.status(500).json({ ok: false, error: e.message });
    }
  });

  // Step 4: Create a test Calendar event with optional Drive file attachment
  app.post("/showingtime/test_calendar", async (req, res) => {
    const { getClientIdFromReq } = await import("./gmail.js");
    const clientId = getClientIdFromReq(req);
    if (!clientId) return res.status(400).json({ ok: false, error: "Missing client_id" });
    const { drive_file_id, drive_web_view_link } = req.body || {};
    try {
      const auth = await getAuthorizedClientFn(clientId);
      const calApi = google.calendar({ version: "v3", auth });
      const start = new Date(Date.now() + 24 * 60 * 60_000); // tomorrow
      const end = new Date(start.getTime() + 30 * 60_000);
      const showing = {
        address: "123 Test St, Springfield NJ 07081",
        date_iso: start.toISOString().split("T")[0],
        start_time_iso: start.toISOString(),
        end_time_iso: end.toISOString(),
        buyer_agent: "Test Agent",
        status: "confirmed",
      };
      const eventId = await upsertCalendarEvent(calApi, showing, drive_file_id || null, drive_web_view_link || null);
      return res.json({ ok: true, event_id: eventId, showing });
    } catch (e) {
      return res.status(500).json({ ok: false, error: e.message });
    }
  });

  // Clear cached event state (forces next test_full to create a new event)
  app.post("/showingtime/reset_state", (req, res) => {
    try {
      if (fs.existsSync(EVENTS_FILE)) fs.unlinkSync(EVENTS_FILE);
      return res.json({ ok: true, message: "State cleared" });
    } catch (e) {
      return res.status(500).json({ ok: false, error: e.message });
    }
  });

  // Full pipeline with a fake email body
  app.post("/showingtime/test_full", async (req, res) => {
    const { getClientIdFromReq } = await import("./gmail.js");
    const clientId = getClientIdFromReq(req);
    if (!clientId) return res.status(400).json({ ok: false, error: "Missing client_id" });
    const { address, date, time } = req.body || {};
    const fakeEmail = [
      "Your showing has been confirmed.",
      `Property: ${address || "456 Oak Ave, Maplewood NJ 07040"}`,
      `Date: ${date || "Friday, May 2, 2026"}`,
      `Time: ${time || "2:00 PM - 2:30 PM"} Eastern`,
      "Buyer Agent: John Smith",
      "Status: Confirmed",
    ].join("\n");
    try {
      const auth = await getAuthorizedClientFn(clientId);
      res.json({ ok: true, message: "Pipeline started async, check Render logs", fake_email: fakeEmail });
      processShowingTimeEmail(auth, fakeEmail).catch((e) =>
        console.error("[showingtime/test_full] Error:", e.message)
      );
    } catch (e) {
      return res.status(500).json({ ok: false, error: e.message });
    }
  });
}

// ─── Main entry point ─────────────────────────────────────────────────────────

export async function processShowingTimeEmail(auth, emailBodyText) {
  // 1. Parse email
  let showing;
  try {
    showing = await parseShowingTimeEmail(emailBodyText);
  } catch (e) {
    console.error("[showingtime] Email parse failed:", e.message);
    return;
  }

  if (!showing?.address || !showing?.start_time_iso) {
    console.warn("[showingtime] Could not extract address/time from email, skipping automation");
    return;
  }

  if (showing.status === "cancelled") {
    console.log(`[showingtime] Email is a cancellation for ${showing.address}, skipping calendar create`);
    return;
  }

  console.log(`[showingtime] Automation: ${showing.address} @ ${showing.start_time_iso} (${showing.status})`);

  const drive = google.drive({ version: "v3", auth });
  const calApi = google.calendar({ version: "v3", auth });

  // 2. Search MLS and capture PDF
  let driveFileId = null;
  let driveWebViewLink = null;
  try {
    console.log(`[showingtime] Searching MLS for: ${showing.address}`);
    const mls = await mlsSearchAndCapturePdf(showing.address);
    if (mls.ok && mls.pdfBuffer) {
      const safeName = showing.address.replace(/[^a-zA-Z0-9\s]/g, "").replace(/\s+/g, "_");
      const filename = `Listing_${safeName}_${showing.date_iso}.pdf`;
      const uploaded = await uploadToDrive(drive, mls.pdfBuffer, filename);
      driveFileId = uploaded.fileId;
      driveWebViewLink = uploaded.webViewLink;
      console.log(`[showingtime] PDF uploaded to Drive: ${driveFileId}`);
    } else {
      console.warn(`[showingtime] MLS search returned no PDF: ${mls.error || "no pdfBuffer"}`);
    }
  } catch (e) {
    console.warn(`[showingtime] MLS/Drive step failed (non-fatal): ${e.message}`);
  }

  // 3. Create or update Calendar event
  try {
    await upsertCalendarEvent(calApi, showing, driveFileId, driveWebViewLink);
  } catch (e) {
    console.error(`[showingtime] Calendar upsert failed: ${e.message}`);
  }
}
