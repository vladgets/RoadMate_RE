/**
 * MLS automation via Playwright (Flexmls - mo.flexmls.com).
 *
 * Flow:
 *  1. Load saved session state (cookies) if available → skip CAPTCHA + login
 *  2. If not authenticated: solve Fastly image CAPTCHA via OpenAI Vision, then login
 *  3. Search by address using the top-left search bar
 *  4. Navigate to the first matching listing page and return extracted data
 *
 * Env vars required:
 *   MLS_USERNAME   - Flexmls username
 *   MLS_PASSWORD   - Flexmls password
 *   OPENAI_API_KEY - Used to solve CAPTCHA via GPT-4 Vision
 *
 * Optional:
 *   MLS_SESSION_FILE - Path to persist browser session (default: /data/mls_session.json)
 */

import { chromium } from "playwright";
import fs from "fs";

// Point Playwright to the persistent disk on Render so the browser binary
// survives redeploys and is only downloaded once.
if (!process.env.PLAYWRIGHT_BROWSERS_PATH) {
  process.env.PLAYWRIGHT_BROWSERS_PATH = "/data/playwright";
}
import path from "path";

const BASE_URL = "https://mo.flexmls.com";
const SESSION_FILE = process.env.MLS_SESSION_FILE ?? "/data/mls_session.json";

// ─── Browser singleton ───────────────────────────────────────────────────────

let _browser = null;

async function getBrowser() {
  if (!_browser || !_browser.isConnected()) {
    _browser = await chromium.launch({
      headless: true,
      args: ["--no-sandbox", "--disable-dev-shm-usage"],
    });
  }
  return _browser;
}

// ─── CAPTCHA solving via OpenAI Vision ───────────────────────────────────────

async function solveCaptchaImage(base64Jpeg) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) throw new Error("OPENAI_API_KEY not set");

  const resp = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "gpt-4o",
      max_tokens: 20,
      messages: [
        {
          role: "user",
          content: [
            {
              type: "text",
              text: "This is a CAPTCHA image containing 4-6 characters (letters and/or digits). " +
                "The characters are case-sensitive — uppercase and lowercase letters are different. " +
                "Ignore the colorful background, lines, and dots. Focus only on the text characters. " +
                "Reply with ONLY the exact characters in order, preserving case. No spaces, no explanation.",
            },
            {
              type: "image_url",
              image_url: { url: `data:image/jpeg;base64,${base64Jpeg}`, detail: "high" },
            },
          ],
        },
      ],
    }),
  });

  const data = await resp.json();
  const answer = data.choices?.[0]?.message?.content?.trim() ?? "";
  console.log(`[MLS] CAPTCHA solved: "${answer}"`);
  return answer;
}

// ─── CAPTCHA challenge page handling ─────────────────────────────────────────

async function handleFastlyChallenge(page) {
  // Wait for the CAPTCHA image to appear (loaded via JS)
  try {
    await page.waitForSelector("#captchaImage", { timeout: 10000 });
  } catch {
    // No CAPTCHA present — already past the challenge
    return;
  }

  const MAX_ATTEMPTS = 5;
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    console.log(`[MLS] CAPTCHA attempt ${attempt}/${MAX_ATTEMPTS}`);

    // If #captchaImage is gone, we already navigated away — success
    const captchaStillPresent = await page.$("#captchaImage");
    if (!captchaStillPresent) {
      console.log("[MLS] CAPTCHA page already passed, URL:", page.url());
      return;
    }

    // Extract base64 image data
    const imageData = await page.$eval("#captchaImage", (img) => {
      const src = img.src;
      return src.includes("base64,") ? src.split("base64,")[1] : null;
    });

    if (!imageData) throw new Error("Could not extract CAPTCHA image data");

    const answer = await solveCaptchaImage(imageData);

    // Fill answer and click submit
    await page.fill("#capInput", answer);
    await page.click("#capSubmit");

    // Wait up to 15s for: URL leaves /ticket (success) OR inline error (wrong answer)
    let passed = false;
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      await page.waitForTimeout(400);

      const currentUrl = page.url();
      if (!currentUrl.includes("/ticket")) {
        console.log("[MLS] CAPTCHA passed, now at:", currentUrl);
        passed = true;
        break;
      }

      // If #captchaImage disappeared the page navigated (success via redirect)
      const imgGone = await page.$("#captchaImage") === null;
      if (imgGone) {
        console.log("[MLS] CAPTCHA image gone — navigated away, URL:", page.url());
        passed = true;
        break;
      }

      // Check for inline error
      const errorVisible = await page.$eval(
        "#errorContainer",
        (el) => el.getAttribute("aria-hidden") !== "true"
      ).catch(() => false);

      if (errorVisible) {
        console.log(`[MLS] CAPTCHA wrong on attempt ${attempt}, retrying...`);
        break;
      }
    }

    if (passed) return;
    // Loop to next attempt — new CAPTCHA image should now be loaded
  }

  throw new Error(`CAPTCHA could not be solved after ${MAX_ATTEMPTS} attempts`);
}

// ─── Login ────────────────────────────────────────────────────────────────────

async function isLoggedIn(page) {
  const url = page.url();
  if (url.includes("/ticket")) return false;
  // Successfully landed on broker dashboard or Flexmls app
  return url.includes("monmouthoceanrealtors.com/dashboard") ||
         url.includes("flexmls.com") && !url.includes("/ticket");
}

/**
 * Fill and submit the login form.
 * Called after the Fastly challenge is cleared — the login form is at the same
 * /ticket URL but now visible.
 */
async function fillLoginForm(page) {
  const username = process.env.MLS_USERNAME;
  const password = process.env.MLS_PASSWORD;
  if (!username || !password) {
    throw new Error("MLS_USERNAME and MLS_PASSWORD environment variables required");
  }

  // Step 1: Wait for username field (name="user") to be visible
  console.log("[MLS] Waiting for username field...");
  await page.waitForSelector("input[name='user']", { state: "visible", timeout: 20000 });
  await page.screenshot({ path: "/tmp/mls_login_step1.png" });

  await page.fill("input[name='user']", username);

  // Click NEXT to proceed to password step
  await page.click("#login-button, input[type='submit'][name='login']");
  console.log("[MLS] Username submitted, waiting for password step...");

  // Step 2: Wait for password field to become visible
  // After clicking NEXT, either a password input appears or hiddenPassword becomes fillable
  await page.waitForTimeout(1000);
  await page.screenshot({ path: "/tmp/mls_login_step2.png" });

  const inputs = await page.$$eval("input", (els) =>
    els.map((e) => ({
      name: e.name, id: e.id, type: e.type,
      visible: e.offsetParent !== null,
      computedDisplay: window.getComputedStyle(e).display,
    }))
  );
  console.log("[MLS] Post-NEXT inputs:", JSON.stringify(inputs));

  // Try to fill any visible password field
  const passwordInput = await page.$("input[type='password']:not([name='hiddenPassword']), input[name='password']");
  if (passwordInput) {
    await passwordInput.fill(password);
  } else {
    // Fall back to filling hiddenPassword directly
    await page.$eval(
      "input[name='hiddenPassword']",
      (el, pw) => { el.value = pw; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); },
      password
    );
  }

  // Submit the password step
  await page.click("#login-button, input[type='submit'][name='login']");
  console.log("[MLS] Password submitted, waiting for dashboard...");

  // Wait for URL to leave /ticket
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    await page.waitForTimeout(500);
    if (!page.url().includes("/ticket")) break;
  }

  const finalUrl = page.url();
  console.log("[MLS] After login URL:", finalUrl);
  await page.screenshot({ path: "/tmp/mls_after_login.png" });

  if (finalUrl.includes("/ticket")) {
    throw new Error(`Login failed — still at: ${finalUrl}`);
  }
  console.log("[MLS] Login successful");
}

// ─── Session persistence ──────────────────────────────────────────────────────

async function loadSession(context) {
  if (fs.existsSync(SESSION_FILE)) {
    try {
      const state = JSON.parse(fs.readFileSync(SESSION_FILE, "utf8"));
      await context.addCookies(state.cookies ?? []);
      console.log("[MLS] Session loaded from", SESSION_FILE);
      return true;
    } catch (e) {
      console.warn("[MLS] Could not load session:", e.message);
    }
  }
  return false;
}

async function saveSession(context) {
  try {
    const cookies = await context.cookies();
    fs.writeFileSync(SESSION_FILE, JSON.stringify({ cookies }, null, 2));
    console.log("[MLS] Session saved to", SESSION_FILE);
  } catch (e) {
    console.warn("[MLS] Could not save session:", e.message);
  }
}

// ─── Ensure authenticated ─────────────────────────────────────────────────────

async function ensureAuthenticated(page, context) {
  await loadSession(context);

  // Navigate to root
  await page.goto(BASE_URL, { waitUntil: "domcontentloaded", timeout: 20000 });

  // Already logged in via saved session?
  if (await isLoggedIn(page)) {
    console.log("[MLS] Already authenticated via saved session");
    return;
  }

  // Handle Fastly CAPTCHA challenge if present (SPA stays at /ticket)
  if (page.url().includes("/ticket")) {
    await handleFastlyChallenge(page);
    // After CAPTCHA the login form is now visible at the same URL
    await fillLoginForm(page);
  } else {
    // Somehow landed on a login page at a different URL
    await fillLoginForm(page);
  }

  await saveSession(context);
}

// ─── Address search ───────────────────────────────────────────────────────────

async function getFlexmlsTopFrame(page) {
  // Flexmls is a multi-frame app. The search bar lives in the top frame.
  await page.waitForTimeout(3000); // Let all frames load
  for (const frame of page.frames()) {
    if (frame.url().includes("top_frame")) {
      return frame;
    }
  }
  return null;
}

async function searchAddress(page, address) {
  console.log("[MLS] Navigating to Flexmls (SSO redirect)...");

  // SSO: navigate via the redirect link used by the broker dashboard
  await page.goto("https://members.flexmls.com/ticket/redirect", {
    waitUntil: "domcontentloaded",
    timeout: 20000,
  });
  console.log("[MLS] After SSO redirect, URL:", page.url());

  // Wait for the multi-frame app to initialize
  await page.waitForTimeout(4000);
  await page.screenshot({ path: "/tmp/mls_app_loaded.png" });

  // Find the top frame that contains the global search bar
  const topFrame = await getFlexmlsTopFrame(page);
  if (!topFrame) {
    const frameUrls = page.frames().map(f => f.url());
    console.log("[MLS] Available frames:", frameUrls);
    throw new Error("Could not find Flexmls top frame");
  }
  console.log("[MLS] Found top frame:", topFrame.url());

  // The search bar in the top frame
  const searchInput = await topFrame.$('input[placeholder*="Address"], input[placeholder*="address"], input[type="text"]:first-of-type');
  if (!searchInput) {
    const inputs = await topFrame.$$eval("input", els => els.map(e => ({ type: e.type, placeholder: e.placeholder })));
    console.log("[MLS] Top frame inputs:", JSON.stringify(inputs));
    throw new Error("Could not find search input in Flexmls top frame");
  }

  console.log("[MLS] Typing address:", address);
  await searchInput.click();
  await searchInput.fill("");
  await searchInput.type(address, { delay: 60 });

  await page.screenshot({ path: "/tmp/mls_search_typing.png" });

  // Wait for autocomplete dropdown in the top frame
  let navigated = false;
  try {
    const dropdown = await topFrame.waitForSelector(
      'ul[class*="auto"], .autocomplete, [class*="suggest"], [class*="dropdown"] li, ul li[class*="result"]',
      { timeout: 4000 }
    );
    console.log("[MLS] Autocomplete appeared, clicking first result");
    await page.screenshot({ path: "/tmp/mls_autocomplete.png" });
    await dropdown.click();
    navigated = true;
  } catch {
    // No dropdown — press Enter
    console.log("[MLS] No autocomplete, pressing Enter");
  }

  if (!navigated) {
    await searchInput.press("Enter");
  }

  // Wait for main content to update (new frame or page navigation)
  await page.waitForTimeout(4000);
  console.log("[MLS] After search, URL:", page.url());
  await page.screenshot({ path: "/tmp/mls_search_results.png" });
}

// ─── Extract listing data ─────────────────────────────────────────────────────

// ─── Documents tab ────────────────────────────────────────────────────────────

async function fetchDocuments(page, resultsFrame) {
  console.log("[MLS] Opening Documents tab...");

  const docsLink = await resultsFrame.$("#detail_documents_link");
  if (!docsLink) {
    console.log("[MLS] No Documents tab found on this listing");
    return [];
  }

  await docsLink.click();

  // Wait for the documents frame to appear (URL contains documentviewer.html)
  // and for its source to contain document data
  let docsFrame = null;
  let frameSource = "";
  const deadline = Date.now() + 12000;
  while (Date.now() < deadline) {
    await page.waitForTimeout(400);
    docsFrame = page.frames().find((f) => f.url().includes("documentviewer"));
    if (docsFrame) {
      frameSource = await docsFrame.content().catch(() => "");
      // The JS source contains `documents.push(new Document(` when data is loaded
      if (frameSource.includes("documents.push")) break;
    }
  }

  if (!docsFrame) {
    console.log("[MLS] Documents frame did not load");
    return [];
  }

  console.log("[MLS] Documents frame loaded:", docsFrame.url());
  await page.screenshot({ path: "/tmp/mls_documents.png" });

  // Parse document metadata from the embedded JavaScript:
  // documents.push(new Document("picture_id","table","tech_id","description","caption","ext","order","confdnt_code","date","time","confidentiality","url"))
  const docs = [];
  const docRegex = /documents\.push\(new Document\(([^)]+)\)\)/g;
  let match;
  while ((match = docRegex.exec(frameSource)) !== null) {
    // Split carefully — values are comma-separated quoted strings
    const raw = match[1];
    const parts = [];
    let current = "";
    let inQuote = false;
    for (const ch of raw) {
      if (ch === '"') {
        inQuote = !inQuote;
      } else if (ch === "," && !inQuote) {
        parts.push(current.trim());
        current = "";
      } else {
        current += ch;
      }
    }
    parts.push(current.trim());

    const [pictureId, , , description, , extension, , , modDate, modTime, confidentiality, customUrl] = parts;

    // Build the PDF URL: use custom URL if provided, otherwise construct from picture_id
    const ext = (extension || "pdf").replace(/^['"]|['"]$/g, "");
    const id = pictureId.replace(/^['"]|['"]$/g, "");
    const pdfUrl = customUrl?.replace(/^['"]|['"]$/g, "") ||
      `https://documents.flexmls.com/documents/mo/${id}.${ext}`;

    docs.push({
      name: description?.replace(/^['"]|['"]$/g, "") || "Unnamed",
      extension: ext,
      confidentiality: confidentiality?.replace(/^['"]|['"]$/g, "") || "unknown",
      modifiedDate: modDate?.replace(/^['"]|['"]$/g, "") || "",
      modifiedTime: modTime?.replace(/^['"]|['"]$/g, "") || "",
      url: pdfUrl,
      downloadable: true,
    });
  }

  if (docs.length === 0) {
    // Fallback: no JS data found — check if the page just says "no documents"
    const bodyText = await docsFrame.evaluate(() => document.body?.innerText ?? "").catch(() => "");
    console.log("[MLS] No document JS data found. Body text:", bodyText.slice(0, 200));
    if (bodyText.toLowerCase().includes("no document")) {
      return [];
    }
  }

  console.log(`[MLS] Found ${docs.length} document(s)`);
  return docs;
}

// ─── Download a document PDF (using session cookies) ─────────────────────────

async function downloadDocument(context, pdfUrl, destPath) {
  // Use Playwright's request API which carries the browser's cookies
  const response = await context.request.get(pdfUrl, {
    headers: {
      "Accept": "application/pdf,*/*",
      "Referer": "https://mo.flexmls.com/",
    },
  });

  if (!response.ok()) {
    throw new Error(`HTTP ${response.status()} downloading ${pdfUrl}`);
  }

  const buffer = await response.body();
  fs.writeFileSync(destPath, buffer);
  console.log(`[MLS] Downloaded ${buffer.length} bytes → ${destPath}`);
  return buffer.length;
}

// ─── Extract listing data ─────────────────────────────────────────────────────

async function extractListingData(page, context) {
  await page.screenshot({ path: "/tmp/mls_listing_page.png" });

  // Flexmls is multi-frame — collect text from all frames
  let bestFrame = null;
  let bestFrameText = "";
  let resultsFrame = null;

  for (const frame of page.frames()) {
    try {
      const text = await frame.evaluate(() => document.body?.innerText ?? "");
      if (text.length > bestFrameText.length) {
        bestFrameText = text;
        bestFrame = frame;
      }
      if (frame.url().includes("listnum/step2")) {
        resultsFrame = frame;
      }
    } catch {}
  }

  console.log("[MLS] Best content frame:", bestFrame?.url());

  // Try to extract structured data from the richest frame
  let structured = {};
  if (bestFrame) {
    structured = await bestFrame.evaluate(() => {
      const getText = (sel) => document.querySelector(sel)?.innerText?.trim() ?? null;
      return {
        address: getText('[class*="address"], h1, [class*="Address"]'),
        price: getText('[class*="price"], [class*="Price"]'),
        status: getText('[class*="status"], [class*="Status"]'),
        beds: getText('[class*="bed"], [class*="Bed"]'),
        baths: getText('[class*="bath"], [class*="Bath"]'),
        sqft: getText('[class*="sqft"], [class*="SqFt"], [class*="square"]'),
        mlsNumber: getText('[class*="mls_nbr"], [class*="MlsNumber"], [class*="listing_number"]'),
      };
    }).catch(() => ({}));
  }

  // Fetch documents
  const documents = resultsFrame
    ? await fetchDocuments(page, resultsFrame)
    : [];

  return {
    url: page.url(),
    title: await page.title(),
    structured,
    rawText: bestFrameText.slice(0, 5000),
    documents,
  };
}

// ─── Main exported function ───────────────────────────────────────────────────

export async function mlsSearchProperty(address) {
  const browser = await getBrowser();
  const context = await browser.newContext({
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    viewport: { width: 1280, height: 900 },
  });

  const page = await context.newPage();

  try {
    await ensureAuthenticated(page, context);
    await searchAddress(page, address);
    const result = await extractListingData(page, context);
    // Refresh session on success
    await saveSession(context);
    return { ok: true, ...result };
  } catch (err) {
    console.error("[MLS] Error:", err);
    await page.screenshot({ path: "/tmp/mls_error.png" }).catch(() => {});
    return { ok: false, error: err.message };
  } finally {
    await context.close();
  }
}

// ─── Express routes ───────────────────────────────────────────────────────────

export function registerMlsRoutes(app) {
  /**
   * POST /mls/search
   * Body: { address: string }
   * Returns listing data from Flexmls
   */
  app.post("/mls/search", async (req, res) => {
    const { address } = req.body ?? {};
    if (!address || typeof address !== "string") {
      return res.status(400).json({ ok: false, error: "Missing required field: address" });
    }
    const result = await mlsSearchProperty(address.trim());
    res.json(result);
  });

  /**
   * GET /mls/document?url=<encoded_pdf_url>
   * Downloads a Flexmls document PDF using the saved session and streams it to the client.
   * The URL comes from the `documents[].url` field returned by /mls/search.
   */
  app.get("/mls/document", async (req, res) => {
    const pdfUrl = req.query.url;
    if (!pdfUrl || !pdfUrl.startsWith("https://documents.flexmls.com/")) {
      return res.status(400).json({ ok: false, error: "Missing or invalid url parameter" });
    }

    // We need a browser context with session cookies to fetch the authenticated PDF
    const browser = await getBrowser();
    const context = await browser.newContext({
      userAgent:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    });

    try {
      // Load saved session cookies
      if (fs.existsSync(SESSION_FILE)) {
        const state = JSON.parse(fs.readFileSync(SESSION_FILE, "utf8"));
        await context.addCookies(state.cookies ?? []);
      }

      const response = await context.request.get(pdfUrl, {
        headers: { Accept: "application/pdf,*/*", Referer: "https://mo.flexmls.com/" },
      });

      if (!response.ok()) {
        return res.status(response.status()).json({ ok: false, error: `Upstream returned ${response.status()}` });
      }

      const buffer = await response.body();
      const contentType = response.headers()["content-type"] || "application/pdf";

      // Try to derive a filename from the URL
      const urlPath = new URL(pdfUrl).pathname;
      const filename = urlPath.split("/").pop() || "document.pdf";

      res.setHeader("Content-Type", contentType);
      res.setHeader("Content-Disposition", `attachment; filename="${filename}"`);
      res.setHeader("Content-Length", buffer.length);
      res.send(buffer);

      console.log(`[MLS] Served document: ${filename} (${buffer.length} bytes)`);
    } catch (e) {
      res.status(500).json({ ok: false, error: e.message });
    } finally {
      await context.close();
    }
  });

  /**
   * DELETE /mls/session
   * Clears the saved browser session (forces re-login on next call)
   */
  app.delete("/mls/session", (req, res) => {
    try {
      if (fs.existsSync(SESSION_FILE)) fs.unlinkSync(SESSION_FILE);
      res.json({ ok: true, message: "Session cleared" });
    } catch (e) {
      res.status(500).json({ ok: false, error: e.message });
    }
  });

  console.log("[MLS] Routes registered: POST /mls/search, GET /mls/document, DELETE /mls/session");
}
