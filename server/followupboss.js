/**
 * Follow Up Boss CRM proxy routes.
 * Auth: API key via HTTP Basic Auth (key as username, blank password).
 * Docs: https://docs.followupboss.com/
 */

const FUB_BASE = "https://api.followupboss.com/v1";

function fubHeaders() {
  const key = process.env.FUB_API_KEY;
  if (!key) throw new Error("FUB_API_KEY environment variable not set");
  const encoded = Buffer.from(`${key}:`).toString("base64");
  return {
    "Authorization": `Basic ${encoded}`,
    "Content-Type": "application/json",
    "Accept": "application/json",
  };
}

export function registerFollowUpBossRoutes(app) {
  /**
   * GET /fub/tasks
   * Returns tasks for the authenticated user, optionally filtered by date.
   * Query params: ?dueDate=YYYY-MM-DD (optional)
   */
  app.get("/fub/tasks", async (req, res) => {
    try {
      const params = new URLSearchParams();
      if (req.query.dueDate) params.set("dueDate", req.query.dueDate);
      params.set("limit", "20");
      params.set("sort", "dueDate");

      const url = `${FUB_BASE}/tasks?${params}`;
      const r = await fetch(url, { headers: fubHeaders() });
      const data = await r.json();

      if (!r.ok) {
        return res.status(r.status).json({ ok: false, error: data?.message || "FUB error" });
      }

      // Simplify the response for voice
      const tasks = (data.tasks || []).map(t => ({
        id: t.id,
        description: t.description || t.name || "",
        dueDate: t.dueDate || null,
        isCompleted: t.isCompleted || false,
        contactName: t.person?.name || null,
        assignedTo: t.assignedTo?.name || null,
      }));

      res.json({ ok: true, tasks, total: data.total || tasks.length });
    } catch (e) {
      res.status(500).json({ ok: false, error: String(e) });
    }
  });
}
