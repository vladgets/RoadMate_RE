/**
 * Test mlsSearchAndCapturePdf locally.
 * Saves the captured PDF to /tmp/listing_test.pdf for visual inspection.
 *
 * Run:
 *   cd server && MLS_USERNAME=mo.33875 MLS_PASSWORD='...' OPENAI_API_KEY='...' \
 *     node test_pdf_capture.mjs "51 Asbury Rd, Farmingdale, NJ"
 */

import fs from "fs";
import { mlsSearchAndCapturePdf } from "./mls.js";

const address = process.argv[2] || "51 Asbury Rd, Farmingdale, NJ";
const outPath = "/tmp/listing_test.pdf";

if (!process.env.MLS_USERNAME || !process.env.MLS_PASSWORD) {
  console.error("Set MLS_USERNAME and MLS_PASSWORD env vars");
  process.exit(1);
}

console.log(`\nSearching MLS for: ${address}`);
console.log("─".repeat(60));

const result = await mlsSearchAndCapturePdf(address);

console.log("\n── Result ──────────────────────────────────────────────────");
console.log("ok:         ", result.ok);
console.log("error:      ", result.error || "none");
console.log("address:    ", result.structured?.address || "(not found)");
console.log("price:      ", result.structured?.price || "(not found)");
console.log("pdf_bytes:  ", result.pdfBuffer ? result.pdfBuffer.length : 0);
console.log("raw preview:", result.rawText?.slice(0, 200) || "(empty)");

if (result.pdfBuffer && result.pdfBuffer.length > 10_000) {
  fs.writeFileSync(outPath, result.pdfBuffer);
  console.log(`\n✓ PDF saved to ${outPath} — open it to inspect`);
} else if (result.pdfBuffer) {
  console.log(`\n✗ PDF captured but suspiciously small (${result.pdfBuffer.length} bytes) — likely empty page`);
  fs.writeFileSync(outPath, result.pdfBuffer);
  console.log(`  Saved anyway to ${outPath}`);
} else {
  console.log("\n✗ No PDF captured");
}

process.exit(result.ok ? 0 : 1);
