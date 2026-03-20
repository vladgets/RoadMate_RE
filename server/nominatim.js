/**
 * OpenStreetMap Nominatim reverse geocoding routes.
 * Free tier: https://nominatim.org/release-docs/latest/api/Reverse/
 */

export function registerNominatimRoutes(app) {
  /**
   * POST /nominatim/reverse
   *
   * Reverse geocode lat/lon to get address + POI name.
   *
   * Request body:
   *   { lat: number, lon: number }
   *
   * Response:
   *   {
   *     address: string,       // formatted address
   *     poi_name: string|null, // POI name if found (e.g. "Starbucks")
   *     poi_type: string|null  // POI type if found (e.g. "cafe")
   *   }
   */
  app.post("/nominatim/reverse", async (req, res) => {
    try {
      const { lat, lon } = req.body;
      if (!lat || !lon) {
        return res.status(400).json({ error: "lat and lon required" });
      }

      // Call Nominatim API with zoom=18 for detailed results
      const url = new URL("https://nominatim.openstreetmap.org/reverse");
      url.searchParams.set("lat", lat);
      url.searchParams.set("lon", lon);
      url.searchParams.set("format", "json");
      url.searchParams.set("zoom", "18"); // detailed level to get POI
      url.searchParams.set("addressdetails", "1");

      const response = await fetch(url, {
        headers: {
          "User-Agent": "RoadMate/1.0", // Required by Nominatim usage policy
        },
      });

      if (!response.ok) {
        console.error("Nominatim API error:", response.status, await response.text());
        return res.status(500).json({ error: "Nominatim API request failed" });
      }

      const data = await response.json();

      // Extract formatted address
      const address = data.display_name || "";

      // Extract POI name if it's a specific place (not just a street address)
      // Nominatim returns 'name' for named places like businesses
      let poiName = null;
      let poiType = null;

      if (data.name && data.type) {
        // Exclude generic types like "road", "residential", "suburb"
        const genericTypes = [
          "road", "street", "residential", "suburb", "neighbourhood",
          "city", "town", "village", "hamlet", "county", "state",
          "postcode", "house"
        ];
        if (!genericTypes.includes(data.type)) {
          poiName = data.name;
          poiType = data.type; // e.g., "cafe", "restaurant", "shop", "hospital"
        }
      }

      res.json({
        address,
        poi_name: poiName,
        poi_type: poiType,
      });
    } catch (error) {
      console.error("Nominatim reverse error:", error);
      res.status(500).json({ error: "Internal server error" });
    }
  });
}
