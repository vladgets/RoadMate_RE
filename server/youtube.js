import fs from "fs";
import { google } from "googleapis";

const SCOPES = ["https://www.googleapis.com/auth/youtube.readonly"];
const TOKEN_DIR = process.env.YOUTUBE_TOKEN_DIR || "/data/youtube_tokens";

const GOOGLE_CLIENT_ID = process.env.GOOGLE_CLIENT_ID;
const GOOGLE_CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET;
const BASE_URL = process.env.BASE_URL;
const REDIRECT_URI = BASE_URL ? `${BASE_URL}/oauth/youtube/callback` : null;

function ensureTokenDir() {
  if (!fs.existsSync(TOKEN_DIR)) {
    fs.mkdirSync(TOKEN_DIR, { recursive: true });
  }
}

function sanitizeClientId(v) {
  if (typeof v !== "string") return null;
  const cid = v.trim();
  if (!cid) return null;
  if (!/^[a-zA-Z0-9_-]{4,80}$/.test(cid)) return null;
  return cid;
}

function getClientIdFromReq(req) {
  return (
    sanitizeClientId(req.get("X-Client-Id")) ||
    sanitizeClientId(req.query.client_id) ||
    sanitizeClientId(req.body?.client_id)
  );
}

function tokenPathFor(clientId) {
  ensureTokenDir();
  return `${TOKEN_DIR}/${clientId}.json`;
}

function assertConfig() {
  const missing = [];
  if (!GOOGLE_CLIENT_ID) missing.push("GOOGLE_CLIENT_ID");
  if (!GOOGLE_CLIENT_SECRET) missing.push("GOOGLE_CLIENT_SECRET");
  if (!BASE_URL) missing.push("BASE_URL");
  if (missing.length) {
    throw new Error(`Missing env vars: ${missing.join(", ")}`);
  }
}

function makeOAuth2Client() {
  assertConfig();
  return new google.auth.OAuth2(GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, REDIRECT_URI);
}

function saveToken(clientId, token) {
  if (!clientId) throw new Error("saveToken: missing clientId");
  if (!token || typeof token !== "object") throw new Error(`saveToken: missing token for client_id=${clientId}`);
  const p = tokenPathFor(clientId);
  fs.writeFileSync(p, JSON.stringify(token, null, 2), "utf-8");
}

function loadToken(clientId) {
  const p = tokenPathFor(clientId);
  if (!fs.existsSync(p)) return null;
  const raw = fs.readFileSync(p, "utf-8");
  return JSON.parse(raw);
}

async function getAuthorizedClient(clientId) {
  const oauth2 = makeOAuth2Client();
  const token = loadToken(clientId);
  if (!token) {
    throw new Error(`Not authorized for client_id=${clientId}. Visit /oauth/youtube/start?client_id=${clientId} first.`);
  }
  oauth2.setCredentials(token);
  await oauth2.getAccessToken();
  const updated = oauth2.credentials;
  if (updated && Object.keys(updated).length > 0) {
    saveToken(clientId, updated);
  }
  return oauth2;
}

const MAX_CHANNELS = 20;
const MAX_VIDEOS_PER_CHANNEL = 50;
const DAYS_AGO = 30;

function publishedAfterDate() {
  const d = new Date();
  d.setDate(d.getDate() - DAYS_AGO);
  return d.toISOString();
}

export function registerYouTubeRoutes(app) {
  app.get("/oauth/youtube/start", (req, res) => {
    try {
      const oauth2 = makeOAuth2Client();
      const clientId = getClientIdFromReq(req);
      if (!clientId) {
        return res.status(400).json({
          ok: false,
          error: "Missing or invalid client_id. Provide ?client_id=XXXX (4-80 chars: letters/digits/_/-) or header X-Client-Id.",
        });
      }
      const authUrl = oauth2.generateAuthUrl({
        access_type: "offline",
        scope: SCOPES,
        include_granted_scopes: true,
        prompt: "consent",
        state: clientId,
      });
      return res.redirect(authUrl);
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });

  app.get("/oauth/youtube/callback", async (req, res) => {
    try {
      const code = req.query.code;
      if (!code || typeof code !== "string") {
        return res.status(400).json({ ok: false, error: "Missing code" });
      }
      const state = req.query.state;
      const clientId = sanitizeClientId(typeof state === "string" ? state : "");
      if (!clientId) {
        return res.status(400).json({ ok: false, error: "Missing or invalid state (client_id)." });
      }
      const oauth2 = makeOAuth2Client();
      const { tokens } = await oauth2.getToken(code);
      oauth2.setCredentials(tokens);
      saveToken(clientId, tokens);
      return res.json({ ok: true, client_id: clientId, message: "YouTube authorized. You can close this tab." });
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });

  app.get("/youtube/subscriptions_feed", async (req, res) => {
    try {
      const clientId = getClientIdFromReq(req);
      if (!clientId) {
        return res.status(400).json({
          ok: false,
          error: "Missing or invalid client_id. Provide header X-Client-Id or ?client_id=...",
        });
      }

      const auth = await getAuthorizedClient(clientId);
      const youtube = google.youtube({ version: "v3", auth });

      const cutoff = publishedAfterDate();

      const subsRes = await youtube.subscriptions.list({
        part: "snippet",
        mine: true,
        maxResults: 50,
      });

      const items = subsRes.data.items || [];
      const channelIds = items
        .map((s) => s.snippet?.resourceId?.channelId)
        .filter(Boolean)
        .slice(0, MAX_CHANNELS);

      if (channelIds.length === 0) {
        return res.json({ ok: true, videos: [] });
      }

      const channelsRes = await youtube.channels.list({
        part: "contentDetails",
        id: channelIds.join(","),
      });

      const uploadsPlaylists = (channelsRes.data.items || [])
        .map((c) => c.contentDetails?.relatedPlaylists?.uploads)
        .filter(Boolean);

      const allVideos = [];

      for (const playlistId of uploadsPlaylists) {
        let pageToken = null;
        let fetched = 0;

        do {
          const plRes = await youtube.playlistItems.list({
            part: "snippet",
            playlistId,
            maxResults: Math.min(50, MAX_VIDEOS_PER_CHANNEL - fetched),
            pageToken: pageToken || undefined,
          });

          const plItems = plRes.data.items || [];
          for (const item of plItems) {
            const publishedAt = item.snippet?.publishedAt;
            const videoId = item.snippet?.resourceId?.videoId;
            const title = item.snippet?.title || "";

            if (!videoId || !publishedAt) continue;
            if (publishedAt < cutoff) continue;

            allVideos.push({
              videoId,
              title,
              url: `https://www.youtube.com/watch?v=${videoId}`,
              publishedAt,
            });
          }

          fetched += plItems.length;
          pageToken = plRes.data.nextPageToken || null;

          if (plItems.some((i) => (i.snippet?.publishedAt || "") < cutoff)) break;
        } while (pageToken && fetched < MAX_VIDEOS_PER_CHANNEL);
      }

      allVideos.sort((a, b) => (b.publishedAt > a.publishedAt ? 1 : -1));

      return res.json({ ok: true, videos: allVideos });
    } catch (e) {
      return res.status(500).json({ ok: false, error: String(e) });
    }
  });
}
