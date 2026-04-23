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

async function upsertCalendarEvent(calApi, showing, driveFileId) {
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
    eventBody.attachments = [{
      fileId: driveFileId,
      title: "MLS Listing.pdf",
      mimeType: "application/pdf",
    }];
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
      // Event may have been deleted — fall through to create a new one.
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
  try {
    console.log(`[showingtime] Searching MLS for: ${showing.address}`);
    const mls = await mlsSearchAndCapturePdf(showing.address);
    if (mls.ok && mls.pdfBuffer) {
      const safeName = showing.address.replace(/[^a-zA-Z0-9\s]/g, "").replace(/\s+/g, "_");
      const filename = `Listing_${safeName}_${showing.date_iso}.pdf`;
      const uploaded = await uploadToDrive(drive, mls.pdfBuffer, filename);
      driveFileId = uploaded.fileId;
      console.log(`[showingtime] PDF uploaded to Drive: ${driveFileId}`);
    } else {
      console.warn(`[showingtime] MLS search returned no PDF: ${mls.error || "no pdfBuffer"}`);
    }
  } catch (e) {
    console.warn(`[showingtime] MLS/Drive step failed (non-fatal): ${e.message}`);
  }

  // 3. Create or update Calendar event
  try {
    await upsertCalendarEvent(calApi, showing, driveFileId);
  } catch (e) {
    console.error(`[showingtime] Calendar upsert failed: ${e.message}`);
  }
}
