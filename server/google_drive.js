import { createRequire } from "module";
import { google } from "googleapis";
import { getAuthorizedClient, getClientIdFromReq } from "./gmail.js";

const require = createRequire(import.meta.url);

const MAX_FILE_BYTES = 15 * 1024 * 1024; // 15 MB hard limit
const MAX_TEXT_CHARS = 12000;            // chars returned to the AI

async function extractText(buffer, mimeType) {
  if (mimeType === "application/pdf") {
    const pdfParse = require("pdf-parse");
    const data = await pdfParse(buffer);
    return data.text || "";
  }
  // Plain text, CSV, etc.
  return buffer.toString("utf-8");
}

export function registerDriveRoutes(app) {
  // ── Read file text content ────────────────────────────────────────────────
  // Supports: PDF, Google Docs (exported as text), Google Sheets (exported as CSV)
  app.get("/drive/read_file", async (req, res) => {
    const clientId = getClientIdFromReq(req);
    if (!clientId)
      return res.status(400).json({ ok: false, error: "Missing client_id" });

    const fileId = req.query.file_id;
    if (!fileId)
      return res.status(400).json({ ok: false, error: "Missing file_id" });

    const maxChars = Math.min(
      parseInt(req.query.max_chars) || MAX_TEXT_CHARS,
      MAX_TEXT_CHARS
    );

    try {
      const auth = await getAuthorizedClient(clientId);
      const drive = google.drive({ version: "v3", auth });

      // Fetch metadata first
      const meta = await drive.files.get({
        fileId,
        fields: "id,name,mimeType,size",
      });
      const { name, mimeType, size } = meta.data;
      const fileSize = parseInt(size || "0");

      console.log(`[drive] reading file "${name}" (${mimeType}, ${fileSize} bytes) for client_id=${clientId}`);

      if (fileSize > MAX_FILE_BYTES) {
        return res.json({
          ok: false,
          error: `File too large (${Math.round(fileSize / 1024 / 1024)} MB). Maximum is ${MAX_FILE_BYTES / 1024 / 1024} MB.`,
          file_name: name,
        });
      }

      let text = "";

      if (mimeType === "application/vnd.google-apps.document") {
        // Google Doc → export as plain text
        const exported = await drive.files.export(
          { fileId, mimeType: "text/plain" },
          { responseType: "arraybuffer" }
        );
        text = Buffer.from(exported.data).toString("utf-8");
      } else if (mimeType === "application/vnd.google-apps.spreadsheet") {
        // Google Sheet → export as CSV
        const exported = await drive.files.export(
          { fileId, mimeType: "text/csv" },
          { responseType: "arraybuffer" }
        );
        text = Buffer.from(exported.data).toString("utf-8");
      } else {
        // PDF or plain text — download binary then parse
        const downloaded = await drive.files.get(
          { fileId, alt: "media" },
          { responseType: "arraybuffer" }
        );
        text = await extractText(Buffer.from(downloaded.data), mimeType);
      }

      text = text.replace(/\s+/g, " ").trim();

      if (!text) {
        return res.json({
          ok: false,
          error:
            "No text could be extracted. The file may be a scanned image PDF (not machine-readable).",
          file_name: name,
        });
      }

      const truncated = text.length > maxChars;
      const output = truncated ? text.slice(0, maxChars) + "…" : text;

      res.json({
        ok: true,
        file_name: name,
        mime_type: mimeType,
        text: output,
        char_count: output.length,
        truncated,
      });
    } catch (e) {
      console.error(`[drive] read_file error for file_id=${fileId}:`, e.message);
      const status = e.message.includes("Not authorized") ? 401 : 500;
      res.status(status).json({ ok: false, error: e.message });
    }
  });
}
