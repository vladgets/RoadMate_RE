import express from "express";
import { registerGmailRoutes } from "./gmail.js";
import { registerGoogleMapsRoutes } from "./google_maps.js";
import { registerYouTubeRoutes } from "./youtube.js";
import { registerCollageRoutes } from "./collage.js";
import { registerWhatsAppBaileysRoutes } from "./whatsapp_baileys.js";
import { registerNominatimRoutes } from "./nominatim.js";

const app = express();
app.use(express.json());

registerGmailRoutes(app);
registerGoogleMapsRoutes(app);
registerYouTubeRoutes(app);
registerCollageRoutes(app);
registerWhatsAppBaileysRoutes(app);
registerNominatimRoutes(app);

const OPENAI_API_KEY = process.env.OPENAI_API_KEY;

app.get("/token", async (req, res) => {
  const r = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      expires_after: { anchor: "created_at", seconds: 600 },
      session: {
        type: "realtime",
        model: "gpt-realtime-mini-2025-12-15",
        output_modalities: ["audio"],
        audio: {
          input: {
            turn_detection: { type: "server_vad" },
          },
          output: {
            voice: "marin",
          },
        },
      },
    }),
  });

  const data = await r.json();
  res.json(data); // contains { value: "ek_..." }
});

// web search endpoint (using OpenAI Responses API with web search tool)
app.post("/websearch", async (req, res) => {
  try {
    const { query, model } = req.body ?? {};
    if (!query || typeof query !== "string") {
      return res.status(400).json({ ok: false, error: "Missing required field: query" });
    }

    const r = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: model || "gpt-4.1-mini",
        input:
          "Search the web for accurate, up-to-date information for the query. " +
          "Return up to 3 results as short snippets (1-3 sentences each) suitable for voice. " +
          "Prefer authoritative sources. Query: " +
          query,
        tools: [{ type: "web_search" }],
      }),
    });

    const data = await r.json();

    if (!r.ok) {
      return res.status(r.status).json({ ok: false, error: data?.error?.message || "OpenAI error" });
    }

    // Extract the assistant's answer text.
    const output = Array.isArray(data?.output) ? data.output : [];
    let answer = "";

    for (const item of output) {
      if (item?.type !== "message") continue;
      if (item?.role && item.role !== "assistant") continue;

      const content = Array.isArray(item?.content) ? item.content : [];
      for (const c of content) {
        if (c?.type === "output_text" && typeof c?.text === "string") {
          answer += (answer ? "\n" : "") + c.text;
        }
      }
    }

    // answer = String(answer || "").trim();
    // Clean URLs from the answer text (citations are returned separately in `sources`)
    answer = String(answer || "")
      // remove markdown-style links: [text](url)
      .replace(/\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g, "$1")
      // remove raw URLs
      .replace(/https?:\/\/\S+/g, "")
      // normalize whitespace
      .replace(/\s{2,}/g, " ")
      .trim();

    // Extract citations (sources) from url_citation annotations.
    const sources = [];
    for (const item of output) {
      if (item?.type !== "message") continue;
      const content = Array.isArray(item?.content) ? item.content : [];
      for (const c of content) {
        if (c?.type !== "output_text") continue;
        const anns = Array.isArray(c?.annotations) ? c.annotations : [];
        for (const a of anns) {
          if (a?.type !== "url_citation") continue;
          const title = a?.title ?? "";
          const url = a?.url ?? "";
          if (title || url) sources.push({ title, url });
        }
      }
    }

    // Return a compact response for Flutter.
    return res.status(200).json({
      ok: true,
      query,
      answer,
      sources: sources,
    });

  } catch (e) {
    res.status(500).json({ ok: false, error: String(e) });
  }
});

// Chat completions endpoint (proxy for text chat)
app.post("/chat", async (req, res) => {
  try {
    const { messages, tools, model } = req.body ?? {};
    if (!messages || !Array.isArray(messages)) {
      return res.status(400).json({ error: "Missing required field: messages" });
    }

    const r = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: model || "gpt-4o-mini",
        messages: messages,
        tools: tools || [],
        temperature: 0.7,
      }),
    });

    const data = await r.json();

    if (!r.ok) {
      return res.status(r.status).json({ error: data?.error?.message || "OpenAI error" });
    }

    return res.status(200).json(data);

  } catch (e) {
    res.status(500).json({ error: String(e) });
  }
});


// AI content generation endpoint (for AI-generated reminder notifications)
app.post("/generate", async (req, res) => {
  try {
    const { prompt } = req.body ?? {};
    if (!prompt || typeof prompt !== "string") {
      return res.status(400).json({ ok: false, error: "Missing required field: prompt" });
    }

    const r = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        messages: [{ role: "user", content: prompt }],
        max_tokens: 150,
      }),
    });

    const data = await r.json();
    if (!r.ok) {
      return res.status(r.status).json({ ok: false, error: data?.error?.message || "OpenAI error" });
    }

    const content = data?.choices?.[0]?.message?.content ?? "";
    return res.status(200).json({ ok: true, content });
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e) });
  }
});

app.listen(3000, () => console.log("Token server on :3000"));
