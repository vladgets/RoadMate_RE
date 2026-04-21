/**
 * Local debug test — mirrors the server's cross-frame fill approach,
 * then inspects autocomplete + form structure before submitting.
 *
 * Run:
 *   cd server && MLS_USERNAME=mo.33875 MLS_PASSWORD='$@#250$*Rb@' node test_mls_submit.mjs
 */

import { chromium } from "playwright";
import fs from "fs";

const USERNAME = process.env.MLS_USERNAME;
const PASSWORD = process.env.MLS_PASSWORD;
const ADDRESS  = process.env.MLS_ADDRESS ?? "27 Regency Way, Manalapan, NJ 07726";
const SESSION_FILE = "/tmp/mls_session_local.json";

if (!USERNAME || !PASSWORD) {
  console.error("Set MLS_USERNAME and MLS_PASSWORD env vars");
  process.exit(1);
}

// ── safeEval helper ───────────────────────────────────────────────────────────
function safeEval(frame, fn, arg, ms = 3000) {
  return Promise.race([
    frame.evaluate(fn, arg).catch(e => ({ _error: e.message })),
    new Promise(r => setTimeout(() => r({ _timeout: true }), ms)),
  ]);
}

const browser = await chromium.launch({ headless: true, slowMo: 0 });
const context = await browser.newContext({
  userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
  viewport: { width: 1280, height: 900 },
});

// Load session if available
if (fs.existsSync(SESSION_FILE)) {
  const state = JSON.parse(fs.readFileSync(SESSION_FILE, "utf8"));
  await context.addCookies(state.cookies ?? []);
  console.log("[+] Session loaded from", SESSION_FILE);
}

const page = await context.newPage();

// Block third-party frames (matches server behavior)
await page.route(url => {
  const u = url.toString();
  return u.includes("walkme.com") ||
         u.includes("getbeamer.com") ||
         u.includes("hs-sites.com") ||
         u.includes("collect.flexmls.com");
}, route => route.abort());
console.log("[+] Third-party frames blocked");

// Log every frame navigation
page.on("framenavigated", f => {
  const u = f.url();
  if (u && u !== "about:blank")
    console.log(`[nav] [${f.name() || "anon"}] → ${u.slice(0, 120)}`);
});

// ── Navigate ──────────────────────────────────────────────────────────────────
console.log("\n[1] Navigating to mo.flexmls.com...");
await page.goto("https://mo.flexmls.com/", { waitUntil: "domcontentloaded", timeout: 30000 });
console.log("URL:", page.url());

// ── CAPTCHA solver ────────────────────────────────────────────────────────────
async function solveCaptcha(pg) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) { console.log("  No OPENAI_API_KEY — solve CAPTCHA manually"); return; }
  for (let attempt = 1; attempt <= 5; attempt++) {
    const captcha = await pg.$("#captchaImage");
    if (!captcha) return;
    const imageData = await pg.$eval("#captchaImage", img => img.src.includes("base64,") ? img.src.split("base64,")[1] : null);
    if (!imageData) return;
    const resp = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ model: "gpt-4o", max_tokens: 20, messages: [{ role: "user", content: [
        { type: "text", text: "CAPTCHA image with 4-6 chars, case-sensitive. Reply with ONLY the exact characters, no spaces." },
        { type: "image_url", image_url: { url: `data:image/jpeg;base64,${imageData}`, detail: "high" } },
      ]}]}),
    });
    const data = await resp.json();
    const answer = data.choices?.[0]?.message?.content?.trim() ?? "";
    console.log(`  CAPTCHA attempt ${attempt}: "${answer}"`);
    await pg.fill("#capInput", answer);
    await pg.click("#capSubmit");
    await pg.waitForTimeout(3000);
    if (!pg.url().includes("/ticket")) return;
  }
}

// ── Login if needed ───────────────────────────────────────────────────────────
if (page.url().includes("/ticket") || page.url().includes("login")) {
  console.log("[2] Login required...");
  await page.screenshot({ path: "/tmp/mls_local_step1.png" });
  console.log("  Screenshot: /tmp/mls_local_step1.png");

  // Wait for either CAPTCHA image or username input
  await Promise.race([
    page.waitForSelector("#captchaImage", { timeout: 10000 }).catch(() => {}),
    page.waitForSelector("input[name='user']", { state: "visible", timeout: 10000 }).catch(() => {}),
  ]);
  await page.screenshot({ path: "/tmp/mls_local_step2.png" });

  // Solve CAPTCHA if present
  await solveCaptcha(page);
  await page.screenshot({ path: "/tmp/mls_local_step3.png" });

  // Username
  const userInput = await page.waitForSelector("input[name='user']", { state: "visible", timeout: 15000 }).catch(() => null);
  console.log("  Username input found:", !!userInput);
  if (userInput) {
    await userInput.fill(USERNAME);
    await page.click("#login-button").catch(() => page.keyboard.press("Enter"));
    console.log("  Username submitted");
    await page.waitForTimeout(2000);
    await page.screenshot({ path: "/tmp/mls_local_step4.png" });

    // Password
    const passInput = await page.waitForSelector("input[type='password']", { state: "visible", timeout: 10000 }).catch(() => null);
    console.log("  Password input found:", !!passInput);
    if (passInput) {
      await passInput.fill(PASSWORD);
    } else {
      // hiddenPassword fallback
      await page.$eval("input[name='hiddenPassword']", (el, pw) => {
        el.value = pw;
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
      }, PASSWORD).catch(() => {});
    }
    await page.click("#login-button").catch(() => page.keyboard.press("Enter"));
    console.log("  Password submitted, waiting for redirect...");
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline && page.url().includes("/ticket")) await page.waitForTimeout(500);
  }
  console.log("After login:", page.url());
  await page.screenshot({ path: "/tmp/mls_local_after_login.png" });
  const cookies = await context.cookies();
  fs.writeFileSync(SESSION_FILE, JSON.stringify({ cookies }, null, 2));
  console.log("[+] Session saved to", SESSION_FILE);
}

// ── Navigate to Flexmls app (may differ from initial URL after login/redirect) ──
if (!page.url().includes("mo.flexmls.com") || page.url().includes("dashboard")) {
  console.log("\n[2b] Navigating to mo.flexmls.com after login...");
  await page.goto("https://mo.flexmls.com/", { waitUntil: "domcontentloaded", timeout: 20000 });
  console.log("App URL:", page.url());
}

// ── Wait for top_frame ────────────────────────────────────────────────────────
console.log("\n[3] Waiting for top_frame...");
let topFrame = null;
for (let i = 0; i < 40; i++) {
  topFrame = page.frames().find(f => f.url().includes("top_frame"));
  if (topFrame) break;
  await new Promise(r => setTimeout(r, 300));
}
if (!topFrame) { console.error("top_frame not found"); process.exit(1); }
console.log("top_frame:", topFrame.url());

// ── Poll until top_frame is readable ─────────────────────────────────────────
console.log("\n[4] Polling top_frame for readiness...");
let ready = false;
for (let i = 0; i < 30; i++) {
  const r = await safeEval(topFrame, () =>
    Array.from(document.querySelectorAll("input")).map(inp => ({
      type: inp.type, placeholder: inp.placeholder, visible: inp.offsetParent !== null,
    }))
  , undefined, 1500);
  if (Array.isArray(r) && r.length > 0) {
    console.log(`top_frame ready after ${i} polls. Inputs:`, JSON.stringify(r));
    ready = true;
    break;
  }
  process.stdout.write(".");
  await new Promise(r => setTimeout(r, 400));
}
console.log("");
if (!ready) { console.error("top_frame never became ready"); process.exit(1); }

// Listen for network requests to see what XHR the QuickLaunch fires
const xhrLog = [];
page.on("request", req => {
  const url = req.url();
  if (url.includes("quicklaunch") || url.includes("autocomplete") || url.includes("suggest") || url.includes("search")) {
    xhrLog.push({ method: req.method(), url: url.slice(0, 150) });
    console.log(`  [XHR] ${req.method()} ${url.slice(0, 150)}`);
  }
});

// Click to focus the input first
console.log("\n[5] Clicking input to focus...");
const searchLocator = topFrame.locator('input[placeholder*="Address"]').first();
await searchLocator.click({ timeout: 5000 }).catch(e => console.log("  click failed:", e.message));

// Clear and type character-by-character (pressSequentially sends individual keydown/keyup events)
console.log("  Clearing and typing address character by character...");
await searchLocator.clear({ timeout: 3000 }).catch(() => {});
await searchLocator.pressSequentially(ADDRESS, { delay: 40, timeout: 30000 });
console.log("  Type complete");

// ── Wait for autocomplete XHR ─────────────────────────────────────────────────
console.log("\n[6] Waiting 4s for autocomplete XHR and results...");
await new Promise(r => setTimeout(r, 4000));
console.log("  XHRs seen:", JSON.stringify(xhrLog));

// ── Inspect: autocomplete + widget structure ──────────────────────────────────
console.log("\n[7] Inspecting autocomplete and widget...");
const inspection = await safeEval(topFrame, () => {
  const input = document.querySelector('input[placeholder*="Address"]') || document.querySelector('input[type="text"]');
  const form = input?.closest("form");

  // QuickLaunch-specific selectors
  const quicklaunchContainers = Array.from(document.querySelectorAll('[class*="quicklaunch"], [class*="quick-launch"], [class*="QuickLaunch"]'))
    .map(el => ({ tag: el.tagName, cls: el.className, html: el.outerHTML.slice(0, 300) }));

  // All list items near the input
  const listItems = Array.from(document.querySelectorAll('li, [role="option"], [role="listitem"]'))
    .filter(el => el.offsetParent !== null) // visible only
    .slice(0, 10)
    .map(el => ({ cls: el.className, text: el.innerText?.trim().slice(0, 80) }));

  return {
    inputClass: input?.className,
    inputParentClass: input?.parentElement?.className,
    inputGrandparentHTML: input?.parentElement?.parentElement?.outerHTML?.slice(0, 600),
    formFound: !!form,
    quicklaunchContainers: quicklaunchContainers.slice(0, 5),
    visibleListItems: listItems,
  };
}, undefined, 5000);

console.log("\n=== INPUT CLASSES ===", inspection?.inputClass);
console.log("=== PARENT CLASS ===", inspection?.inputParentClass);
console.log("\n=== GRANDPARENT HTML ===");
console.log(inspection?.inputGrandparentHTML);
console.log("\n=== QUICKLAUNCH CONTAINERS ===");
console.log(JSON.stringify(inspection?.quicklaunchContainers, null, 2));
console.log("\n=== VISIBLE LIST ITEMS ===");
console.log(JSON.stringify(inspection?.visibleListItems, null, 2));

// ── Inspect quicklaunch-pane items ────────────────────────────────────────────
const paneItems = await safeEval(topFrame, () => {
  const pane = document.querySelector('.quicklaunch-pane, [class*="quicklaunch-pane"]');
  if (!pane) return { found: false };
  const items = Array.from(pane.querySelectorAll('li, [role="option"]'));
  return {
    found: true,
    paneClass: pane.className,
    paneStyle: pane.getAttribute('style'),
    itemCount: items.length,
    items: items.slice(0, 5).map(el => ({ cls: el.className, text: el.innerText?.trim().slice(0, 80) })),
    paneHTML: pane.outerHTML.slice(0, 800),
  };
}, undefined, 3000);
console.log("\n=== QUICKLAUNCH PANE ===");
console.log(JSON.stringify(paneItems, null, 2));

// ── Attempt submission ────────────────────────────────────────────────────────
console.log("\n[8] Attempting submission...");

// Try clicking first autocomplete result in quicklaunch-pane
if (paneItems?.found && paneItems?.itemCount > 0) {
  console.log("  Clicking first quicklaunch-pane item via locator...");
  try {
    await topFrame.locator('.quicklaunch-pane li, .quicklaunch-pane [role="option"]').first().click({ timeout: 3000 });
    console.log("  Clicked first pane item");
  } catch(e) {
    console.log("  Pane click failed:", e.message);
  }
} else {
  // No autocomplete items — press Enter via locator (isTrusted=true)
  console.log("  No autocomplete items, pressing Enter via locator...");
  try {
    await topFrame.locator('input[placeholder*="Address"]').first().press("Enter", { timeout: 5000 });
    console.log("  press('Enter') succeeded");
  } catch (e) {
    console.log("  press('Enter') failed:", e.message);
  }
}

// ── Watch what happens for 20s ────────────────────────────────────────────────
console.log("\n[9] Watching frames for 20s after submission...");
for (let i = 0; i < 20; i++) {
  await new Promise(r => setTimeout(r, 1000));
  const frames = page.frames().map(f => `[${f.name()||"anon"}]${f.url().slice(0,70)}`);
  process.stdout.write(`\r[t+${i+1}s] ${frames.length} frames`);
}
console.log("\n\nFinal frames:");
page.frames().forEach(f => {
  if (f.url() && f.url() !== "about:blank")
    console.log(` [${f.name()||"anon"}] ${f.url()}`);
});

// ── Read view_frame content ───────────────────────────────────────────────────
const vf = page.frames().find(f => f.name() === "view_frame");
if (vf) {
  console.log("\n[10] view_frame content:");
  const r = await safeEval(vf, () => ({ url: location.href, text: document.body?.innerText?.slice(0, 500) }), undefined, 5000);
  console.log(JSON.stringify(r, null, 2));
}

// ── Inspect all frames for document links ─────────────────────────────────────
console.log("\n[11] Inspecting all frames for document links...");
for (const frame of page.frames()) {
  const url = frame.url();
  if (!url || url === "about:blank" || url.includes("walkme") || url.includes("beamer") || url.includes("hs-sites")) continue;

  const r = await safeEval(frame, () => {
    // Look for documents tab link
    const docsLink = document.querySelector('#detail_documents_link, [id*="document"], a[href*="document"], [class*="document"]');
    const allLinks = Array.from(document.querySelectorAll('a[id], a[class*="tab"], li[class*="tab"], [data-tab]'))
      .map(el => ({ id: el.id, cls: el.className, text: el.innerText?.trim().slice(0,40), href: el.href?.slice(0,80) }))
      .filter(l => l.text);
    return {
      docsLinkFound: !!docsLink,
      docsLinkId: docsLink?.id,
      docsLinkText: docsLink?.innerText?.trim(),
      tabLinks: allLinks.slice(0, 10),
    };
  }, undefined, 3000);

  if (r && !r._timeout && !r._error) {
    console.log(`\n  Frame [${frame.name()||"anon"}] ${url.slice(0, 100)}`);
    console.log("  docsLink:", r.docsLinkFound, r.docsLinkId, r.docsLinkText);
    if (r.tabLinks?.length) console.log("  tabs:", JSON.stringify(r.tabLinks));
  }
}

// ── Try clicking docs link in iframe_detail ───────────────────────────────────
console.log("\n[12] Looking for Documents tab in iframe_detail...");
const detailFrame = page.frames().find(f => f.url().includes("display_custom_report") || f.name() === "iframe_detail");
if (detailFrame) {
  console.log("  Found detail frame:", detailFrame.url().slice(0, 120));

  // Dump all links/buttons in the detail frame
  const links = await safeEval(detailFrame, () => {
    return Array.from(document.querySelectorAll('a, button'))
      .filter(el => el.offsetParent !== null)
      .map(el => ({ tag: el.tagName, id: el.id, cls: el.className, text: el.innerText?.trim().slice(0,60), href: el.href?.slice(0,100) }))
      .slice(0, 20);
  }, undefined, 5000);
  console.log("  Visible links/buttons in detail frame:");
  console.log(JSON.stringify(links, null, 2));

  // Check for document-viewer iframes
  const docViewerFrames = page.frames().filter(f => f.url().includes("document"));
  console.log("  documentviewer frames:", docViewerFrames.map(f => f.url().slice(0, 100)));

  // Check iframe_detail HTML for document references
  const docCheck = await safeEval(detailFrame, () => {
    const html = document.body?.innerHTML ?? "";
    const docMatches = html.match(/document[Vv]iewer|\.pdf|documents\.push|attachm/g) ?? [];
    return { docMatches: [...new Set(docMatches)].slice(0, 10), bodyLen: document.body?.innerText?.length };
  }, undefined, 5000);
  console.log("  Document references in detail frame HTML:", JSON.stringify(docCheck));
} else {
  console.log("  No detail frame found. Available frames:");
  page.frames().forEach(f => {
    if (f.url() && f.url() !== "about:blank") console.log("   ", f.url().slice(0, 100));
  });
}

// ── Actually click the Documents tab and inspect what loads ──────────────────
console.log("\n[13] Clicking Documents tab (#adv_document) in view_frame...");
const vfForDocs = page.frames().find(f => f.name() === "view_frame");
if (vfForDocs) {
  const docsLink = await vfForDocs.$("#adv_document").catch(() => null);
  if (docsLink) {
    // Inspect visibility before clicking
    const elInfo = await safeEval(vfForDocs, () => {
      const el = document.querySelector("#adv_document");
      if (!el) return null;
      const r = el.getBoundingClientRect();
      const cs = window.getComputedStyle(el);
      return { display: cs.display, visibility: cs.visibility, opacity: cs.opacity,
               offsetParent: !!el.offsetParent, rect: { top: r.top, left: r.left, w: r.width, h: r.height },
               html: el.outerHTML.slice(0, 200) };
    }, undefined, 3000);
    console.log("  #adv_document info:", JSON.stringify(elInfo));

    await docsLink.click({ force: true }).catch(e => console.log("  click error:", e.message));
    console.log("  Clicked. Waiting 5s for documentviewer frame...");
    await new Promise(r => setTimeout(r, 5000));

    // Check for new frames
    console.log("  Frames after click:");
    page.frames().forEach(f => {
      if (f.url() && f.url() !== "about:blank") console.log("   ", f.url().slice(0, 120));
    });

    const docFrame = page.frames().find(f => f.url().includes("documentviewer") || f.url().includes("document"));
    if (docFrame) {
      console.log("\n  Document frame URL:", docFrame.url());
      const src = await docFrame.content().catch(() => "");
      console.log("  Has documents.push:", src.includes("documents.push"));
      const matches = src.match(/documents\.push\([^)]+\)/g) ?? [];
      console.log("  document entries:", matches.length);
      if (matches.length) console.log("  First entry:", matches[0].slice(0, 200));
    } else {
      // Maybe docs load inline — check view_frame for document links
      const docsInline = await safeEval(vfForDocs, () => {
        const links = Array.from(document.querySelectorAll('a[href*=".pdf"], a[href*="document"], iframe[src*="document"]'));
        return links.map(el => ({ tag: el.tagName, href: el.href?.slice(0,120), src: el.src?.slice(0,120) }));
      }, undefined, 3000);
      console.log("  No document frame found. Inline doc links:", JSON.stringify(docsInline));

      // Dump any new iframes
      const iframes = await safeEval(vfForDocs, () =>
        Array.from(document.querySelectorAll("iframe")).map(f => ({ src: f.src?.slice(0,120), name: f.name }))
      , undefined, 3000);
      console.log("  iframes in view_frame:", JSON.stringify(iframes));
    }
  } else {
    console.log("  #adv_document not found in view_frame");
  }
}

// ── Try navigating iframe_detail with allow_linkbar=Y ────────────────────────
console.log("\n[14] Re-navigating iframe_detail with allow_linkbar=Y...");
const detailFr = page.frames().find(f => f.url().includes("display_custom_report"));
if (detailFr) {
  const newUrl = detailFr.url().replace("allow_linkbar=N", "allow_linkbar=Y");
  console.log("  New URL:", newUrl.slice(0, 150));
  await detailFr.goto(newUrl, { waitUntil: "domcontentloaded", timeout: 15000 }).catch(e => console.log("  goto error:", e.message));
  await new Promise(r => setTimeout(r, 3000));

  // Check for Documents tab link in this frame now
  const linkbarLinks = await safeEval(detailFr, () => {
    const links = Array.from(document.querySelectorAll("a[id], a[href*='document'], li[id*='document'], [class*='linkbar'] a"));
    return links.map(el => ({ id: el.id, text: el.innerText?.trim().slice(0,60), href: el.href?.slice(0,100), cls: el.className }));
  }, undefined, 5000);
  console.log("  Linkbar links:", JSON.stringify(linkbarLinks, null, 2));

  // Also look at any sub-frames that appeared
  const newFrames = page.frames().filter(f => f.url() && f.url() !== "about:blank" && !f.url().includes("flexmls.com/"));
  console.log("  New frames:", newFrames.map(f => f.url().slice(0, 100)));

  // Check for document JS data in the full page HTML
  const htmlCheck = await safeEval(detailFr, () => {
    const html = document.documentElement.outerHTML;
    const pushMatches = html.match(/documents\.push\([^)]+\)/g) ?? [];
    const docLinks = Array.from(document.querySelectorAll('[href*=".pdf"], [href*="document"]')).map(el => el.href?.slice(0,120));
    return { pushCount: pushMatches.length, first: pushMatches[0]?.slice(0,200), docLinks: docLinks.slice(0,5), bodyLen: document.body?.innerText?.length };
  }, undefined, 5000);
  console.log("  HTML check:", JSON.stringify(htmlCheck, null, 2));
}

// ── Try clicking the Detail tab, then look for Documents tab ─────────────────
console.log("\n[15] Clicking #tab_detail in view_frame to load full listing detail...");
const vfD = page.frames().find(f => f.name() === "view_frame");
if (vfD) {
  // Call the tab via JS (it has no href)
  await vfD.evaluate(() => {
    document.querySelector('#tab_detail')?.click();
  });
  console.log("  Clicked tab_detail. Waiting 5s...");
  await new Promise(r => setTimeout(r, 5000));

  // Check iframe_detail URL now
  const detFr2 = page.frames().find(f => f.name() === "iframe_detail");
  console.log("  iframe_detail URL:", detFr2?.url()?.slice(0, 150));

  // Check all frames
  console.log("  All frames:");
  page.frames().forEach(f => {
    if (f.url() && f.url() !== "about:blank") console.log("   ", f.name() || "anon", "|", f.url().slice(0, 120));
  });

  if (detFr2) {
    // Look for document links in iframe_detail
    const detLinks = await safeEval(detFr2, () => {
      const links = Array.from(document.querySelectorAll("a[id], [id*='document'], [href*='document'], [class*='linkbar'] a, li.c-tab, li[class*='tab']"));
      return links.map(el => ({ id: el.id, text: el.innerText?.trim().slice(0,50), href: el.href?.slice(0,100), cls: el.className }));
    }, undefined, 5000);
    console.log("  iframe_detail links/tabs:", JSON.stringify(detLinks, null, 2));

    // Check for documents.push in the HTML
    const detHtml = await safeEval(detFr2, () => {
      const html = document.documentElement.outerHTML;
      const push = html.match(/documents\.push\([^)]+\)/g) ?? [];
      return { pushCount: push.length, first: push[0]?.slice(0,200), bodyLen: document.body?.innerText?.length };
    }, undefined, 5000);
    console.log("  documents.push count:", detHtml?.pushCount, "bodyLen:", detHtml?.bodyLen);
  }
}

// ── Navigate view_frame directly to the full listing page ────────────────────
console.log("\n[16] Navigating view_frame directly to full listing detail page...");
const listId = "20260410223910748529000000";
const mlsId  = "20140311223451933927000000";
const vfDirect = page.frames().find(f => f.name() === "view_frame");
if (vfDirect) {
  const detailUrl = `https://mo.flexmls.com/start/listing/id/index.html?id=${listId}&mls_id=${mlsId}`;
  console.log("  Navigating to:", detailUrl);
  await vfDirect.goto(detailUrl, { waitUntil: "domcontentloaded", timeout: 15000 }).catch(e => console.log("  goto error:", e.message));
  await new Promise(r => setTimeout(r, 5000));

  console.log("  view_frame URL now:", vfDirect.url().slice(0, 150));
  console.log("  All frames:");
  page.frames().forEach(f => {
    if (f.url() && f.url() !== "about:blank") console.log("   ", f.name() || "anon", "|", f.url().slice(0, 120));
  });

  // Look for document links or tabs in view_frame
  const vfLinks = await safeEval(vfDirect, () => {
    const allLinks = Array.from(document.querySelectorAll("a[id], li[id*='document'], [href*='document'], [class*='linkbar'] a, [class*='tab'] a, ul.c-tabs li, [data-tab]"));
    return allLinks.map(el => ({ id: el.id, tag: el.tagName, text: el.innerText?.trim().slice(0,50), href: el.href?.slice(0,100), cls: el.className?.slice(0,60) }));
  }, undefined, 5000);
  console.log("  Links/tabs in view_frame:", JSON.stringify(vfLinks, null, 2));

  // Check for documents.push in view_frame
  const vfHtml = await safeEval(vfDirect, () => {
    const push = (document.documentElement.outerHTML.match(/documents\.push\([^)]+\)/g) ?? []);
    return { pushCount: push.length, first: push[0]?.slice(0,200) };
  }, undefined, 5000);
  console.log("  documents.push count:", vfHtml?.pushCount);
}

// ── Get full HTML of iframe_detail and look for any document pattern ─────────
console.log("\n[17] Full iframe_detail analysis...");
const ifd = page.frames().find(f => f.name() === "iframe_detail" || f.url().includes("display_custom_report"));
if (ifd) {
  const fullAnalysis = await safeEval(ifd, () => {
    const html = document.documentElement.outerHTML;
    return {
      bodyText: document.body?.innerText?.slice(0, 2000),
      // Search for any scripts containing document/supplement data
      scriptSnippets: Array.from(document.scripts)
        .map(s => s.textContent?.slice(0, 300))
        .filter(t => t && (t.includes("document") || t.includes("supplement") || t.includes("pdf") || t.includes("Document"))),
      // All anchors
      anchors: Array.from(document.querySelectorAll("a")).map(a => ({
        id: a.id, text: a.innerText?.trim().slice(0,50), href: a.href?.slice(0,100)
      })),
      // iframes inside
      subFrames: Array.from(document.querySelectorAll("iframe")).map(f => ({ name: f.name, src: f.src?.slice(0,100) })),
      // URL patterns in innerHTML
      documentUrls: (html.match(/https?:\/\/[^"'<>]+(?:document|supplement|pdf|\.pdf)[^"'<>]*/gi) ?? []).slice(0,10),
      // giveMeMore call
      giveMeMore: (html.match(/giveMeMore\([^)]+\)/)?.[0] ?? null),
    };
  }, undefined, 8000);

  console.log("  bodyText:", fullAnalysis?.bodyText?.slice(0, 500));
  console.log("  scriptSnippets:", JSON.stringify(fullAnalysis?.scriptSnippets?.slice(0,3)));
  console.log("  anchors:", JSON.stringify(fullAnalysis?.anchors));
  console.log("  subFrames:", JSON.stringify(fullAnalysis?.subFrames));
  console.log("  documentUrls:", JSON.stringify(fullAnalysis?.documentUrls));
  console.log("  giveMeMore:", fullAnalysis?.giveMeMore?.slice(0, 300));

  // Try calling giveMeMore if found
  if (fullAnalysis?.giveMeMore) {
    console.log("\n  Calling giveMeMore via JS...");
    await ifd.evaluate((fn) => { eval(fn); }, `try { ${fullAnalysis.giveMeMore} } catch(e) { console.log(e.message); }`).catch(() => {});
    await new Promise(r => setTimeout(r, 3000));
    console.log("  Frames after giveMeMore:");
    page.frames().forEach(f => {
      if (f.url() && f.url() !== "about:blank") console.log("   ", f.name() || "anon", "|", f.url().slice(0, 120));
    });
  }
}

// ── Call giveMeMore with real args and inspect moreSupplementFrame ───────────
console.log("\n[18] Calling giveMeMore with real args and inspecting moreSupplementFrame...");
const ifd2 = page.frames().find(f => f.name() === "iframe_detail" || f.url().includes("display_custom_report"));
if (ifd2) {
  // The anchor href had: giveMeMore('22609846','20260410223910748529000000','20140311223451933927000000','20140811...')
  // Invoke the function in the frame
  const moreResult = await ifd2.evaluate(() => {
    const moreLink = document.querySelector("a[href*='giveMeMore']");
    if (!moreLink) return "no giveMeMore link";
    const href = moreLink.getAttribute("href");
    const args = href.match(/giveMeMore\((.+)\)/)?.[1];
    // Build the XHR URL directly from the function source
    // The moreSupplementFrame src will be set by giveMeMore — extract it
    const script = Array.from(document.scripts).find(s => s.textContent.includes("moreSupplementFrame"));
    return { href, args, scriptSnippet: script?.textContent?.slice(0, 1000) };
  }).catch(e => ({ error: e.message }));

  console.log("  giveMeMore details:", JSON.stringify(moreResult, null, 2));

  // Check moreSupplementFrame content
  const suppFrame = page.frames().find(f => f.url().includes("moreSupplementFrame") || (f.url().includes("display_custom_report") && f !== ifd2));
  const suppInPage = ifd2.childFrames?.()?.find(f => f.url() !== "about:blank");
  console.log("  moreSupplementFrame via page.frames():", suppFrame?.url()?.slice(0, 100));
  console.log("  child frames of iframe_detail:", ifd2.childFrames().map(f => f.url().slice(0,100)));

  // Try to call it directly
  await ifd2.evaluate(() => {
    const link = document.querySelector("a[href*='giveMeMore']");
    if (link) {
      // Simulate the click by evaluating its href
      const fn = link.getAttribute("href").replace("javascript:", "");
      try { eval(fn); } catch(e) { console.error("eval error:", e.message); }
    }
  }).catch(() => {});
  await new Promise(r => setTimeout(r, 4000));

  console.log("  Frames after calling giveMeMore:");
  page.frames().forEach(f => {
    if (f.url() && f.url() !== "about:blank") console.log("   ", f.name() || "anon", "|", f.url().slice(0, 120));
  });

  const suppFrame2 = page.frames().find(f => f.name() === "moreSupplementFrame");
  if (suppFrame2) {
    console.log("  moreSupplementFrame URL:", suppFrame2.url().slice(0, 150));
    const suppContent = await safeEval(suppFrame2, () => ({
      bodyText: document.body?.innerText?.slice(0, 500),
      hasDocs: document.documentElement.outerHTML.includes("documents.push"),
      pushMatches: (document.documentElement.outerHTML.match(/documents\.push\([^)]+\)/g) ?? []).slice(0,3),
    }), undefined, 5000);
    console.log("  moreSupplementFrame content:", JSON.stringify(suppContent, null, 2));
  }
}

// ── Read moreSupplementFrame content ─────────────────────────────────────────
console.log("\n[19] Reading moreSupplementFrame content after waiting...");
await new Promise(r => setTimeout(r, 3000));

// Find it by URL this time
let suppFr = page.frames().find(f => f.url().includes("supplement"));
console.log("  supplement frame URL:", suppFr?.url()?.slice(0, 150));

if (suppFr) {
  const suppData = await safeEval(suppFr, () => {
    const html = document.documentElement.outerHTML;
    const pushMatches = html.match(/documents\.push\([^)]+\)/g) ?? [];
    return {
      bodyText: document.body?.innerText?.slice(0, 1000),
      hasDocs: html.includes("documents.push"),
      pushCount: pushMatches.length,
      pushMatches: pushMatches.slice(0, 5),
      // All links
      links: Array.from(document.querySelectorAll("a[href]")).map(a => a.href?.slice(0,120)),
    };
  }, undefined, 8000);
  console.log("  suppData:", JSON.stringify(suppData, null, 2));
} else {
  // Try constructing the URL directly and navigating a new frame
  console.log("  No supplement frame found. Trying direct request...");
  // Extract args from the More... link
  const ifd3 = page.frames().find(f => f.url().includes("display_custom_report"));
  if (ifd3) {
    const href = await ifd3.evaluate(() => document.querySelector("a[href*='giveMeMore']")?.getAttribute("href")).catch(() => null);
    console.log("  giveMeMore href:", href?.slice(0, 200));
    const m = href?.match(/giveMeMore\('([^']+)','([^']+)','([^']+)','([^']+)'\)/);
    if (m) {
      const [, listnbr, listingid, matechid, techid] = m;
      const suppUrl = `https://mo.flexmls.com/cgi-bin/mainmenu.cgi?cmd=srv+lib/supplement/supplement.html&listingid=${listingid}&ma_tech_id=${matechid}&tech_id=${techid}`;
      console.log("  Constructed supplement URL:", suppUrl);
      // Navigate in a new tab/context
      const newPage = await context.newPage();
      await newPage.goto(suppUrl, { waitUntil: "domcontentloaded", timeout: 15000 }).catch(e => console.log("  goto error:", e.message));
      await new Promise(r => setTimeout(r, 2000));
      const content = await newPage.content().catch(() => "");
      const pushMatches = content.match(/documents\.push\([^)]+\)/g) ?? [];
      console.log("  Direct page body:", (await newPage.evaluate(() => document.body?.innerText).catch(() => "")).slice(0, 500));
      console.log("  documents.push count:", pushMatches.length);
      if (pushMatches.length) console.log("  First push:", pushMatches[0].slice(0, 200));
      await newPage.close();
    }
  }
}

// ── Find the "Documents" tab in view_frame ────────────────────────────────────
console.log("\n[20] Finding Documents tab in view_frame (listnum/step2)...");
const vf20 = page.frames().find(f => f.name() === "view_frame");
if (vf20) {
  const docTabInfo = await safeEval(vf20, () => {
    // Find all elements whose visible text contains "Documents"
    const all = Array.from(document.querySelectorAll("a, li, span, div, button"))
      .filter(el => el.innerText?.trim() === "Documents" || el.textContent?.trim() === "Documents");
    return all.map(el => ({
      tag: el.tagName, id: el.id, cls: el.className,
      href: el.href?.slice(0, 100),
      parentTag: el.parentElement?.tagName,
      parentId: el.parentElement?.id,
      parentCls: el.parentElement?.className?.slice(0, 60),
      outerHTML: el.outerHTML.slice(0, 200),
    }));
  }, undefined, 5000);
  console.log("  Elements with text 'Documents':", JSON.stringify(docTabInfo, null, 2));

  // Also dump all <a> and <li> elements near "Documents"
  const nearDocs = await safeEval(vf20, () => {
    const linkbar = document.querySelector('[class*="linkbar"], [id*="linkbar"], .details_tabbar, [class*="tabbar"]');
    if (linkbar) return { found: true, html: linkbar.outerHTML.slice(0, 1000) };
    // Search for tab container holding Report/History/Supplement/Documents
    const allEls = Array.from(document.querySelectorAll("a, li"));
    const supplementEl = allEls.find(el => el.innerText?.trim() === "Supplement");
    if (supplementEl) {
      const parent = supplementEl.closest("ul, div, nav, table");
      return { found: true, parent: parent?.tagName, parentId: parent?.id, parentCls: parent?.className, html: parent?.outerHTML?.slice(0, 1000) };
    }
    return { found: false };
  }, undefined, 5000);
  console.log("  Near 'Documents' container:", JSON.stringify(nearDocs, null, 2));
}

// ── Click #detail_documents_link and watch what loads ────────────────────────
console.log("\n[21] Clicking #detail_documents_link...");
const vf21 = page.frames().find(f => f.name() === "view_frame");
if (vf21) {
  const clicked = await vf21.evaluate(() => {
    const el = document.querySelector("#detail_documents_link");
    if (!el) return "not found";
    el.click();
    return "clicked: " + el.outerHTML.slice(0, 100);
  }).catch(e => "error: " + e.message);
  console.log("  Click result:", clicked);

  console.log("  Waiting 5s for document frame...");
  await new Promise(r => setTimeout(r, 5000));

  console.log("  All frames:");
  page.frames().forEach(f => {
    if (f.url() && f.url() !== "about:blank") console.log("   ", f.name() || "anon", "|", f.url().slice(0, 120));
  });

  // Check for any new frames with document-related URLs
  const docFr = page.frames().find(f => f.url().includes("document") || f.url().includes("supplement"));
  if (docFr) {
    console.log("  Document frame found:", docFr.url());
    const src = await docFr.content().catch(() => "");
    const pushes = src.match(/documents\.push\([^)]+\)/g) ?? [];
    console.log("  documents.push count:", pushes.length);
    if (pushes.length) console.log("  First:", pushes[0].slice(0, 200));
    else console.log("  Body text:", (await safeEval(docFr, () => document.body?.innerText?.slice(0,300), undefined, 3000)));
  } else {
    // Maybe it loaded inline inside view_frame — check all sub-iframes
    const subFrames = await safeEval(vf21, () =>
      Array.from(document.querySelectorAll("iframe")).map(f => ({ name: f.name, src: f.src?.slice(0,120) }))
    , undefined, 3000);
    console.log("  Sub-iframes in view_frame:", JSON.stringify(subFrames, null, 2));

    // Check view_frame HTML for document data
    const inlineCheck = await safeEval(vf21, () => {
      const html = document.documentElement.outerHTML;
      const pushes = html.match(/documents\.push\([^)]+\)/g) ?? [];
      return { pushCount: pushes.length, first: pushes[0]?.slice(0,200) };
    }, undefined, 5000);
    console.log("  Inline documents.push:", JSON.stringify(inlineCheck));
  }
}

await browser.close();
