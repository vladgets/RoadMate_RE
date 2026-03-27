/**
 * OpenStreetMap Nominatim reverse geocoding routes.
 * Free tier: https://nominatim.org/release-docs/latest/api/Reverse/
 * Usage policy: max 1 req/sec, must include contact in User-Agent.
 */

// Simple in-memory cache keyed by rounded coords (3 dp ≈ 111m resolution).
const _cache = new Map();
const CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes

// Rate limiter: track time of last Nominatim request.
let _lastRequestAt = 0;
const MIN_INTERVAL_MS = 1100; // slightly over 1 second to stay under rate limit

function _cacheKey(lat, lon) {
  return `${parseFloat(lat).toFixed(3)},${parseFloat(lon).toFixed(3)}`;
}

async function reverseGeocode(lat, lon) {
  const key = _cacheKey(lat, lon);
  const cached = _cache.get(key);
  if (cached && Date.now() - cached.ts < CACHE_TTL_MS) {
    return cached.data;
  }

  // Enforce rate limit: wait if last request was too recent.
  const wait = MIN_INTERVAL_MS - (Date.now() - _lastRequestAt);
  if (wait > 0) await new Promise(r => setTimeout(r, wait));
  _lastRequestAt = Date.now();

  const url = new URL("https://nominatim.openstreetmap.org/reverse");
  url.searchParams.set("lat", lat);
  url.searchParams.set("lon", lon);
  url.searchParams.set("format", "json");
  url.searchParams.set("zoom", "18");
  url.searchParams.set("addressdetails", "1");

  const response = await fetch(url, {
    headers: {
      // Nominatim policy requires app name + contact info in User-Agent.
      "User-Agent": "RoadMate/1.0 (https://roadmate-flutter.onrender.com)",
    },
  });

  if (!response.ok) {
    const body = await response.text();
    console.error("Nominatim API error:", response.status, body);
    throw new Error(`Nominatim ${response.status}`);
  }

  const data = await response.json();
  const address = data.display_name || "";

  let poiName = null;
  let poiType = null;
  if (data.name && data.type) {
    const genericTypes = [
      "road", "street", "residential", "suburb", "neighbourhood",
      "city", "town", "village", "hamlet", "county", "state",
      "postcode", "house",
    ];
    if (!genericTypes.includes(data.type)) {
      poiName = data.name;
      poiType = data.type;
    }
  }

  const result = { address, poi_name: poiName, poi_type: poiType };
  _cache.set(key, { ts: Date.now(), data: result });
  return result;
}

export function registerNominatimRoutes(app) {
  app.post("/nominatim/reverse", async (req, res) => {
    try {
      const { lat, lon } = req.body;
      if (!lat || !lon) {
        return res.status(400).json({ error: "lat and lon required" });
      }
      const result = await reverseGeocode(lat, lon);
      res.json(result);
    } catch (error) {
      console.error("Nominatim reverse error:", error);
      res.status(500).json({ error: "Internal server error" });
    }
  });
}
