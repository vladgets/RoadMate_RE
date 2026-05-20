/**
 * RPR (Realtors Property Resource) automation via Playwright.
 *
 * Flow:
 *  1. Load saved RPR session (cookies) — skip login if still valid
 *  2. If not authenticated: direct login at auth.narrpr.com with RPR credentials
 *  3. Reports menu → My Templates → RB Sellers Report Template
 *  4. Fill address in "Select Location" modal → Continue
 *  5. Wait for preview → fetch PDF from /reports-v2/{uuid}/pdf
 *
 * Env vars required:
 *   RPR_USERNAME  - RPR email (e.g. rbalandin@gmail.com)
 *   RPR_PASSWORD  - RPR password
 */

import { chromium } from "playwright";
import fs from "fs";
import path from "path";
import { execFileSync } from "child_process";

const BROWSERS_PATH = "/data/playwright";
const SESSION_FILE = "/data/rpr_session.json";
const RPR_LOGIN_URL = "https://auth.narrpr.com/auth/sign-in";
const RPR_HOME_URL = "https://www.narrpr.com/home";
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

// ─── Authentication ───────────────────────────────────────────────────────────

function isRprLoggedIn(url) {
  return url.includes("www.narrpr.com") && !url.includes("auth.narrpr.com") && !url.includes("/sign-in");
}

async function ensureAuthenticated(page, context) {
  await loadSession(context);

  // Single navigation — session valid = stays on narrpr.com,
  // session invalid = OIDC redirects to auth.narrpr.com with correct params.
  await page.goto(RPR_HOME_URL, { waitUntil: "domcontentloaded", timeout: 30000 });
  await page.waitForTimeout(2000);
  console.log("[RPR] After home nav, URL:", page.url());

  if (isRprLoggedIn(page.url())) {
    const bodyLen = await page.evaluate(() => document.body?.innerText?.length ?? 0).catch(() => 0);
    if (bodyLen > 200) {
      console.log("[RPR] Already authenticated via saved session");
      await dismissDialogs(page);
      return;
    }
  }

  // Not logged in — should now be on auth.narrpr.com with OIDC params
  const username = process.env.RPR_USERNAME;
  const password = process.env.RPR_PASSWORD;
  if (!username || !password) throw new Error("RPR_USERNAME and RPR_PASSWORD env vars required");

  console.log("[RPR] Logging in, current URL:", page.url());

  // Accept cookie consent if present (OneTrust / similar)
  for (const sel of ['button:has-text("Accept Optional")', 'button:has-text("Accept All")', 'button:has-text("Accept Cookies")', '#onetrust-accept-btn-handler']) {
    try {
      const btn = page.locator(sel).first();
      if (await btn.isVisible({ timeout: 2000 }).catch(() => false)) {
        console.log("[RPR] Accepting cookie consent...");
        await btn.click({ timeout: 3000 });
        await page.waitForTimeout(1000);
        break;
      }
    } catch {}
  }

  // Angular app — wait for email input to be ready (try multiple selectors)
  const emailInput = page.locator('input[name="email"], input[type="email"], input[placeholder*="email" i]').first();
  await emailInput.waitFor({ state: "visible", timeout: 40000 });
  await emailInput.click();
  await emailInput.pressSequentially(username, { delay: 50 });
  await page.waitForTimeout(300);

  const pwInput = page.locator('input[name="password"]');
  await pwInput.click();
  await pwInput.pressSequentially(password, { delay: 50 });
  await page.waitForTimeout(500);

  // Verify the values were typed correctly
  const typedEmail = await emailInput.inputValue().catch(() => "");
  const typedPw = await pwInput.inputValue().catch(() => "");
  console.log("[RPR] Email field value:", typedEmail);
  console.log("[RPR] Password field length:", typedPw.length);

  await page.locator('button[type="submit"]').click({ force: true });
  await page.waitForTimeout(2000);
  await screenshot(page, "after_login_click");

  // Wait for redirect to www.narrpr.com
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (isRprLoggedIn(page.url())) break;
    await page.waitForTimeout(500);
  }

  if (!isRprLoggedIn(page.url())) {
    await screenshot(page, "login_failed");
    throw new Error(`RPR login failed. URL: ${page.url()}`);
  }

  console.log("[RPR] Logged in, URL:", page.url());
  await saveSession(context);
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

  // Navigate directly to the templates page — avoids dropdown timing issues
  console.log("[RPR] Navigating to My Templates...");
  await page.goto("https://www.narrpr.com/reports-v2/templates", { waitUntil: "commit", timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(3000);
  await dismissDialogs(page);
  console.log("[RPR] Templates page URL:", page.url());

  // Step 3: Find and click "RB Sellers Report" template
  console.log("[RPR] Looking for RB Sellers Report template...");

  // Scroll to bottom to ensure My Templates section is visible
  await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight)).catch(() => {});
  await page.waitForTimeout(500);

  // Target the exact template name within the My Templates table row to avoid
  // matching the "RB" sidebar tab or other partial matches
  const templateSelectors = [
    page.locator('td:has-text("RB Sellers Report Template")'),
    page.locator('td:has-text("RB Sellers Report")'),
    page.getByText("RB Sellers Report Template", { exact: true }),
  ];

  let foundTemplate = false;
  for (const locator of templateSelectors) {
    try {
      if (await locator.count() > 0 && await locator.first().isVisible({ timeout: 2000 }).catch(() => false)) {
        console.log("[RPR] Clicking RB Sellers Report template...");
        await locator.first().click({ timeout: 5000, force: true });
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
  // Step 1: Wait for Download button to appear — this is RPR's signal that
  // server-side PDF generation is complete (not just the live preview).
  console.log("[RPR] Waiting for Download button (report fully generated)...");
  const downloadBtn = page.locator('a:has-text("Download"), button:has-text("Download")').first();
  await downloadBtn.waitFor({ state: "visible", timeout: 120_000 });
  console.log("[RPR] Download button appeared — report is ready");

  // Step 2: Click Download — this triggers server-side PDF generation on RPR.
  // After clicking, RPR opens a new tab at /reports-v2/{uuid}/pdf with the full PDF.
  const editorUrl = page.url();
  const uuidMatch = editorUrl.match(/reports-v2\/([^/]+)\/editor/);

  console.log("[RPR] Clicking Download to trigger PDF generation...");
  const newPagePromise = context.waitForEvent("page", { timeout: 30_000 }).catch(() => null);
  const downloadPromise = page.waitForEvent("download", { timeout: 30_000 }).catch(() => null);
  await downloadBtn.click({ timeout: 5000, noWaitAfter: true });

  const [newTab, download] = await Promise.all([newPagePromise, downloadPromise]);

  // Strategy 1: new tab opened — fetch PDF URL from it
  if (newTab) {
    await newTab.waitForLoadState("domcontentloaded", { timeout: 15000 }).catch(() => {});
    const tabUrl = newTab.url();
    console.log("[RPR] New tab URL:", tabUrl);
    const resp = await context.request.get(tabUrl, { headers: { Referer: "https://www.narrpr.com" } });
    if (resp.ok()) {
      const buf = await resp.body();
      console.log(`[RPR] PDF from new tab: ${buf.length} bytes`);
      if (buf.length > 50_000) return buf;
    }
  }

  // Strategy 2: download event fired
  if (download) {
    const stream = await download.createReadStream();
    const buf = await new Promise((resolve, reject) => {
      const chunks = [];
      stream.on("data", c => chunks.push(c));
      stream.on("end", () => resolve(Buffer.concat(chunks)));
      stream.on("error", reject);
    });
    console.log(`[RPR] PDF via download event: ${buf.length} bytes`);
    if (buf.length > 50_000) return buf;
  }

  // Strategy 3: derive PDF URL from editor URL, wait for generation then fetch
  if (uuidMatch) {
    const pdfUrl = `https://www.narrpr.com/reports-v2/${uuidMatch[1]}/pdf`;
    console.log("[RPR] Waiting 10s then fetching PDF URL directly:", pdfUrl);
    await page.waitForTimeout(10_000);
    const resp = await context.request.get(pdfUrl, { headers: { Referer: "https://www.narrpr.com" }, timeout: 60_000 });
    if (resp.ok()) {
      const buf = await resp.body();
      console.log(`[RPR] PDF from direct URL: ${buf.length} bytes`);
      if (buf.length > 50_000) return buf;
    }
  }

  await screenshot(page, "download_failed");
  throw new Error("Could not obtain a valid PDF (all strategies failed)");
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
