/**
 * Headless test to explore ShowingTime tab in Flexmls listing detail.
 *
 * Run:
 *   cd server
 *   MLS_USERNAME=mo.33875 MLS_PASSWORD='$@#250$*Rb@' OPENAI_API_KEY=sk-... node test_showingtime_local.mjs
 *
 * Optional: MLS_ADDRESS="27 Regency Way, Manalapan, NJ 07726"
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

function safeEval(frame, fn, arg, ms = 3000) {
  return Promise.race([
    frame.evaluate(fn, arg).catch(e => ({ _error: e.message })),
    new Promise(r => setTimeout(() => r({ _timeout: true }), ms)),
  ]);
}

function logFrames(label, page) {
  const frames = page.frames().filter(f => {
    const u = f.url();
    return u && u !== "about:blank" && !u.startsWith("chrome-error://");
  });
  console.log(`\n── FRAMES @ ${label} ──`);
  frames.forEach(f => console.log(`  [${f.name() || "(no name)"}] ${f.url().slice(0, 120)}`));
}

// ── CAPTCHA solver ────────────────────────────────────────────────────────────
async function solveCaptcha(pg) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) { console.log("  No OPENAI_API_KEY — solve CAPTCHA manually"); return; }
  for (let attempt = 1; attempt <= 5; attempt++) {
    const captcha = await pg.$("#captchaImage");
    if (!captcha) return;
    const imageData = await pg.$eval("#captchaImage", img =>
      img.src.includes("base64,") ? img.src.split("base64,")[1] : null
    );
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

// ── Browser + session ─────────────────────────────────────────────────────────
const browser = await chromium.launch({ headless: true, slowMo: 0 });
const context = await browser.newContext({
  userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
  viewport: { width: 1280, height: 900 },
});

if (fs.existsSync(SESSION_FILE)) {
  const state = JSON.parse(fs.readFileSync(SESSION_FILE, "utf8"));
  await context.addCookies(state.cookies ?? []);
  console.log("[+] Session loaded from", SESSION_FILE);
}

const page = await context.newPage();

await page.route(url => {
  const u = url.toString();
  return u.includes("walkme.com") || u.includes("getbeamer.com") ||
         u.includes("hs-sites.com") || u.includes("collect.flexmls.com");
}, route => route.abort());

page.on("framenavigated", f => {
  const u = f.url();
  if (u && u !== "about:blank" && !u.startsWith("chrome-error://") && f.name())
    console.log(`  [nav] [${f.name()}] ${u.slice(0, 120)}`);
});

// ── Navigate + login ──────────────────────────────────────────────────────────
console.log("\n[1] Navigating to mo.flexmls.com...");
await page.goto("https://mo.flexmls.com/", { waitUntil: "domcontentloaded", timeout: 30000 });
console.log("URL:", page.url());

if (page.url().includes("/ticket") || page.url().includes("login")) {
  console.log("[2] Login required...");
  await Promise.race([
    page.waitForSelector("#captchaImage", { timeout: 10000 }).catch(() => {}),
    page.waitForSelector("input[name='user']", { state: "visible", timeout: 10000 }).catch(() => {}),
  ]);

  await solveCaptcha(page);

  const userInput = await page.waitForSelector("input[name='user']", { state: "visible", timeout: 15000 }).catch(() => null);
  if (userInput) {
    await userInput.fill(USERNAME);
    await page.click("#login-button").catch(() => page.keyboard.press("Enter"));
    await page.waitForTimeout(2000);

    const passInput = await page.waitForSelector("input[type='password']", { state: "visible", timeout: 10000 }).catch(() => null);
    if (passInput) {
      await passInput.fill(PASSWORD);
    } else {
      await page.$eval("input[name='hiddenPassword']", (el, pw) => {
        el.value = pw;
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
      }, PASSWORD).catch(() => {});
    }
    await page.click("#login-button").catch(() => page.keyboard.press("Enter"));
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline && page.url().includes("/ticket")) await page.waitForTimeout(500);
  }

  console.log("After login:", page.url());
  const cookies = await context.cookies();
  fs.writeFileSync(SESSION_FILE, JSON.stringify({ cookies }, null, 2));
  console.log("[+] Session saved to", SESSION_FILE);
}

// ── Navigate to Flexmls app (may redirect to broker dashboard after login) ────
if (!page.url().includes("mo.flexmls.com") || page.url().includes("dashboard") || page.url().startsWith("chrome-error")) {
  console.log("\n[2b] Re-navigating to mo.flexmls.com...");
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
if (!topFrame) { console.error("top_frame not found"); await browser.close(); process.exit(1); }
console.log("top_frame:", topFrame.url());

// ── Poll until search input ready ─────────────────────────────────────────────
console.log("\n[4] Polling top_frame for search input...");
let ready = false;
for (let i = 0; i < 30; i++) {
  const r = await safeEval(topFrame, () =>
    document.querySelectorAll('input[placeholder*="Address"]').length
  , undefined, 1500);
  if (r > 0) { ready = true; break; }
  process.stdout.write(".");
  await new Promise(r => setTimeout(r, 400));
}
console.log(ready ? "\nSearch input ready." : "\nSearch input not found.");
if (!ready) { await browser.close(); process.exit(1); }

// ── Search ────────────────────────────────────────────────────────────────────
console.log("\n[5] Searching:", ADDRESS);
const searchInput = topFrame.locator('input.quick-launch__input, input[placeholder*="Address"]').first();
await searchInput.click({ force: true, noWaitAfter: true });
await searchInput.clear({ noWaitAfter: true }).catch(() => {});
await searchInput.pressSequentially(ADDRESS, { delay: 20, timeout: 60000 });

console.log("[6] Waiting for autocomplete...");
await topFrame.locator('li.result.selectable').first().waitFor({ state: 'visible', timeout: 4000 }).catch(() => {});
const acCount = await topFrame.locator('li.result.selectable').count().catch(() => 0);
if (acCount > 0) {
  await topFrame.locator('li.result.selectable').first().click({ force: true, noWaitAfter: true });
  console.log("Clicked first autocomplete result");
} else {
  await searchInput.press("Enter", { timeout: 3000 }).catch(() => {});
  console.log("Pressed Enter (no autocomplete)");
}

// ── Wait for listing detail ───────────────────────────────────────────────────
console.log("\n[7] Waiting 12s for listing detail...");
await new Promise(r => setTimeout(r, 12000));
logFrames("after listing load", page);

// ── Inspect view_frame for ShowingTime ───────────────────────────────────────
console.log("\n[8] Searching for ShowingTime elements across all frames...");
for (const frame of page.frames()) {
  const u = frame.url();
  if (!u || u === "about:blank" || u.startsWith("chrome-error://")) continue;

  const hits = await safeEval(frame, () => {
    const results = [];
    for (const el of document.querySelectorAll('*')) {
      const id   = (el.id ?? "").toLowerCase();
      const cls  = (el.className?.toString() ?? "").toLowerCase();
      const txt  = (el.innerText ?? "").trim().toLowerCase().slice(0, 80);
      const href = (el.href ?? "").toLowerCase();
      const oc   = (el.getAttribute("onclick") ?? "").toLowerCase();
      if (id.includes("showing") || cls.includes("showing") ||
          txt.includes("showingtime") || href.includes("showingtime") ||
          oc.includes("showingtime")) {
        results.push({
          tag: el.tagName, id: el.id || "",
          cls: (el.className?.toString() ?? "").slice(0, 60),
          text: (el.innerText ?? "").trim().slice(0, 60),
          href: (el.href ?? ""),
          onclick: (el.getAttribute("onclick") ?? "").slice(0, 80),
        });
      }
    }
    return results;
  }, undefined, 4000);

  if (Array.isArray(hits) && hits.length > 0) {
    console.log(`\nFrame [${frame.name() || "(no name)"}] ${u.slice(0, 80)}:`);
    hits.forEach(h =>
      console.log(`  [${h.tag}#${h.id || "?"}] "${h.text}" href="${h.href.slice(0,80)}" onclick="${h.onclick}"`)
    );
  }
}

// ── Click ShowingTime and capture final URL ───────────────────────────────────
const viewFrame = page.frames().find(f => f.name() === "view_frame");
if (viewFrame) {
  // Get the redirector href
  const stHref = await safeEval(viewFrame, () => {
    const a = document.querySelector('a[href*="showing_time"]');
    return a?.href ?? null;
  }, undefined, 4000);

  console.log("\n[9] ShowingTime redirector href:", stHref);

  if (stHref && typeof stHref === "string") {
    console.log("[10] Intercepting popup + clicking ShowingTime link...");
    const [popup] = await Promise.all([
      context.waitForEvent("page", { timeout: 15000 }).catch(() => null),
      safeEval(viewFrame, () => {
        document.querySelector('a[href*="showing_time"]')?.click();
      }, undefined, 3000),
    ]);

    // Poll until URL leaves flexmls.com (reached ShowingTime domain)
    async function waitForShowingTimeUrl(pg, timeoutMs = 20000) {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        const u = pg.url();
        if (u && !u.includes("flexmls.com") && !u.includes("about:blank") && !u.startsWith("chrome-error")) return u;
        await new Promise(r => setTimeout(r, 500));
      }
      return pg.url();
    }

    const stPage = popup ?? await context.newPage();
    if (!popup) {
      console.log("No popup — navigating directly...");
      await stPage.goto(stHref, { waitUntil: "domcontentloaded", timeout: 20000 }).catch(() => {});
    }

    const finalUrl = await waitForShowingTimeUrl(stPage, 20000);
    console.log("\n✅ ShowingTime landing URL:", finalUrl);

    // ── Dump page structure ─────────────────────────────────────────────────
    console.log("\n[11] Waiting 3s for ShowingTime page to fully load...");
    await new Promise(r => setTimeout(r, 3000));
    console.log("URL after wait:", stPage.url());

    console.log("\n[12] Full page text:");
    const pageText = await stPage.evaluate(() => document.body?.innerText ?? "").catch(() => "");
    console.log(pageText.slice(0, 3000));

    console.log("\n[13] All buttons and interactive elements:");
    const buttons = await stPage.evaluate(() => {
      return Array.from(document.querySelectorAll('button, a, [role="button"], input[type="submit"], input[type="button"]'))
        .map(el => ({
          tag: el.tagName,
          id: el.id || "",
          cls: (el.className?.toString() ?? "").slice(0, 60),
          text: (el.innerText ?? el.value ?? "").trim().slice(0, 80),
          href: (el.href ?? "").slice(0, 80),
          type: el.type || "",
        }))
        .filter(e => e.text || e.id);
    }).catch(() => []);
    buttons.forEach(b => console.log(`  [${b.tag}#${b.id}] type="${b.type}" text="${b.text}" cls="${b.cls}" href="${b.href}"`));

    console.log("\n[14] Listing Details section:");
    const listingDetails = await stPage.evaluate(() => {
      // Look for listing info section
      const selectors = [
        '[class*="listing"]', '[class*="property"]', '[class*="detail"]',
        '[id*="listing"]', '[id*="property"]',
      ];
      const results = [];
      for (const sel of selectors) {
        for (const el of document.querySelectorAll(sel)) {
          const text = el.innerText?.trim();
          if (text && text.length > 10 && text.length < 500) {
            results.push({ sel, text: text.slice(0, 200) });
          }
        }
      }
      return results.slice(0, 20);
    }).catch(() => []);
    listingDetails.forEach(d => console.log(`  [${d.sel}] ${d.text}`));

    // ── Try clicking "Schedule single showing" ────────────────────────────
    console.log("\n[15] Looking for 'Schedule' button...");
    const scheduleBtn = await stPage.evaluate(() => {
      const candidates = Array.from(document.querySelectorAll('button, a, [role="button"]'))
        .find(el => {
          const t = (el.innerText ?? "").toLowerCase();
          return t.includes("schedule") || t.includes("single showing") || t.includes("book");
        });
      if (!candidates) return null;
      return { tag: candidates.tagName, id: candidates.id, text: candidates.innerText?.trim(), cls: (candidates.className?.toString() ?? "").slice(0, 60) };
    }).catch(() => null);

    console.log("Schedule button found:", JSON.stringify(scheduleBtn));

    if (scheduleBtn) {
      console.log("\n[16] Clicking schedule button...");
      await stPage.evaluate(() => {
        const btn = Array.from(document.querySelectorAll('button, a, [role="button"]'))
          .find(el => {
            const t = (el.innerText ?? "").toLowerCase();
            return t.includes("schedule") || t.includes("single showing") || t.includes("book");
          });
        btn?.click();
      });

      console.log("Waiting 5s for calendar/availability page...");
      await new Promise(r => setTimeout(r, 5000));
      console.log("URL after click:", stPage.url());

      console.log("\n[17] Calendar/availability page text:");
      const calText = await stPage.evaluate(() => document.body?.innerText ?? "").catch(() => "");
      console.log(calText.slice(0, 3000));

      console.log("\n[18] Calendar table — first 4 data rows raw HTML:");
      const calHtml = await stPage.evaluate(() => {
        const table = document.querySelector('table.cal-table');
        if (!table) return "table.cal-table not found";
        const rows = Array.from(table.querySelectorAll('tr')).slice(2, 6);
        return rows.map(r => r.outerHTML.replace(/\s+/g, ' ').slice(0, 600)).join('\n---\n');
      }).catch(e => e.message);
      console.log(calHtml);

      console.log("\n[19] All unique TD class names in calendar:");
      const tdClasses = await stPage.evaluate(() => {
        const table = document.querySelector('table.cal-table');
        const classes = new Set();
        table?.querySelectorAll('td').forEach(td => { if (td.className) classes.add(td.className.toString().trim()); });
        return [...classes];
      }).catch(() => []);
      tdClasses.forEach(c => console.log(`  "${c}"`));

      console.log("\n[20] Slot cells (non-time-header) — first 20:");
      const slots = await stPage.evaluate(() => {
        const table = document.querySelector('table.cal-table');
        if (!table) return [];
        const results = [];
        table.querySelectorAll('tr').forEach(row => {
          const cells = Array.from(row.querySelectorAll('td'));
          const timeCell = cells.find(c => c.className.includes('time-header-cell') && !c.className.includes('minutes-only'));
          if (!timeCell) return;
          const timeText = timeCell.innerText.trim();
          cells.forEach((cell, idx) => {
            if (cell.className.includes('time-header-cell')) return;
            results.push({
              time: timeText, idx,
              cls: cell.className.toString(),
              hasLink: cell.innerHTML.includes('<a'),
              html: cell.innerHTML.replace(/\s+/g,' ').slice(0, 120),
            });
          });
        });
        return results.slice(0, 20);
      }).catch(() => []);
      slots.forEach(s => console.log(`  [${s.time} col${s.idx}] cls="${s.cls}" link=${s.hasLink} html="${s.html}"`));
    }

    await stPage.close().catch(() => {});
  } else {
    console.log("ShowingTime link not found in view_frame.");
  }
}

await browser.close();
console.log("\n[done]");
