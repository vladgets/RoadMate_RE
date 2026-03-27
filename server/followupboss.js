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
   * Returns incomplete tasks, optionally filtered by due date.
   *
   * Query params:
   *   dueDate=YYYY-MM-DD  - exact due date (default: from 7 days ago to +30 days)
   *   all=true            - skip date window, return all incomplete tasks
   */
  app.get("/fub/tasks", async (req, res) => {
    try {
      const params = new URLSearchParams();
      params.set("isCompleted", "false");  // only incomplete tasks
      params.set("limit", "25");
      params.set("sort", "dueDate");

      if (req.query.dueDate) {
        params.set("dueDate", req.query.dueDate);
      } else if (!req.query.all) {
        // Default window: 7 days ago → 30 days from now
        const from = new Date();
        from.setDate(from.getDate() - 7);
        const to = new Date();
        to.setDate(to.getDate() + 30);
        params.set("dueDateFrom", from.toISOString().slice(0, 10));
        params.set("dueDateTo", to.toISOString().slice(0, 10));
      }

      const url = `${FUB_BASE}/tasks?${params}`;
      const r = await fetch(url, { headers: fubHeaders() });
      const data = await r.json();

      if (!r.ok) {
        return res.status(r.status).json({ ok: false, error: data?.message || "FUB error" });
      }

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
