import { chromium } from 'playwright';
import { ensureAuthenticated, searchAddress, waitForDetailFrame, openShowingTime } from './mls.js';

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  viewport: { width: 1280, height: 900 }
});
const page = await context.newPage();

console.log('[1] Authenticating...');
await ensureAuthenticated(page, context);

console.log('[2] Searching address...');
await searchAddress(page, '27 Regency Way, Manalapan, NJ 07726');

console.log('[3] Waiting for detail frame...');
await waitForDetailFrame(page, 15000);

// Debug: what does view_frame look like?
console.log('\n[DEBUG] Frames:');
page.frames().forEach(f => console.log(`  [${f.name()}] ${f.url().slice(0,100)}`));

const vf = page.frames().find(f => f.name() === 'view_frame');
if (vf) {
  console.log('\n[DEBUG] ShowingTime link in view_frame:');
  const href = await vf.evaluate(() => {
    const a = document.querySelector('a[href*="showing_time"]');
    return a ? { href: a.href, id: a.id, text: a.innerText } : null;
  }).catch(e => ({ error: e.message }));
  console.log(JSON.stringify(href));

  // Extra wait and retry if not found
  if (!href) {
    console.log('[DEBUG] Waiting 5s more...');
    await new Promise(r => setTimeout(r, 5000));
    const href2 = await vf.evaluate(() => {
      const a = document.querySelector('a[href*="showing_time"]');
      return a ? { href: a.href, id: a.id, text: a.innerText } : null;
    }).catch(e => ({ error: e.message }));
    console.log('[DEBUG] After wait:', JSON.stringify(href2));
  }
}

console.log('[4] Opening ShowingTime...');
const result = await openShowingTime(page, context);
console.log('\n=== RESULT ===');
console.log(JSON.stringify(result, null, 2));
await browser.close();
