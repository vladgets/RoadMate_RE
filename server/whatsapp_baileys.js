/**
 * WhatsApp auto-send via Baileys (unofficial WhatsApp Web API).
 *
 * Endpoints:
 *   GET  /whatsapp/status?client_id=xxx  — connection state + QR if pending
 *   POST /whatsapp/connect  { client_id } — initiate pairing
 *   POST /whatsapp/send     { client_id, phone, message } — send message
 *   POST /whatsapp/disconnect { client_id } — logout + delete credentials
 */

import QRCode from 'qrcode';
import pino from 'pino';
import path from 'path';
import { fileURLToPath } from 'url';
import fs from 'fs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SESSION_ROOT = process.env.WA_SESSION_DIR || path.join(__dirname, 'wa_sessions');

// In-memory state per client_id.
const sessions = new Map();

const silentLogger = pino({ level: 'silent' });

// Lazy-load Baileys so import errors surface cleanly at connect time.
let _baileys = null;
async function getBaileys() {
  if (_baileys) return _baileys;
  try {
    _baileys = await import('@whiskeysockets/baileys');
    return _baileys;
  } catch (e) {
    throw new Error(`Failed to load Baileys: ${e.message}`);
  }
}

function sessionDir(clientId) {
  const dir = path.join(SESSION_ROOT, clientId);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

/**
 * Create (or recreate) a Baileys socket for clientId.
 * When pairingPhone is set, the socket skips QR and calls requestPairingCode immediately.
 * Returns { state, pairingCode? } — pairingCode is set only when pairingPhone was given.
 */
async function createSession(clientId, { pairingPhone = null, clearAuth = false } = {}) {
  // Tear down any existing socket cleanly.
  // Mark it superseded FIRST so its connection.update handler won't schedule
  // another reconnect when socket.end() triggers a close event.
  const prev = sessions.get(clientId);
  if (prev) {
    prev.superseded = true;
    if (prev.socket) {
      try { prev.socket.end(undefined); } catch (_) {}
    }
  }

  if (clearAuth) {
    try { fs.rmSync(sessionDir(clientId), { recursive: true, force: true }); } catch (_) {}
  }

  const state = {
    socket: null,
    connected: false,
    connecting: true,   // explicit flag, not derived
    qrBase64: null,
    pairingCode: null,  // 8-char code alternative to QR
    phone: null,
    lastError: null,
    superseded: false,  // set to true when replaced by a newer session
  };
  sessions.set(clientId, state);

  // Timeout: if no QR/code/connection after 60s, surface an error.
  const timeoutHandle = setTimeout(() => {
    if (state.connecting && !state.connected && !state.qrBase64 && !state.pairingCode) {
      state.connecting = false;
      state.lastError = 'Timed out. Check Render logs and retry.';
      console.error(`[WhatsApp] Connection timeout for client ${clientId}`);
    }
  }, 60_000);

  let resolvedPairingCode = null;

  try {
    const baileys = await getBaileys();
    const makeWASocket = baileys.default ?? baileys.makeWASocket;
    const { useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion } = baileys;

    // Fetch the current WhatsApp Web version — required or the handshake hangs.
    const { version, isLatest } = await fetchLatestBaileysVersion();
    console.log(`[WhatsApp] Using WA version ${version.join('.')} (latest: ${isLatest})`);

    const dir = sessionDir(clientId);
    const { state: authState, saveCreds } = await useMultiFileAuthState(dir);

    const socket = makeWASocket({
      version,
      auth: authState,
      logger: silentLogger,
      printQRInTerminal: false,
      browser: ['', 'RoadMate', '1.0.0'],
    });

    state.socket = socket;

    socket.ev.on('creds.update', () => {
      const registered = socket.authState?.creds?.registered ?? false;
      console.log(`[WhatsApp] Client ${clientId}: creds.update (registered=${registered})`);
      saveCreds();
    });

    // Register connection.update BEFORE calling requestPairingCode so no events
    // are missed if they fire during the await.
    socket.ev.on('connection.update', async (update) => {
      // This session was replaced by a newer one — ignore all events to
      // prevent stale handlers from scheduling duplicate reconnects.
      if (state.superseded) return;

      const { connection, lastDisconnect, qr } = update;

      if (qr) {
        clearTimeout(timeoutHandle);
        try {
          const dataUrl = await QRCode.toDataURL(qr, { margin: 1, width: 300 });
          state.qrBase64 = dataUrl.split(',')[1];
        } catch (e) {
          console.error('[WhatsApp] QR generation failed:', e.message);
          state.qrBase64 = null;
        }
        state.connected = false;
        state.connecting = false;
        state.lastError = null;
      }

      if (connection === 'open') {
        clearTimeout(timeoutHandle);
        state.connected = true;
        state.connecting = false;
        state.qrBase64 = null;
        state.lastError = null;
        state.phone = socket.user?.id?.split(':')[0] ?? null;
        console.log(`[WhatsApp] Client ${clientId} connected as ${state.phone}`);
      }

      if (connection === 'close') {
        state.connected = false;
        state.qrBase64 = null;

        const statusCode = lastDisconnect?.error?.output?.statusCode
          ?? lastDisconnect?.error?.output?.status;
        const loggedOut = statusCode === DisconnectReason.loggedOut
          || statusCode === 401;

        // After the user enters the pairing code, WhatsApp closes the initial
        // unauthenticated socket. This shows up as 401 OR as code=undefined.
        // Either way, credentials should have been saved — reconnect without
        // clearing auth so Baileys picks them up.
        const isPairingClose = state.pairingCode != null
          && (loggedOut || statusCode === undefined);

        if (isPairingClose) {
          console.log(`[WhatsApp] Client ${clientId}: post-pairing close (code ${statusCode}) — reconnecting with saved creds.`);
          state.pairingCode = null; // prevent this branch looping
          state.connecting = true;
          setTimeout(() => createSessionCompat(clientId).catch((e) => {
            state.connecting = false;
            state.lastError = e.message;
          }), 1500);
        } else if (loggedOut) {
          console.log(`[WhatsApp] Client ${clientId} logged out.`);
          state.connecting = false;
          state.lastError = 'Logged out from WhatsApp. Please reconnect.';
          sessions.delete(clientId);
          try { fs.rmSync(sessionDir(clientId), { recursive: true, force: true }); } catch (_) {}
        } else {
          console.log(`[WhatsApp] Client ${clientId} disconnected (code ${statusCode}), reconnecting...`);
          state.connecting = true;
          setTimeout(() => createSessionCompat(clientId).catch((e) => {
            state.connecting = false;
            state.lastError = e.message;
          }), 3000);
        }
      }
    });

    // Request pairing code AFTER listeners are registered (so we don't miss events).
    if (pairingPhone) {
      // Wait for the noise-protocol handshake with WA to complete.
      // A fixed delay is more reliable than waiting for connection.update,
      // because the close event (rate-limit 401) would otherwise resolve the
      // promise immediately and we'd call requestPairingCode on a dead socket.
      await new Promise(r => setTimeout(r, 1500));

      console.log(`[WhatsApp] Requesting pairing code for ${clientId}, phone=${pairingPhone}, registered=${socket.authState.creds.registered}`);
      try {
        const raw = await socket.requestPairingCode(pairingPhone);
        console.log(`[WhatsApp] Raw pairing code for ${clientId}: "${raw}"`);
        resolvedPairingCode = (raw && raw.length === 8 && !raw.includes('-'))
          ? `${raw.slice(0, 4)}-${raw.slice(4)}`
          : (raw ?? null);
        state.pairingCode = resolvedPairingCode;
        clearTimeout(timeoutHandle);
        console.log(`[WhatsApp] Formatted pairing code for ${clientId}: ${resolvedPairingCode} at ${new Date().toISOString()}`);

        // If WhatsApp doesn't complete the handshake within 90s after the code
        // is shown, it's being silently rate-limited. Surface a clear error.
        setTimeout(() => {
          if (state.superseded || state.connected) return;
          if (state.pairingCode) { // still waiting — no creds.update arrived
            state.pairingCode = null;
            state.connecting = false;
            state.lastError = 'WhatsApp did not complete pairing. Too many recent attempts — wait 1–2 hours and try again.';
            console.error(`[WhatsApp] Client ${clientId}: pairing timeout — likely rate-limited by WhatsApp`);
          }
        }, 90_000);
      } catch (e) {
        console.error(`[WhatsApp] requestPairingCode failed for ${clientId}:`, e.message, e.stack);
        state.lastError = `Pairing code error: ${e.message}`;
        state.connecting = false;
      }
    }

  } catch (e) {
    clearTimeout(timeoutHandle);
    console.error(`[WhatsApp] createSession failed for ${clientId}:`, e.message);
    state.connecting = false;
    state.lastError = e.message;
  }

  return { state, pairingCode: resolvedPairingCode };
}

// Backwards-compat wrapper used by restoreSessions and /connect.
async function createSessionCompat(clientId, opts = {}) {
  const result = await createSession(clientId, opts);
  return result?.state ?? result; // old callers expected state object directly
}

/** On server startup, restore sessions that have saved credentials. */
async function restoreSessions() {
  if (!fs.existsSync(SESSION_ROOT)) return;
  const entries = fs.readdirSync(SESSION_ROOT, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    console.log(`[WhatsApp] Restoring session for client ${entry.name}...`);
    createSessionCompat(entry.name).catch(console.error);
  }
}

export function registerWhatsAppBaileysRoutes(app) {
  restoreSessions().catch(console.error);

  // ── GET /whatsapp/status?client_id=xxx ──────────────────────────────────
  app.get('/whatsapp/status', (req, res) => {
    const clientId = req.query.client_id;
    if (!clientId) return res.status(400).json({ ok: false, error: 'Missing client_id' });

    const s = sessions.get(clientId);
    if (!s) {
      return res.json({ ok: true, connected: false, connecting: false,
        qrBase64: null, phone: null, lastError: null });
    }

    return res.json({
      ok: true,
      connected: s.connected,
      connecting: s.connecting,
      qrBase64: s.qrBase64 ?? null,
      pairingCode: s.pairingCode ?? null,
      phone: s.phone ?? null,
      lastError: s.lastError ?? null,
    });
  });

  // ── POST /whatsapp/connect ───────────────────────────────────────────────
  app.post('/whatsapp/connect', async (req, res) => {
    const { client_id } = req.body ?? {};
    if (!client_id) return res.status(400).json({ ok: false, error: 'Missing client_id' });

    const existing = sessions.get(client_id);
    if (existing?.connected) {
      return res.json({ ok: true, already_connected: true, phone: existing.phone });
    }

    createSessionCompat(client_id).catch(console.error);
    return res.json({ ok: true, message: 'Connecting — poll /whatsapp/status for QR.' });
  });

  // ── POST /whatsapp/pairing-code ──────────────────────────────────────────
  // Start a FRESH session and request a pairing code immediately, before any
  // QR handshake can begin.  This is the correct flow for same-device linking.
  app.post('/whatsapp/pairing-code', async (req, res) => {
    const { client_id, phone } = req.body ?? {};
    if (!client_id || !phone) {
      return res.status(400).json({ ok: false, error: 'Missing client_id or phone' });
    }

    const digits = phone.replace(/[^0-9]/g, '');
    if (digits.length < 7) {
      return res.status(400).json({ ok: false, error: 'Invalid phone number' });
    }

    // If already connected, no need to pair.
    const existing = sessions.get(client_id);
    if (existing?.connected) {
      return res.json({ ok: true, already_connected: true, phone: existing.phone });
    }

    try {
      // Clear any stale session/auth so the socket starts fresh in pairing mode.
      const { state, pairingCode } = await createSession(client_id, {
        pairingPhone: digits,
        clearAuth: true,
      });

      if (!pairingCode) {
        const isRateLimit = state.lastError?.includes('Connection Closed');
        return res.status(isRateLimit ? 429 : 500).json({
          ok: false,
          error: isRateLimit
            ? 'WhatsApp has rate-limited this number due to too many attempts. Wait 1–2 hours then try again.'
            : (state.lastError ?? 'Failed to get pairing code'),
        });
      }

      return res.json({ ok: true, pairingCode });
    } catch (e) {
      console.error(`[WhatsApp] /pairing-code error:`, e.message);
      return res.status(500).json({ ok: false, error: e.message });
    }
  });

  // ── POST /whatsapp/send ──────────────────────────────────────────────────
  // Accepts optional image_base64 (base64-encoded image). If present,
  // sends an image with caption instead of a plain text message.
  app.post('/whatsapp/send', async (req, res) => {
    const { client_id, phone, message, image_base64 } = req.body ?? {};
    if (!client_id || !phone || !message) {
      return res.status(400).json({ ok: false, error: 'Missing client_id, phone, or message' });
    }

    const s = sessions.get(client_id);
    if (!s?.connected) {
      return res.status(400).json({ ok: false,
        error: 'WhatsApp not connected. Open RoadMate settings to pair.' });
    }

    try {
      const digits = phone.replace(/[^0-9]/g, '');
      const jid = `${digits}@s.whatsapp.net`;

      if (image_base64) {
        const imageBuffer = Buffer.from(image_base64, 'base64');
        await s.socket.sendMessage(jid, { image: imageBuffer, caption: message });
      } else {
        await s.socket.sendMessage(jid, { text: message });
      }
      console.log(`[WhatsApp] Sent to ${digits} for client ${client_id}`);
      return res.json({ ok: true, to: digits });
    } catch (e) {
      console.error(`[WhatsApp] Send error:`, e.message);
      return res.status(500).json({ ok: false, error: e.message });
    }
  });

  // ── POST /whatsapp/disconnect ────────────────────────────────────────────
  app.post('/whatsapp/disconnect', async (req, res) => {
    const { client_id } = req.body ?? {};
    if (!client_id) return res.status(400).json({ ok: false, error: 'Missing client_id' });

    const s = sessions.get(client_id);
    if (s?.socket) {
      try { await s.socket.logout(); } catch (_) {}
    }
    sessions.delete(client_id);
    try { fs.rmSync(sessionDir(client_id), { recursive: true, force: true }); } catch (_) {}

    console.log(`[WhatsApp] Client ${client_id} disconnected and cleared.`);
    return res.json({ ok: true });
  });
}
