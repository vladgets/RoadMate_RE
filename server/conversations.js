/**
 * Conversation logging routes.
 * Saves full chat transcripts to disk and serves an admin UI to browse them.
 *
 * Files stored as: {CONV_DIR}/{client_id}_{platform}_{session_start}.json
 * Default dir: /data/conversations (override with CONVERSATIONS_DIR env var)
 */

import fs from "fs";
import path from "path";

const CONV_DIR = process.env.CONVERSATIONS_DIR || "/data/conversations";

function ensureDir() {
  if (!fs.existsSync(CONV_DIR)) fs.mkdirSync(CONV_DIR, { recursive: true });
}

async function getLocationFromIp(ip) {
  try {
    // Strip IPv6 prefix if present (e.g. "::ffff:1.2.3.4" → "1.2.3.4")
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

function buildFilename(clientId, platform, sessionStart) {
  return `${clientId}_${platform}_${safeTs(sessionStart)}.json`;
}

function platformIcon(platform) {
  if (platform === "ios") return "🍎";
  if (platform === "android") return "🤖";
  if (platform === "web") return "🌐";
  return "💻";
}

function formatDate(iso) {
  if (!iso) return "—";
  try {
    return new Date(iso).toLocaleString("en-US", {
      month: "short", day: "numeric", year: "numeric",
      hour: "2-digit", minute: "2-digit",
    });
  } catch { return iso; }
}

function escapeHtml(str) {
  return String(str || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/\n/g, "<br>");
}

export function registerConversationRoutes(app) {

  /** GET /admin/debug — shows disk contents for troubleshooting */
  app.get("/admin/debug", (req, res) => {
    const dataExists = fs.existsSync("/data");
    const convExists = fs.existsSync(CONV_DIR);
    const files = convExists ? fs.readdirSync(CONV_DIR) : [];
    const dataContents = dataExists ? fs.readdirSync("/data") : [];
    res.json({ CONV_DIR, dataExists, convExists, dataContents, files });
  });

  /**
   * POST /conversation/save
   * Flutter app calls this to save/update the current session transcript.
   * Body: { client_id, platform, session_start, agent_name?, messages[] }
   */
  app.post("/conversation/save", async (req, res) => {
    try {
      ensureDir();
      const { client_id, platform, session_start, agent_name, messages } = req.body || {};
      if (!client_id || !session_start || !Array.isArray(messages)) {
        return res.status(400).json({ ok: false, error: "client_id, session_start, messages required" });
      }

      const fname = buildFilename(client_id, platform || "unknown", session_start);
      const fpath = path.join(CONV_DIR, fname);

      // Read existing location if file already exists (avoid re-fetching on every update)
      let location = null;
      if (fs.existsSync(fpath)) {
        try { location = JSON.parse(fs.readFileSync(fpath, "utf8")).location || null; } catch {}
      }
      if (!location) {
        const ip = req.headers["x-forwarded-for"]?.split(",")[0]?.trim() || req.socket.remoteAddress;
        location = await getLocationFromIp(ip);
      }

      const data = {
        client_id,
        platform: platform || "unknown",
        agent_name: agent_name || null,
        location: location || null,
        session_start,
        last_updated: new Date().toISOString(),
        message_count: messages.length,
        messages,
      };

      fs.writeFileSync(fpath, JSON.stringify(data, null, 2), "utf8");
      const written = fs.existsSync(fpath);
      console.log(`[Conv] saved ${fname} to ${fpath}, exists=${written}, messages=${messages.length}`);
      res.json({ ok: true, filename: fname, path: fpath, written });
    } catch (e) {
      console.error("[Conversations] save error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * GET /admin/conversations
   * Lists all saved conversation files, newest first.
   */
  app.get("/admin/conversations", (req, res) => {
    try {
      ensureDir();
      const files = fs.readdirSync(CONV_DIR)
        .filter(f => f.endsWith(".json"))
        .map(f => {
          try {
            const raw = fs.readFileSync(path.join(CONV_DIR, f), "utf8");
            const d = JSON.parse(raw);
            return {
              filename: f,
              client_id: d.client_id || "—",
              platform: d.platform || "unknown",
              agent_name: d.agent_name || "—",
              location: d.location || null,
              session_start: d.session_start || null,
              last_updated: d.last_updated || null,
              message_count: d.message_count || d.messages?.length || 0,
            };
          } catch {
            return { filename: f, error: true, client_id: "—", platform: "—", agent_name: "—", location: null, session_start: null, last_updated: null, message_count: 0 };
          }
        })
        .sort((a, b) => (b.last_updated || "").localeCompare(a.last_updated || ""));

      const rows = files.map(f => `
        <tr onclick="location.href='/admin/conversation/${encodeURIComponent(f.filename)}'" style="cursor:pointer">
          <td>${platformIcon(f.platform)} ${escapeHtml(f.platform)}</td>
          <td>${escapeHtml(f.agent_name)}</td>
          <td title="${escapeHtml(f.client_id)}">${escapeHtml(f.client_id.substring(0, 8))}…</td>
          <td>${escapeHtml(f.location || "—")}</td>
          <td><span class="ts" data-ts="${escapeHtml(f.session_start || "")}">—</span></td>
          <td><span class="ts" data-ts="${escapeHtml(f.last_updated || "")}">—</span></td>
          <td style="text-align:center">${f.message_count}</td>
          <td style="text-align:center">
            <button class="del-btn" onclick="event.stopPropagation(); deleteConv('${escapeHtml(f.filename)}')" title="Delete">🗑</button>
          </td>
        </tr>`).join("");

      res.send(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RoadMate — Conversations</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f5f5f7; color: #1d1d1f; }
  h1 { font-size: 1.6rem; font-weight: 700; padding: 24px 32px 0; }
  .subtitle { color: #6e6e73; font-size: 0.9rem; padding: 4px 32px 24px; }
  .container { padding: 0 24px 40px; }
  table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 12px; overflow: hidden; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }
  thead { background: #f5f5f7; }
  th { padding: 12px 16px; text-align: left; font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: #6e6e73; border-bottom: 1px solid #e5e5ea; }
  td { padding: 12px 16px; font-size: 0.9rem; border-bottom: 1px solid #f2f2f7; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #f5f5f7; }
  .empty { text-align: center; padding: 48px; color: #6e6e73; }
  .del-btn { background: none; border: none; cursor: pointer; font-size: 1rem; opacity: 0.4; padding: 4px 8px; border-radius: 6px; }
  .del-btn:hover { opacity: 1; background: #fee2e2; }
</style>
</head>
<body>
<h1>RoadMate Conversations</h1>
<p class="subtitle">${files.length} session${files.length !== 1 ? "s" : ""} — click any row to view transcript</p>
<div class="container">
<table>
  <thead><tr>
    <th>Platform</th><th>Agent</th><th>Client ID</th><th>Location</th>
    <th>Started</th><th>Last Active</th><th>Messages</th><th></th>
  </tr></thead>
  <tbody>${rows || '<tr><td colspan="8" class="empty">No conversations yet</td></tr>'}</tbody>
</table>
</div>
<script>
async function deleteConv(filename) {
  if (!confirm('Delete this conversation?')) return;
  const res = await fetch('/admin/conversation/' + encodeURIComponent(filename), { method: 'DELETE' });
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

  /**
   * GET /admin/conversation/:filename
   * Renders a single conversation as a chat UI.
   */
  app.get("/admin/conversation/:filename", (req, res) => {
    try {
      const safeName = path.basename(req.params.filename);
      const fpath = path.join(CONV_DIR, safeName);
      if (!fs.existsSync(fpath)) return res.status(404).send("Conversation not found.");

      const d = JSON.parse(fs.readFileSync(fpath, "utf8"));
      const messages = d.messages || [];

      const bubbleParts = [];
      for (const m of messages) {
        const isUser = m.role === "user";
        const typeLabel = m.type === "voice_transcript" ? "🎤" : m.type === "text_with_images" ? "📷" : "";
        const tsAttr = m.timestamp ? ` data-ts="${escapeHtml(m.timestamp)}"` : "";
        bubbleParts.push(`
        <div class="msg ${isUser ? "user" : "assistant"}"${tsAttr}>
          <div class="bubble">
            ${typeLabel ? `<span class="type-label">${typeLabel}</span>` : ""}
            ${escapeHtml(m.content)}
          </div>
          <div class="meta"></div>
        </div>`);
      }
      const bubbles = bubbleParts.join("");

      res.send(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Conversation — ${escapeHtml(d.agent_name || d.client_id)}</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f5f5f7; color: #1d1d1f; display: flex; flex-direction: column; height: 100vh; }
  .header { background: #fff; border-bottom: 1px solid #e5e5ea; padding: 16px 20px; display: flex; align-items: center; gap: 16px; position: sticky; top: 0; z-index: 10; }
  .back { color: #007aff; text-decoration: none; font-size: 0.9rem; }
  .back:hover { text-decoration: underline; }
  .header-info h2 { font-size: 1rem; font-weight: 600; }
  .header-info p { font-size: 0.8rem; color: #6e6e73; margin-top: 2px; }
  .chat { flex: 1; overflow-y: auto; padding: 20px 16px; display: flex; flex-direction: column; gap: 8px; }
  .msg { display: flex; flex-direction: column; max-width: 72%; }
  .msg.user { align-self: flex-end; align-items: flex-end; }
  .msg.assistant { align-self: flex-start; align-items: flex-start; }
  .bubble { padding: 10px 14px; border-radius: 18px; font-size: 0.92rem; line-height: 1.45; word-break: break-word; }
  .msg.user .bubble { background: #007aff; color: #fff; border-bottom-right-radius: 4px; }
  .msg.assistant .bubble { background: #fff; color: #1d1d1f; border-bottom-left-radius: 4px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }
  .meta { font-size: 0.7rem; color: #6e6e73; margin-top: 3px; padding: 0 4px; }
  .type-label { font-size: 0.75rem; opacity: 0.7; margin-right: 4px; }
  .empty { text-align: center; color: #6e6e73; padding: 48px; }
  .day-sep { display: flex; align-items: center; justify-content: center; padding: 16px 0 8px; align-self: stretch; }
  .day-sep span { background: #e5e5ea; color: #6e6e73; font-size: 0.72rem; font-weight: 600; padding: 4px 12px; border-radius: 12px; letter-spacing: 0.03em; }
</style>
</head>
<body>
<div class="header">
  <a class="back" href="/admin/conversations">← All Conversations</a>
  <div class="header-info">
    <h2>${platformIcon(d.platform)} ${escapeHtml(d.agent_name || "Unknown agent")} &nbsp;·&nbsp; ${escapeHtml(d.platform)}</h2>
    <p><span class="ts" data-ts="${escapeHtml(d.session_start || "")}">—</span> &nbsp;·&nbsp; ${messages.length} message${messages.length !== 1 ? "s" : ""}${d.location ? " &nbsp;·&nbsp; 📍 " + escapeHtml(d.location) : ""} &nbsp;·&nbsp; Client: ${escapeHtml(d.client_id)}</p>
  </div>
</div>
<div class="chat">
  ${bubbles || '<div class="empty">No messages</div>'}
</div>
<script>
(function () {
  var fmtTime = function(ts) {
    return new Date(ts).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
  };
  var fmtDay = function(ts) {
    return new Date(ts).toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
  };
  var dayKey = function(ts) { return new Date(ts).toDateString(); };

  // Format header session start
  document.querySelectorAll('.ts[data-ts]').forEach(function(el) {
    var ts = el.dataset.ts;
    if (!ts) return;
    try {
      el.textContent = new Date(ts).toLocaleString('en-US', {
        month: 'short', day: 'numeric', year: 'numeric',
        hour: '2-digit', minute: '2-digit',
      });
    } catch {}
  });

  // Format message times and insert day separators
  var msgs = document.querySelectorAll('.msg[data-ts]');
  var lastDay = null;
  msgs.forEach(function(msg) {
    var ts = msg.dataset.ts;
    msg.querySelector('.meta').textContent = fmtTime(ts);
    var dk = dayKey(ts);
    if (dk !== lastDay) {
      var sep = document.createElement('div');
      sep.className = 'day-sep';
      sep.innerHTML = '<span>' + fmtDay(ts) + '</span>';
      msg.parentNode.insertBefore(sep, msg);
      lastDay = dk;
    }
  });
})();
</script>
</body>
</html>`);
    } catch (e) {
      res.status(500).send("<pre>Error: " + escapeHtml(String(e)) + "</pre>");
    }
  });

  /** DELETE /admin/conversation/:filename */
  app.delete("/admin/conversation/:filename", (req, res) => {
    try {
      const safeName = path.basename(req.params.filename);
      const fpath = path.join(CONV_DIR, safeName);
      if (!fs.existsSync(fpath)) return res.status(404).json({ ok: false, error: "Not found" });
      fs.unlinkSync(fpath);
      console.log(`[Conv] deleted ${safeName}`);
      res.json({ ok: true });
    } catch (e) {
      res.status(500).json({ ok: false, error: String(e) });
    }
  });
}
