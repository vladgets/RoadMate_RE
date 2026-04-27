import { WebSocketServer } from "ws";
import WebSocket from "ws";

const SYSTEM_PROMPT = `You are RoadMate, a smart and friendly voice assistant designed for drivers.
You answer questions, give directions, check the weather, search the web, and help with tasks — all hands-free.
Keep responses concise and natural for voice. Avoid long lists or markdown formatting.
If you don't know something, say so briefly and offer to help with something else.
Today's date: ${new Date().toDateString()}.`;

export function registerPhoneBridgeRoutes(app, httpServer) {
  // TwiML webhook — Twilio POSTs here when someone calls the number
  app.post("/call/incoming", (req, res) => {
    const host = req.headers.host;
    res.type("text/xml");
    res.send(`<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Say>Connecting you to RoadMate.</Say>
  <Connect>
    <Stream url="wss://${host}/call/stream" />
  </Connect>
</Response>`);
  });

  // WebSocket server that Twilio Media Streams connects to
  const wss = new WebSocketServer({ noServer: true });

  httpServer.on("upgrade", (request, socket, head) => {
    if (request.url === "/call/stream") {
      wss.handleUpgrade(request, socket, head, (ws) => {
        wss.emit("connection", ws, request);
      });
    }
  });

  wss.on("connection", (twilioWs) => {
    console.log("[phone] Twilio Media Stream connected");
    handleCall(twilioWs);
  });
}

async function handleCall(twilioWs) {
  const OPENAI_API_KEY = process.env.OPENAI_API_KEY;

  const openaiWs = new WebSocket(
    "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview-2024-12-17",
    {
      headers: {
        Authorization: `Bearer ${OPENAI_API_KEY}`,
        "OpenAI-Beta": "realtime=v1",
      },
    }
  );

  let streamSid = null;
  let openaiReady = false;
  const pendingAudio = [];

  openaiWs.on("open", () => {
    console.log("[phone] Connected to OpenAI Realtime");
    openaiReady = true;

    openaiWs.send(
      JSON.stringify({
        type: "session.update",
        session: {
          turn_detection: { type: "server_vad" },
          input_audio_format: "g711_ulaw",
          output_audio_format: "g711_ulaw",
          voice: "alloy",
          instructions: SYSTEM_PROMPT,
          modalities: ["text", "audio"],
        },
      })
    );

    // Flush any audio that arrived before OpenAI was ready
    for (const payload of pendingAudio) {
      openaiWs.send(
        JSON.stringify({ type: "input_audio_buffer.append", audio: payload })
      );
    }
    pendingAudio.length = 0;
  });

  // Twilio → OpenAI
  twilioWs.on("message", (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }

    if (msg.event === "start") {
      streamSid = msg.start.streamSid;
      console.log(`[phone] Stream started: ${streamSid}`);
    }

    if (msg.event === "media") {
      const payload = msg.media.payload; // base64 g711_ulaw
      if (openaiReady) {
        openaiWs.send(
          JSON.stringify({ type: "input_audio_buffer.append", audio: payload })
        );
      } else {
        pendingAudio.push(payload);
      }
    }

    if (msg.event === "stop") {
      console.log("[phone] Stream stopped");
      openaiWs.close();
    }
  });

  // OpenAI → Twilio
  openaiWs.on("message", (raw) => {
    let event;
    try {
      event = JSON.parse(raw);
    } catch {
      return;
    }

    if (event.type === "response.audio.delta" && event.delta && streamSid) {
      twilioWs.send(
        JSON.stringify({
          event: "media",
          streamSid,
          media: { payload: event.delta }, // base64 g711_ulaw back to Twilio
        })
      );
    }

    if (event.type === "error") {
      console.error("[phone] OpenAI error:", event.error);
    }
  });

  twilioWs.on("close", () => {
    console.log("[phone] Twilio disconnected");
    openaiWs.close();
  });

  openaiWs.on("close", () => {
    console.log("[phone] OpenAI disconnected");
    if (twilioWs.readyState === WebSocket.OPEN) twilioWs.close();
  });

  openaiWs.on("error", (err) => {
    console.error("[phone] OpenAI WS error:", err.message);
  });
}
