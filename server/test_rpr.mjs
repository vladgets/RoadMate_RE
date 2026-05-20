/**
 * Quick local test for RPR report generation.
 * Usage: MLS_USERNAME=<user> MLS_PASSWORD=<pass> node test_rpr.mjs "123 Main St, Springfield NJ"
 */
import { generateRprReport } from "./rpr.js";
import fs from "fs";

const address = process.argv[2] || "123 Main St, Springfield NJ 07081";
console.log("Testing RPR report generation for:", address);

const result = await generateRprReport(address);

if (result.ok && result.pdfBuffer) {
  const outFile = `/tmp/rpr_test_report.pdf`;
  fs.writeFileSync(outFile, result.pdfBuffer);
  console.log(`\n✅ SUCCESS — PDF saved to: ${outFile} (${result.pdfBuffer.length} bytes)`);
  console.log("Check screenshots in /tmp/rpr_*.png for the automation flow");
} else {
  console.error("\n❌ FAILED:", result.error);
  console.log("Check screenshots in /tmp/rpr_*.png for what went wrong");
  process.exit(1);
}
