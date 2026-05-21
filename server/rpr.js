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
  // Wait for OIDC callback redirect chain to settle (callback → home)
  await page.waitForURL(url => !url.includes("/auth/callback"), { timeout: 10000 }).catch(() => {});
  await page.waitForLoadState("load", { timeout: 10000 }).catch(() => {});
  console.log("[RPR] After home nav, URL:", page.url());

  if (isRprLoggedIn(page.url())) {
    const bodyLen = await page.evaluate(() => document.body?.innerText?.length ?? 0).catch(() => 0);
    if (bodyLen > 200) {
      console.log("[RPR] Already authenticated via saved session");
      await dismissDialogs(page);
      return;
    }
  }

  // Not logged in — we're already on auth.narrpr.com with correct OIDC params.
  // Clear stale cookies then reload the same URL (keeps OIDC params intact).
  const username = process.env.RPR_USERNAME;
  const password = process.env.RPR_PASSWORD;
  if (!username || !password) throw new Error("RPR_USERNAME and RPR_PASSWORD env vars required");

  const authUrl = page.url().includes("auth.narrpr.com") ? page.url() : RPR_LOGIN_URL;
  await context.clearCookies();
  console.log("[RPR] Cleared stale cookies, reloading auth page...");
  await page.goto(authUrl, { waitUntil: "domcontentloaded", timeout: 30000 });
  await page.waitForLoadState("load", { timeout: 15000 }).catch(() => {});
  console.log("[RPR] Login page URL:", page.url());

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

  // Angular app — wait for email input, use fill() + blur to trigger reactive form validation
  const emailInput = page.locator('input[name="email"], input[type="email"], input[placeholder*="email" i]').first();
  await emailInput.waitFor({ state: "visible", timeout: 40000 });
  await emailInput.fill(username);
  await emailInput.press("Tab"); // triggers blur + Angular validation

  const pwInput = page.locator('input[name="password"], input[type="password"]').first();
  await pwInput.fill(password);
  await page.waitForTimeout(300);

  console.log("[RPR] Email:", await emailInput.inputValue().catch(() => ""));
  console.log("[RPR] Password length:", (await pwInput.inputValue().catch(() => "")).length);

  const submitBtn = page.locator('button[type="submit"]').first();
  const isDisabled = await submitBtn.isDisabled().catch(() => false);
  console.log("[RPR] Submit button disabled:", isDisabled);

  // Press Enter on password field as primary method — more reliable than button click
  await pwInput.press("Enter");
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
    const pageText = await page.evaluate(() => document.body?.innerText?.slice(0, 500) ?? "").catch(() => "");
    console.log("[RPR] Login failed page text:", pageText);
    throw new Error(`RPR login failed. URL: ${page.url()} | Page: ${pageText.slice(0, 200)}`);
  }

  console.log("[RPR] Logged in, URL:", page.url());
  await saveSession(context);
  await dismissDialogs(page);
}

async function dismissDialogs(page) {
  const selectors = [
    'button:has-text("Close")',
    'button:has-text("OK")',
    'button:has-text("Dismiss")',
    '.cdk-overlay-backdrop ~ * button',
  ];
  for (const sel of selectors) {
    try {
      const btn = page.locator(sel).first();
      if (await btn.isVisible({ timeout: 2000 }).catch(() => false)) {
        console.log("[RPR] Dismissing dialog:", sel);
        await btn.click({ timeout: 3000 });
        await page.waitForTimeout(500);
      }
    } catch {}
  }
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

  // Dismiss any delayed dialogs (e.g. "Another user detected") before searching
  await page.waitForTimeout(2000);
  await dismissDialogs(page);

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

  // Click Continue and wait for navigation to editor page
  console.log("[RPR] Clicking Continue...");
  const continueBtn = page.locator('button:has-text("Continue")').first();
  await continueBtn.waitFor({ state: "visible", timeout: 8000 });
  await continueBtn.click({ timeout: 5000 });

  // Wait for navigation away from templates to the report editor
  await page.waitForURL(/reports-v2\/.+\/editor/, { timeout: 30000 }).catch(() => {});
  console.log("[RPR] Report generation started, URL:", page.url());
}

// ─── Wait for and download report PDF ────────────────────────────────────────

async function downloadReport(page, context) {
  // Step 1: Wait for Download button to appear — this is RPR's signal that
  // server-side PDF generation is complete (not just the live preview).
  console.log("[RPR] Waiting for Download button to be enabled...");
  // Wait for the specific download-button class to appear and become active
  await page.waitForFunction(
    () => {
      const btn = document.querySelector('a.download-button, button.download-button');
      return btn && !btn.classList.contains("disabled") && !btn.classList.contains("is-loading");
    },
    null,
    { timeout: 120_000, polling: 2000 }
  );
  const downloadBtn = page.locator('a.download-button, button.download-button').first();
  console.log("[RPR] Download button ready — report is fully generated");

  // Step 2: Derive PDF URL from editor URL and poll until the PDF is ready.
  // Clicking Download just triggers generation — the PDF URL may return a small
  // placeholder until the server finishes, so we poll with retries.
  const editorUrl = page.url();
  const uuidMatch = editorUrl.match(/reports-v2\/([^/]+)\/editor/);
  if (!uuidMatch) throw new Error("Could not extract report UUID from editor URL: " + editorUrl);

  const pdfUrl = `https://www.narrpr.com/reports-v2/${uuidMatch[1]}/pdf`;
  console.log("[RPR] Clicking Download, then polling PDF:", pdfUrl);

  await downloadBtn.click({ timeout: 5000, noWaitAfter: true }).catch(() => {});
  await page.waitForTimeout(3000);

  // Poll PDF URL up to 90s — RPR generates async so first few fetches may return a placeholder.
  // Follow the redirect to get the public S3 URL instead of downloading bytes.
  const deadline = Date.now() + 90_000;
  let attempt = 0;
  while (Date.now() < deadline) {
    attempt++;
    // Use fetch (not Playwright request) so we can follow redirects and get the final URL
    const resp = await fetch(pdfUrl, {
      headers: { Referer: "https://www.narrpr.com", Cookie: (await context.cookies()).map(c => `${c.name}=${c.value}`).join("; ") },
      redirect: "follow",
    }).catch(() => null);

    if (resp?.ok) {
      const finalUrl = resp.url;
      if (finalUrl.includes("staticaws.narrpr.com")) {
        // S3 URL appeared — HEAD it to confirm the file has content
        const head = await fetch(finalUrl, { method: "HEAD" }).catch(() => null);
        const size = parseInt(head?.headers?.get("content-length") ?? "0", 10);
        console.log(`[RPR] PDF attempt ${attempt}: S3 URL ready, size=${size}`);
        if (size > 50_000) return finalUrl;
      } else {
        console.log(`[RPR] PDF attempt ${attempt}: not S3 yet (${finalUrl})`);
      }
    }
    console.log(`[RPR] PDF not ready yet (attempt ${attempt}), waiting 5s...`);
    await page.waitForTimeout(5000);
  }

  await screenshot(page, "download_failed");
  throw new Error("PDF never became available after polling 90s");
}

// ─── Request queue — RPR only allows one active session per account ──────────

let _rprQueue = Promise.resolve();

function enqueueRpr(fn) {
  const result = _rprQueue.then(fn);
  _rprQueue = result.catch(() => {});
  return result;
}

// ─── Main exported function ───────────────────────────────────────────────────

export function generateRprReport(address) {
  return enqueueRpr(() => _generateRprReport(address));
}

async function _generateRprReport(address) {
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
    const pdfUrl = await Promise.race([
      (async () => {
        await ensureAuthenticated(page, context);
        await generateReport(page, address);
        const url = await downloadReport(page, context);
        await saveSession(context);
        return url;
      })(),
      hardTimeout,
    ]);

    return { ok: true, pdfUrl };
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

    if (!result.ok || !result.pdfUrl) {
      return res.status(500).json({ ok: false, error: result.error || "Failed to generate report" });
    }

    res.json({ ok: true, pdfUrl: result.pdfUrl });
    console.log(`[RPR] Report ready: ${result.pdfUrl}`);
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
