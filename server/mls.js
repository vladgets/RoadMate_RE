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
import path from "path";
import { execFileSync } from "child_process";

// Where we store the Chromium binary on the Render persistent disk.
// We pass executablePath directly to chromium.launch() so Playwright
// doesn't need to read any env var — it always finds the right binary.
const BROWSERS_PATH = "/data/playwright";

function ensureChromium() {
  const alreadyInstalled =
    fs.existsSync(BROWSERS_PATH) &&
    fs.readdirSync(BROWSERS_PATH).some((d) => d.startsWith("chromium"));

  if (alreadyInstalled) {
    console.log("[MLS] Chromium found in", BROWSERS_PATH);
    return;
  }

  console.log("[MLS] Installing Chromium to", BROWSERS_PATH, "...");
  fs.mkdirSync(BROWSERS_PATH, { recursive: true });
  execFileSync("npx", ["playwright", "install", "chromium"], {
    stdio: "inherit",
    env: { ...process.env, PLAYWRIGHT_BROWSERS_PATH: BROWSERS_PATH },
  });
  console.log("[MLS] Chromium ready.");
}

function findChromiumExecutable() {
  if (!fs.existsSync(BROWSERS_PATH)) return null;
  for (const dir of fs.readdirSync(BROWSERS_PATH)) {
    if (!dir.startsWith("chromium")) continue;
    // Playwright installs headless shell or full chrome under versioned dirs
    const candidates = [
      path.join(BROWSERS_PATH, dir, "chrome-headless-shell-linux64", "chrome-headless-shell"),
      path.join(BROWSERS_PATH, dir, "chrome-linux64", "chrome"),
      path.join(BROWSERS_PATH, dir, "chrome-headless-shell-linux", "chrome-headless-shell"),
      path.join(BROWSERS_PATH, dir, "chrome-linux", "chrome"),
    ];
    for (const exe of candidates) {
      if (fs.existsSync(exe)) {
        console.log("[MLS] Chromium executable:", exe);
        return exe;
      }
    }
  }
  return null;
}

ensureChromium();

const BASE_URL = "https://mo.flexmls.com";
const SESSION_FILE = process.env.MLS_SESSION_FILE ?? "/data/mls_session.json";

// ─── Browser singleton ───────────────────────────────────────────────────────

let _browser = null;

async function getBrowser() {
  if (!_browser || !_browser.isConnected()) {
    const executablePath = findChromiumExecutable() ?? undefined;
    _browser = await chromium.launch({
      headless: true,
      executablePath,
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

async function waitForTopFrame(page, timeout = 15000) {
  // Wait for the top_frame to appear rather than sleeping a fixed duration
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const frame = page.frames().find(f => f.url().includes("top_frame"));
    if (frame) return frame;
    await page.waitForTimeout(200);
  }
  return null;
}

async function waitForDetailFrame(page, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    for (const frame of page.frames()) {
      if (frame.url().includes("display_custom_report")) {
        const r = await safeEval(frame, () => document.body?.innerText ?? "", undefined, 2000);
        if (typeof r === "string" && r.length > 200) return frame;
      }
    }
    await page.waitForTimeout(200);
  }
  return null;
}

// safeEval: run fn in frame with a hard ms timeout.
// Returns {_timeout:true} or {_error:msg} instead of hanging indefinitely.
function safeEval(frame, fn, arg, ms = 3000) {
  return Promise.race([
    frame.evaluate(fn, arg).catch(e => ({ _error: e.message })),
    new Promise(r => setTimeout(() => r({ _timeout: true }), ms)),
  ]);
}

async function waitForResultsFrame(page, dashboardUrl, timeout = 45000) {
  // view_frame is the named content area where search results load.
  // We wait for it to navigate AWAY from the initial dashboard URL.
  const DASHBOARD_PATTERNS = ["flexdash", "private_dashboard"];

  const deadline = Date.now() + timeout;
  let lastLogAt = 0;

  while (Date.now() < deadline) {
    // (no periodic frame dump — nav events logged below are sufficient)

    for (const frame of page.frames()) {
      const url = frame.url();
      if (!url || url === "about:blank") continue;

      // Primary target: view_frame that has left the dashboard URL
      if (frame.name() === "view_frame") {
        const isStillDashboard = url === dashboardUrl ||
          DASHBOARD_PATTERNS.some(p => url.includes(p));
        if (!isStillDashboard) {
          const r = await safeEval(frame, () => ({
            len: document.body?.innerText?.length ?? 0,
            text: document.body?.innerText?.slice(0, 100) ?? "",
          }), undefined, 2500);
          if (!r._timeout && !r._error && r.len > 200) {
            return frame;
          }
        }
        continue;
      }

      // Secondary: any frame whose URL suggests search results
      const RESULT_PATTERNS = ["listnum", "display_custom_report", "cgi-bin/mainmenu"];
      if (RESULT_PATTERNS.some(p => url.includes(p))) {
        const r = await safeEval(frame, () => ({
          len: document.body?.innerText?.length ?? 0,
          text: document.body?.innerText?.slice(0, 100) ?? "",
        }), undefined, 2500);
        if (!r._timeout && !r._error && r.len > 200 && !looksLikeScript(r.text)) {
          return frame;
        }
      }
    }

    await page.waitForTimeout(400);
  }

  // Timeout — return view_frame with whatever it has, for best-effort extraction
  const vf = page.frames().find(f => f.name() === "view_frame");
  console.log("[MLS] waitForResultsFrame timed out. view_frame URL:", vf?.url()?.slice(0, 100));
  return vf ?? null;
}

async function searchAddress(page, address) {
  // Block third-party frames that navigate constantly and cause Playwright's
  // between-keystroke settle-waits to block indefinitely (especially in headless mode).
  // WalkMe, Beamer, and HubSpot iframes serve no automation purpose.
  await page.route(url => {
    const u = url.toString();
    return u.includes("walkme.com") ||
           u.includes("getbeamer.com") ||
           u.includes("hs-sites.com") ||
           u.includes("collect.flexmls.com");
  }, route => route.abort());
  console.log("[MLS] Loading Flexmls app...");
  await page.goto("https://mo.flexmls.com/", { waitUntil: "domcontentloaded", timeout: 20000 });

  if (page.url().includes("/ticket")) {
    console.log("[MLS] Direct nav failed, using SSO redirect...");
    await page.goto("https://members.flexmls.com/ticket/redirect", {
      waitUntil: "domcontentloaded", timeout: 20000,
    });
  }
  // Log key frame navigations only (skip chrome-error and about:blank noise)
  page.on("framenavigated", f => {
    const u = f.url();
    if (u && u !== "about:blank" && !u.startsWith("chrome-error://") && f.name()) {
      console.log(`[MLS] nav [${f.name()}]: ${u.slice(0, 100)}`);
    }
  });

  // Wait for top_frame to appear in the frame list (URL-based, no evaluate needed)
  const topFrame = await waitForTopFrame(page, 15000);
  if (!topFrame) throw new Error("top_frame did not load");

  // Record view_frame's initial (dashboard) URL so we can detect when it navigates to results
  const viewFrame = page.frames().find(f => f.name() === "view_frame");
  const dashboardUrl = viewFrame?.url() ?? "";

  // Poll until top_frame context becomes accessible via safeEval.
  let topFrameReady = false;
  for (let i = 0; i < 30; i++) {
    const r = await safeEval(topFrame, () =>
      document.querySelectorAll('input[placeholder*="Address"]').length
    , undefined, 1500);
    if (r > 0) { topFrameReady = true; break; }
    await page.waitForTimeout(400);
  }
  if (!topFrameReady) throw new Error("top_frame context never became available");

  // Type address character-by-character to trigger React's autocomplete XHR
  const searchLocator = topFrame.locator('input.quick-launch__input, input[placeholder*="Address"]').first();
  await searchLocator.click({ timeout: 8000, force: true, noWaitAfter: true });
  await searchLocator.clear({ timeout: 3000, noWaitAfter: true }).catch(() => {});
  console.log("[MLS] Searching:", address);
  await searchLocator.pressSequentially(address, { delay: 20, timeout: 60000 });

  // Step 2: Poll for autocomplete results instead of fixed sleep (max 4s)
  console.log("[MLS] Waiting for autocomplete...");
  const autocompleteReady = topFrame.locator('li.result.selectable').first();
  await autocompleteReady.waitFor({ state: 'visible', timeout: 4000 }).catch(() => {});

  // Step 3: Try clicking the first autocomplete result, fall back to Enter.
  // Both actions may timeout because child frames are still navigating (Playwright
  // waits for them mid-action). We use force:true+noWaitAfter:true to avoid this,
  // and catch any remaining timeouts — if view_frame already started navigating the
  // search was submitted successfully regardless.
  const autocompleteItem = topFrame.locator('li.result.selectable').first();
  let submitted = "pending";
  try {
    const count = await autocompleteItem.count();
    if (count > 0) {
      await autocompleteItem.click({ timeout: 4000, force: true, noWaitAfter: true });
      submitted = "autocomplete_click";
    }
  } catch (e) {
    // timeout OK — fall through to Enter
  }

  if (submitted !== "autocomplete_click") {
    try {
      await searchLocator.press("Enter", { timeout: 5000 });
      submitted = "enter";
    } catch (e) {
      // Timeout here is OK — view_frame may already be navigating to results
      submitted = "enter_timeout";
    }
  }

  // Wait for view_frame to navigate from the dashboard to search results
  const resultsFrame = await waitForResultsFrame(page, dashboardUrl, 45000);
  if (!resultsFrame) console.log("[MLS] Results frame not found after 45s");

  // Also wait for the detail report sub-frame
  await waitForDetailFrame(page, 10000);
}

// ─── Extract listing data ─────────────────────────────────────────────────────

// ─── Documents via giveMeMore / supplement.html ───────────────────────────────
//
// In Flexmls's embedded detail view (display_custom_report with allow_linkbar=N)
// the Documents tab is hidden. The only route to supplement/document data is the
// "More..." link which calls giveMeMore(listnbr, listingid, matechid, techid) to
// load /cgi-bin/mainmenu.cgi?cmd=srv+lib/supplement/supplement.html into
// moreSupplementFrame. That page contains documents.push() calls for any PDFs
// attached to the listing.

function parseDocumentsPush(source) {
  const docs = [];
  const docRegex = /documents\.push\(new Document\(([^)]+)\)\)/g;
  let match;
  while ((match = docRegex.exec(source)) !== null) {
    const raw = match[1];
    const parts = [];
    let current = "";
    let inQuote = false;
    for (const ch of raw) {
      if (ch === '"') { inQuote = !inQuote; }
      else if (ch === "," && !inQuote) { parts.push(current.trim()); current = ""; }
      else { current += ch; }
    }
    parts.push(current.trim());
    const [pictureId, , , description, , extension, , , modDate, modTime, confidentiality, customUrl] = parts;
    const ext = (extension || "pdf").replace(/^['"]|['"]$/g, "");
    const id  = pictureId.replace(/^['"]|['"]$/g, "");
    const pdfUrl = customUrl?.replace(/^['"]|['"]$/g, "") ||
      `https://documents.flexmls.com/documents/mo/${id}.${ext}`;
    docs.push({
      name: description?.replace(/^['"]|['"]$/g, "") || "Unnamed",
      extension: ext,
      confidentiality: confidentiality?.replace(/^['"]|['"]$/g, "") || "unknown",
      modifiedDate: modDate?.replace(/^['"]|['"]$/g, "") || "",
      url: pdfUrl,
    });
  }
  return docs;
}

async function fetchDocuments(page, viewFrame) {
  // The Documents tab is #detail_documents_link inside the view_frame (listnum/step2).
  // Clicking it navigates iframe_detail to documentviewer.html which contains
  // documents.push() calls for any PDFs attached to the listing.
  console.log("[MLS] Clicking Documents tab (#detail_documents_link)...");

  const clicked = await safeEval(viewFrame, () => {
    const el = document.querySelector("#detail_documents_link");
    if (!el) return false;
    el.click();
    return true;
  }, undefined, 3000);

  if (!clicked || clicked._timeout || clicked._error) {
    console.log("[MLS] #detail_documents_link not found in view_frame");
    return [];
  }

  // Wait for iframe_detail to navigate to documentviewer.html
  let docFrame = null;
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    docFrame = page.frames().find(f => f.url().includes("documentviewer"));
    if (docFrame) break;
    await page.waitForTimeout(200);
  }

  if (!docFrame) {
    console.log("[MLS] documentviewer frame did not appear");
    return [];
  }

  console.log("[MLS] documentviewer frame:", docFrame.url().slice(0, 100));

  // Wait for content to be injected
  let source = "";
  const deadline2 = Date.now() + 8000;
  while (Date.now() < deadline2) {
    source = await docFrame.content().catch(() => "");
    if (source.includes("documents.push")) break;
    await page.waitForTimeout(300);
  }

  const docs = parseDocumentsPush(source);
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

// Returns true if text looks like minified/raw JavaScript (not property content)
function looksLikeScript(text) {
  const t = text.trimStart();
  return (
    t.startsWith("!function") ||
    t.startsWith("function(") ||
    t.startsWith("(function") ||
    t.startsWith("var ") ||
    t.startsWith("/*") ||
    // high density of JS syntax characters
    (t.length > 200 && (t.match(/[{};()=>]/g) || []).length / t.length > 0.08)
  );
}

async function extractListingData(page, context) {
  // Use view_frame by name (the main content area) — it's the definitive results frame
  const viewFrame = page.frames().find(f => f.name() === "view_frame");
  const SKIP = ["about:blank", "javascript:", "data:", "top_frame", "walkme", "beamer", "getbeamer", "hs-sites.com"];

  let bestFrame = viewFrame ?? null;
  let bestFrameText = "";
  let detailFrame = null; // iframe_detail (display_custom_report) — used for document fetching

  // Read view_frame first; fall back to other frames if it's blocked
  for (const frame of page.frames()) {
    const url = frame.url();
    if (!url || SKIP.some(p => url.includes(p))) continue;

    const r = await safeEval(frame, () => document.body?.innerText ?? "", undefined, 3000);
    const text = (typeof r === "string") ? r : "";

    // iframe_detail (display_custom_report) is used for document access via giveMeMore
    if (url.includes("display_custom_report")) {
      detailFrame = frame;
    }

    if (looksLikeScript(text)) continue;

    const isViewFrame = frame.name() === "view_frame";
    const score = text.length + (isViewFrame ? 200000 : 0) +
      (url.includes("display_custom_report") ? 100000 : 0);

    const bestScore = bestFrameText.length +
      (bestFrame?.name() === "view_frame" ? 200000 : 0) +
      (bestFrame?.url().includes("display_custom_report") ? 100000 : 0);

    if (score > bestScore) {
      bestFrameText = text;
      bestFrame = frame;
    }
  }


  const structured = await safeEval(bestFrame ?? page.mainFrame(), () => {
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
  }, undefined, 3000).catch(() => ({}));

  // fetchDocuments needs view_frame (listnum/step2) to click #detail_documents_link
  const documents = viewFrame
    ? await fetchDocuments(page, viewFrame)
    : [];

  return {
    url: page.url(),
    viewFrameUrl: viewFrame?.url() ?? null,
    structured: (structured && !structured._timeout && !structured._error) ? structured : {},
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

  // Hard 3-minute timeout — prevents hung browser contexts from leaking memory
  const hardTimeout = new Promise((_, reject) =>
    setTimeout(() => reject(new Error("mlsSearchProperty hard timeout (3min)")), 180_000)
  );

  try {
    const result = await Promise.race([
      (async () => {
        await ensureAuthenticated(page, context);
        await searchAddress(page, address);
        const r = await extractListingData(page, context);
        await saveSession(context);
        return { ok: true, ...r };
      })(),
      hardTimeout,
    ]);
    return result;
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
