/**
 * Feedback routes.
 * Stores user voice feedback to disk and serves an admin UI tab to browse them.
 *
 * Files stored as: {FEEDBACK_DIR}/{client_id}_{platform}_{timestamp}.json
 * Default dir: /data/feedback (override with FEEDBACK_DIR env var)
 */

import fs from "fs";
import path from "path";

const FEEDBACK_DIR = process.env.FEEDBACK_DIR || "/data/feedback";

function ensureDir() {
  if (!fs.existsSync(FEEDBACK_DIR)) fs.mkdirSync(FEEDBACK_DIR, { recursive: true });
}

async function getLocationFromIp(ip) {
  try {
    const cleanIp = ip.replace(/^::ffff:/, "");
    if (cleanIp === "127.0.0.1" || cleanIp === "::1") return null;
    const r = await fetch(`http://ip-api.com/json/${cleanIp}?fields=city,regionName,country,status`);
    const d = await r.json();
    if (d.status !== "success") return null;
    return [d.city, d.regionName, d.country].filter(Boolean).join(", ");
  } catch {
    return null;
  }
}

function safeTs(iso) {
  return iso.replace(/[:.]/g, "-").replace("T", "_").replace("Z", "").substring(0, 19);
}

function platformIcon(platform) {
  if (platform === "ios") return "🍎";
  if (platform === "android") return "🤖";
  if (platform === "web") return "🌐";
  return "💻";
}

function escapeHtml(str) {
  return String(str || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/\n/g, "<br>");
}

/** Shared tab navigation bar HTML. Pass optional rightHtml to render at the right end. */
function adminTabBar(active, rightHtml = "") {
  return `
<nav class="tab-bar">
  <a href="/admin/conversations" class="tab${active === "conversations" ? " active" : ""}">💬 Conversations</a>
  <a href="/admin/feedback" class="tab${active === "feedback" ? " active" : ""}">📣 Feedback</a>
  ${rightHtml ? `<div class="tab-bar-right">${rightHtml}</div>` : ""}
</nav>`;
}

/** Shared tab bar CSS */
const tabBarCss = `
  .tab-bar { display: flex; align-items: flex-end; gap: 4px; padding: 20px 32px 0; }
  .tab { padding: 8px 18px; border-radius: 8px 8px 0 0; font-size: 0.88rem; font-weight: 600; text-decoration: none; color: #6e6e73; background: #e5e5ea; border: 1px solid #e5e5ea; border-bottom: none; }
  .tab.active { background: #fff; color: #1d1d1f; border-color: #e5e5ea; }
  .tab:hover:not(.active) { background: #d1d1d6; }
  .tab-bar-right { margin-left: auto; padding-bottom: 4px; }
  .tab-content { background: #fff; border-top: 1px solid #e5e5ea; }
`;

export function registerFeedbackRoutes(app) {

  /**
   * POST /feedback
   * Flutter app calls this to submit voice feedback.
   * Body: { client_id, platform, text }
   */
  app.post("/feedback", async (req, res) => {
    try {
      ensureDir();
      const { client_id, platform, text } = req.body || {};
      if (!client_id || !text) {
        return res.status(400).json({ ok: false, error: "client_id and text required" });
      }

      const timestamp = new Date().toISOString();
      const fname = `${client_id}_${platform || "unknown"}_${safeTs(timestamp)}.json`;
      const fpath = path.join(FEEDBACK_DIR, fname);

      const ip = req.headers["x-forwarded-for"]?.split(",")[0]?.trim() || req.socket.remoteAddress;
      const location = await getLocationFromIp(ip);

      const data = {
        client_id,
        platform: platform || "unknown",
        location: location || null,
        timestamp,
        text,
      };

      fs.writeFileSync(fpath, JSON.stringify(data, null, 2), "utf8");
      console.log(`[Feedback] saved ${fname}`);
      res.json({ ok: true, filename: fname });
    } catch (e) {
      console.error("[Feedback] save error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * GET /admin/feedback
   * Lists all saved feedback entries, newest first.
   */
  app.get("/admin/feedback", (req, res) => {
    try {
      ensureDir();
      const files = fs.readdirSync(FEEDBACK_DIR)
        .filter(f => f.endsWith(".json"))
        .map(f => {
          try {
            const d = JSON.parse(fs.readFileSync(path.join(FEEDBACK_DIR, f), "utf8"));
            return {
              filename: f,
              client_id: d.client_id || "—",
              platform: d.platform || "unknown",
              location: d.location || null,
              timestamp: d.timestamp || null,
              text: d.text || "",
            };
          } catch {
            return { filename: f, error: true, client_id: "—", platform: "—", location: null, timestamp: null, text: "" };
          }
        })
        .sort((a, b) => (b.timestamp || "").localeCompare(a.timestamp || ""));

      const rows = files.map(f => `
        <tr>
          <td>${platformIcon(f.platform)} ${escapeHtml(f.platform)}</td>
          <td title="${escapeHtml(f.client_id)}">${escapeHtml(f.client_id.substring(0, 8))}…</td>
          <td>${escapeHtml(f.location || "—")}</td>
          <td><span class="ts" data-ts="${escapeHtml(f.timestamp || "")}">—</span></td>
          <td class="feedback-text">${escapeHtml(f.text)}</td>
          <td style="text-align:center">
            <button class="del-btn" onclick="deleteFeedback('${escapeHtml(f.filename)}')" title="Delete">🗑</button>
          </td>
        </tr>`).join("");

      res.send(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RoadMate — Feedback</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f5f5f7; color: #1d1d1f; }
  h1 { font-size: 1.6rem; font-weight: 700; padding: 24px 32px 0; }
  .subtitle { color: #6e6e73; font-size: 0.9rem; padding: 4px 32px 16px; }
  ${tabBarCss}
  .container { padding: 0 24px 40px; }
  table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 0 12px 12px 12px; overflow: hidden; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }
  thead { background: #f5f5f7; }
  th { padding: 12px 16px; text-align: left; font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: #6e6e73; border-bottom: 1px solid #e5e5ea; }
  td { padding: 12px 16px; font-size: 0.9rem; border-bottom: 1px solid #f2f2f7; vertical-align: top; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #f5f5f7; }
  .feedback-text { max-width: 480px; line-height: 1.5; }
  .empty { text-align: center; padding: 48px; color: #6e6e73; }
  .del-btn { background: none; border: none; cursor: pointer; font-size: 1rem; opacity: 0.4; padding: 4px 8px; border-radius: 6px; }
  .del-btn:hover { opacity: 1; background: #fee2e2; }
</style>
</head>
<body>
<h1>RoadMate</h1>
<p class="subtitle">${files.length} feedback entr${files.length !== 1 ? "ies" : "y"}</p>
${adminTabBar("feedback")}
<div class="container">
<table>
  <thead><tr>
    <th>Platform</th><th>Client ID</th><th>Location</th><th>Submitted</th><th>Feedback</th><th></th>
  </tr></thead>
  <tbody>${rows || '<tr><td colspan="6" class="empty">No feedback yet</td></tr>'}</tbody>
</table>
</div>
<script>
async function deleteFeedback(filename) {
  if (!confirm('Delete this feedback?')) return;
  const res = await fetch('/admin/feedback/' + encodeURIComponent(filename), { method: 'DELETE' });
  if (res.ok) location.reload();
  else alert('Delete failed');
}
document.querySelectorAll('.ts[data-ts]').forEach(el => {
  const ts = el.dataset.ts;
  if (!ts) return;
  try {
    el.textContent = new Date(ts).toLocaleString('en-US', {
      month: 'short', day: 'numeric', year: 'numeric',
      hour: '2-digit', minute: '2-digit',
    });
  } catch {}
});
</script>
</body>
</html>`);
    } catch (e) {
      res.status(500).send("<pre>Error: " + escapeHtml(String(e)) + "</pre>");
    }
  });

  /** DELETE /admin/feedback/:filename */
  app.delete("/admin/feedback/:filename", (req, res) => {
    try {
      const safeName = path.basename(req.params.filename);
      const fpath = path.join(FEEDBACK_DIR, safeName);
      if (!fs.existsSync(fpath)) return res.status(404).json({ ok: false, error: "Not found" });
      fs.unlinkSync(fpath);
      console.log(`[Feedback] deleted ${safeName}`);
      res.json({ ok: true });
    } catch (e) {
      res.status(500).json({ ok: false, error: String(e) });
    }
  });
}

/** Export tab bar helper for use in conversations.js */
export { adminTabBar, tabBarCss };
