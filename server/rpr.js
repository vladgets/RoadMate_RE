/**
 * RPR (Realtors Property Resource) automation via Playwright.
 *
 * Flow:
 *  1. Load saved RPR session (cookies) if available — skip login
 *  2. If not authenticated: login to Flexmls first, then click the RPR SSO link
 *     (RPR uses MLS SSO — direct login requires an email, but MLS SSO bypasses that)
 *  3. Search property by address
 *  4. Click "Create Report" → My Templates → "RB Seller Report Template"
 *  5. Wait for report generation → click "Download" → return PDF buffer
 *
 * Env vars required (same as MLS):
 *   MLS_USERNAME  - Flexmls username
 *   MLS_PASSWORD  - Flexmls password
 */

import { chromium } from "playwright";
import fs from "fs";
import path from "path";
import { execFileSync } from "child_process";

const BROWSERS_PATH = "/data/playwright";
const SESSION_FILE = "/data/rpr_session.json";
const RPR_ENTRY_URL = "https://www.narrpr.com/home?cbcode=NJMOMLS-N2";
const SCREENSHOT_DIR = "/tmp";

// ─── Chromium install (shared pattern with mls.js) ───────────────────────────

function ensureChromium() {
  if (process.platform !== "linux") return;

  const alreadyInstalled =
    fs.existsSync(BROWSERS_PATH) &&
    fs.readdirSync(BROWSERS_PATH).some((d) => d.startsWith("chromium"));

  if (alreadyInstalled) return;

  console.log("[RPR] Installing Chromium to", BROWSERS_PATH, "...");
  fs.mkdirSync(BROWSERS_PATH, { recursive: true });
  execFileSync("npx", ["playwright", "install", "chromium"], {
    stdio: "inherit",
    env: { ...process.env, PLAYWRIGHT_BROWSERS_PATH: BROWSERS_PATH },
  });
}

function findChromiumExecutable() {
  if (!fs.existsSync(BROWSERS_PATH)) return null;
  for (const dir of fs.readdirSync(BROWSERS_PATH)) {
    if (!dir.startsWith("chromium")) continue;
    const candidates = [
      path.join(BROWSERS_PATH, dir, "chrome-headless-shell-linux64", "chrome-headless-shell"),
      path.join(BROWSERS_PATH, dir, "chrome-linux64", "chrome"),
      path.join(BROWSERS_PATH, dir, "chrome-headless-shell-linux", "chrome-headless-shell"),
      path.join(BROWSERS_PATH, dir, "chrome-linux", "chrome"),
    ];
    for (const exe of candidates) {
      if (fs.existsSync(exe)) return exe;
    }
  }
  return null;
}

// ─── Browser singleton ────────────────────────────────────────────────────────

let _browser = null;

async function getBrowser() {
  if (!_browser || !_browser.isConnected()) {
    ensureChromium();
    const executablePath = findChromiumExecutable() ?? undefined;
    _browser = await chromium.launch({
      headless: true,
      executablePath,
      args: ["--no-sandbox", "--disable-dev-shm-usage"],
    });
  }
  return _browser;
}

// ─── Session persistence ──────────────────────────────────────────────────────

async function loadSession(context) {
  if (fs.existsSync(SESSION_FILE)) {
    try {
      const state = JSON.parse(fs.readFileSync(SESSION_FILE, "utf8"));
      await context.addCookies(state.cookies ?? []);
      console.log("[RPR] Session loaded from", SESSION_FILE);
      return true;
    } catch (e) {
      console.warn("[RPR] Could not load session:", e.message);
    }
  }
  return false;
}

async function saveSession(context) {
  try {
    const cookies = await context.cookies();
    fs.writeFileSync(SESSION_FILE, JSON.stringify({ cookies }, null, 2));
    console.log("[RPR] Session saved");
  } catch (e) {
    console.warn("[RPR] Could not save session:", e.message);
  }
}

// ─── Screenshot helper ────────────────────────────────────────────────────────

async function screenshot(page, name) {
  try {
    const p = path.join(SCREENSHOT_DIR, `rpr_${name}.png`);
    await page.screenshot({ path: p, fullPage: false });
    console.log(`[RPR] Screenshot: ${p}`);
  } catch {}
}

// ─── MLS SSO → RPR authentication ────────────────────────────────────────────
// RPR login requires an email address, but MLS members can access RPR via SSO.
// We log into Flexmls first (reusing the same MLS credentials), then find and
// click the RPR link inside Flexmls which redirects us to narrpr.com authenticated.

import { ensureAuthenticated as mlsEnsureAuthenticated } from "./mls.js";

async function isRprLoggedIn(page) {
  const url = page.url();
  return url.includes("www.narrpr.com") && !url.includes("auth.narrpr.com") && !url.includes("/sign-in");
}

async function waitForRprLoad(page, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await isRprLoggedIn(page)) {
      const bodyLen = await page.evaluate(() => document.body?.innerText?.length ?? 0).catch(() => 0);
      if (bodyLen > 100) {
        console.log("[RPR] Authenticated on RPR, URL:", page.url());
        return true;
      }
    }
    await page.waitForTimeout(500);
  }
  return false;
}

async function ensureAuthenticated(page, context) {
  // Try saved RPR session first
  await loadSession(context);
  await page.goto(RPR_ENTRY_URL, { waitUntil: "domcontentloaded", timeout: 30000 });
  await page.waitForTimeout(2000);

  if (await isRprLoggedIn(page)) {
    const bodyLen = await page.evaluate(() => document.body?.innerText?.length ?? 0).catch(() => 0);
    if (bodyLen > 200) {
      console.log("[RPR] Already authenticated via saved RPR session");
      return;
    }
  }

  console.log("[RPR] RPR session invalid — logging into Flexmls for SSO...");

  // Log into Flexmls using existing MLS auth logic
  await mlsEnsureAuthenticated(page, context);
  console.log("[RPR] Flexmls authenticated, URL:", page.url());

  // Look for RPR link inside Flexmls (app launcher or navigation)
  const rprLinkSelectors = [
    'a[href*="narrpr.com"]',
    'a[href*="rpr"]',
    'a:has-text("RPR")',
    'img[alt*="RPR"]',
    '[title*="RPR"]',
    '[class*="rpr"]',
  ];

  let rprHref = null;
  for (const sel of rprLinkSelectors) {
    try {
      // Check main frame and all child frames
      for (const frame of page.frames()) {
        const el = frame.locator(sel).first();
        if (await el.count() > 0) {
          rprHref = await el.getAttribute("href").catch(() => null);
          console.log(`[RPR] Found RPR link (${sel}):`, rprHref);
          break;
        }
      }
    } catch {}
    if (rprHref) break;
  }

  if (rprHref) {
    console.log("[RPR] Navigating via SSO link:", rprHref);
    await page.goto(rprHref, { waitUntil: "domcontentloaded", timeout: 30000 });
  } else {
    // No link found — navigate to the RPR cbcode URL from within the Flexmls session.
    // The browser context shares the Flexmls session cookies; even though RPR is a different
    // domain, the cbcode URL triggers an SSO handshake that the MLS session authorizes.
    console.log("[RPR] No RPR link found in Flexmls UI, navigating to cbcode URL directly...");
    await page.goto(RPR_ENTRY_URL, { waitUntil: "domcontentloaded", timeout: 30000 });
  }

  await page.waitForTimeout(3000);
  console.log("[RPR] Post-SSO URL:", page.url());

  // If still on auth page, try navigating to the RPR URL directly — sometimes
  // the cbcode is enough on its own after a fresh Flexmls login.
  if (!await isRprLoggedIn(page)) {
    console.log("[RPR] Still not on RPR, trying cbcode URL again after short wait...");
    await page.waitForTimeout(2000);
    await page.goto(RPR_ENTRY_URL, { waitUntil: "domcontentloaded", timeout: 30000 });
    await page.waitForTimeout(3000);
  }

  const ok = await waitForRprLoad(page, 20000);
  if (!ok) {
    await screenshot(page, "rpr_login_failed");
    throw new Error(`RPR SSO failed. Final URL: ${page.url()}`);
  }

  await saveSession(context);
  console.log("[RPR] RPR session established via MLS SSO");

  // Dismiss "Another user detected" dialog if present
  await dismissDialogs(page);
}

async function dismissDialogs(page) {
  const closeBtn = page.locator('button:has-text("Close"), button:has-text("OK"), button:has-text("Dismiss"), .cdk-overlay-backdrop ~ * button').first();
  try {
    if (await closeBtn.count() > 0 && await closeBtn.isVisible({ timeout: 3000 })) {
      console.log("[RPR] Dismissing dialog...");
      await closeBtn.click({ timeout: 3000 });
      await page.waitForTimeout(1000);
    }
  } catch {}
}

// ─── Navigate to report via Reports menu ─────────────────────────────────────
//
// Flow: Reports (nav menu) → My Templates → RB Sellers Report
//       → "Select Location" modal: fill address + Continue
//       → Report generation → Download

async function generateReport(page, address) {
  await dismissDialogs(page);

  // Step 1: Click "Reports" in the top nav
  console.log("[RPR] Clicking Reports menu...");
  const reportsMenu = page.locator('nav a:has-text("Reports"), a:has-text("Reports"), button:has-text("Reports")').first();
  await reportsMenu.waitFor({ state: "visible", timeout: 15000 });
  await reportsMenu.click({ timeout: 5000 });
  await page.waitForTimeout(1000);

  // Step 2: Click "My Templates" in the dropdown
  console.log("[RPR] Clicking My Templates...");
  const myTemplatesLink = page.locator('a:has-text("My Templates"), button:has-text("My Templates")').first();
  await myTemplatesLink.waitFor({ state: "visible", timeout: 8000 });
  await myTemplatesLink.click({ timeout: 5000 });
  await page.waitForTimeout(2000);
  console.log("[RPR] Templates page URL:", page.url());

  // Step 3: Find and click "RB Sellers Report" template
  console.log("[RPR] Looking for RB Sellers Report template...");

  // Scroll to bottom to ensure My Templates section is visible
  await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight)).catch(() => {});
  await page.waitForTimeout(500);

  const templateSelectors = [
    page.getByText("RB Sellers Report Template", { exact: true }),
    page.getByText("RB Sellers Report", { exact: false }),
    page.locator(':text-matches("RB Sellers", "i")'),
    page.locator(':text-matches("RB Seller", "i")'),
  ];

  let foundTemplate = false;
  for (const locator of templateSelectors) {
    try {
      if (await locator.count() > 0 && await locator.first().isVisible({ timeout: 2000 }).catch(() => false)) {
        console.log("[RPR] Clicking RB Sellers Report template...");
        await locator.first().click({ timeout: 5000 });
        foundTemplate = true;
        break;
      }
    } catch {}
  }

  if (!foundTemplate) {
    const bodyText = await page.evaluate(() => document.body?.innerText?.slice(0, 3000) ?? "").catch(() => "");
    console.log("[RPR] Templates page text:", bodyText);
    await screenshot(page, "template_not_found");
    throw new Error("Could not find 'RB Sellers Report' template in My Templates");
  }

  await page.waitForTimeout(1500);

  // Step 4: Handle "Select Location" modal — fill address and click Continue
  console.log("[RPR] Handling Select Location modal...");
  const addressInput = page.locator('input[placeholder*="address" i], input[placeholder*="MLS" i]').first();
  await addressInput.waitFor({ state: "visible", timeout: 10000 });
  await addressInput.click({ timeout: 5000 });
  await addressInput.fill(address);
  console.log("[RPR] Filled address:", address);

  await page.waitForTimeout(1500);

  // Click first autocomplete suggestion if it appears
  const suggestion = page.locator('[role="option"], [class*="suggestion"], [class*="autocomplete"]').first();
  if (await suggestion.isVisible({ timeout: 3000 }).catch(() => false)) {
    console.log("[RPR] Clicking address suggestion...");
    await suggestion.click({ timeout: 5000 });
    await page.waitForTimeout(1000);
  }

  // Click Continue
  console.log("[RPR] Clicking Continue...");
  const continueBtn = page.locator('button:has-text("Continue")').first();
  await continueBtn.waitFor({ state: "visible", timeout: 8000 });
  await continueBtn.click({ timeout: 5000 });

  await page.waitForTimeout(2000);
  console.log("[RPR] Report generation started, URL:", page.url());
}

// ─── Wait for and download report PDF ────────────────────────────────────────

async function downloadReport(page, context) {
  // Step 1: Wait for "Generating live preview..." to disappear
  console.log("[RPR] Waiting for report preview to finish generating...");
  const previewDeadline = Date.now() + 120_000;
  while (Date.now() < previewDeadline) {
    const isGenerating = await page.locator('text="Generating live preview"').isVisible({ timeout: 1000 }).catch(() => false);
    if (!isGenerating) {
      console.log("[RPR] Preview generation complete");
      break;
    }
    await page.waitForTimeout(2000);
  }

  // Step 2: Derive PDF URL directly from the editor URL.
  // Editor URL pattern: /reports-v2/{uuid}/editor?...
  // PDF URL pattern:    /reports-v2/{uuid}/pdf
  // This is more reliable than intercepting download events across platforms.
  const editorUrl = page.url();
  const uuidMatch = editorUrl.match(/reports-v2\/([^/]+)\/editor/);
  if (uuidMatch) {
    const pdfUrl = `https://www.narrpr.com/reports-v2/${uuidMatch[1]}/pdf`;
    console.log("[RPR] Fetching PDF from:", pdfUrl);

    // Wait a moment for server-side PDF generation to complete
    await page.waitForTimeout(3000);

    const resp = await context.request.get(pdfUrl, {
      headers: { Referer: "https://www.narrpr.com" },
      timeout: 60_000,
    });

    if (resp.ok()) {
      const pdfBuffer = await resp.body();
      console.log(`[RPR] PDF fetched: ${pdfBuffer.length} bytes`);
      return pdfBuffer;
    }
    console.warn(`[RPR] PDF URL returned ${resp.status()}, falling back to Download button`);
  }

  // Fallback: click the Download button and intercept
  console.log("[RPR] Clicking Download button...");
  const downloadBtn = page.locator('a:has-text("Download"), button:has-text("Download")').first();
  await downloadBtn.waitFor({ state: "visible", timeout: 15000 });

  // Listen for new page (new tab) before clicking
  const newPagePromise = context.waitForEvent("page", { timeout: 30_000 }).catch(() => null);
  const downloadPromise = page.waitForEvent("download", { timeout: 30_000 }).catch(() => null);
  await downloadBtn.click({ timeout: 5000, noWaitAfter: true });

  const [newTab, download] = await Promise.all([newPagePromise, downloadPromise]);

  if (newTab) {
    await newTab.waitForLoadState("domcontentloaded", { timeout: 15000 }).catch(() => {});
    const tabUrl = newTab.url();
    console.log("[RPR] New tab URL:", tabUrl);
    if (tabUrl.includes("/pdf") || tabUrl.includes(".pdf")) {
      const resp = await context.request.get(tabUrl, { headers: { Referer: "https://www.narrpr.com" } });
      if (resp.ok()) {
        const buf = await resp.body();
        console.log(`[RPR] PDF from new tab: ${buf.length} bytes`);
        return buf;
      }
    }
  }

  if (download) {
    const stream = await download.createReadStream();
    const buf = await new Promise((resolve, reject) => {
      const chunks = [];
      stream.on("data", c => chunks.push(c));
      stream.on("end", () => resolve(Buffer.concat(chunks)));
      stream.on("error", reject);
    });
    console.log(`[RPR] PDF via download event: ${buf.length} bytes`);
    return buf;
  }

  await screenshot(page, "download_failed");
  throw new Error("Could not obtain PDF — check download_failed.png");
}

// ─── Main exported function ───────────────────────────────────────────────────

export async function generateRprReport(address) {
  const browser = await getBrowser();
  const context = await browser.newContext({
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    viewport: { width: 1280, height: 900 },
    acceptDownloads: true,
  });

  const page = await context.newPage();

  const hardTimeout = new Promise((_, reject) =>
    setTimeout(() => reject(new Error("generateRprReport hard timeout (5min)")), 300_000)
  );

  try {
    const pdfBuffer = await Promise.race([
      (async () => {
        await ensureAuthenticated(page, context);
        await generateReport(page, address);
        const pdf = await downloadReport(page, context);
        await saveSession(context);
        return pdf;
      })(),
      hardTimeout,
    ]);

    return { ok: true, pdfBuffer };
  } catch (err) {
    console.error("[RPR] Error:", err.message);
    await screenshot(page, "error").catch(() => {});
    return { ok: false, error: err.message };
  } finally {
    await context.close();
  }
}

// ─── Express routes ───────────────────────────────────────────────────────────

export function registerRprRoutes(app) {
  /**
   * POST /rpr/report
   * Body: { address: string }
   * Returns: PDF file (application/pdf) or JSON error
   *
   * Generate an RPR "RB Seller Report Template" for the given property address.
   */
  app.post("/rpr/report", async (req, res) => {
    const { address } = req.body ?? {};
    if (!address || typeof address !== "string") {
      return res.status(400).json({ ok: false, error: "Missing required field: address" });
    }

    console.log(`[RPR] /rpr/report request for: ${address}`);
    const result = await generateRprReport(address.trim());

    if (!result.ok || !result.pdfBuffer) {
      return res.status(500).json({ ok: false, error: result.error || "Failed to generate report" });
    }

    const safeAddr = address.trim().replace(/[^a-zA-Z0-9\s]/g, "").replace(/\s+/g, "_");
    const filename = `RPR_Seller_Report_${safeAddr}.pdf`;

    res.setHeader("Content-Type", "application/pdf");
    res.setHeader("Content-Disposition", `attachment; filename="${filename}"`);
    res.setHeader("Content-Length", result.pdfBuffer.length);
    res.send(result.pdfBuffer);

    console.log(`[RPR] Served PDF: ${filename} (${result.pdfBuffer.length} bytes)`);
  });

  /**
   * DELETE /rpr/session
   * Clears saved RPR session (forces re-login on next call)
   */
  app.delete("/rpr/session", (req, res) => {
    try {
      if (fs.existsSync(SESSION_FILE)) fs.unlinkSync(SESSION_FILE);
      res.json({ ok: true, message: "RPR session cleared" });
    } catch (e) {
      res.status(500).json({ ok: false, error: e.message });
    }
  });

  console.log("[RPR] Routes registered: POST /rpr/report, DELETE /rpr/session");
}
