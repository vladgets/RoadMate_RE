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

/**
 * Fetch all pages of incomplete tasks from FUB (FUB API doesn't support
 * date-range filtering, so we fetch and filter server-side).
 */
async function fetchAllIncompleteTasks() {
  const allTasks = [];
  let offset = 0;
  const limit = 100;

  while (true) {
    const params = new URLSearchParams({
      isCompleted: "false",
      limit: String(limit),
      offset: String(offset),
      sort: "dueDate",
    });

    const r = await fetch(`${FUB_BASE}/tasks?${params}`, { headers: fubHeaders() });
    const data = await r.json();
    if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);

    const batch = data.tasks || [];
    allTasks.push(...batch);

    // Stop if we've fetched everything
    if (allTasks.length >= (data.total || 0) || batch.length < limit) break;
    offset += limit;
  }

  return allTasks;
}

export function registerFollowUpBossRoutes(app) {
  /**
   * GET /fub/tasks
   * Returns incomplete tasks in a relevant date window, filtered server-side.
   *
   * Query params:
   *   dueDate=YYYY-MM-DD  exact due date filter
   *   all=true            skip date filter (return all incomplete tasks)
   *   days=N              tasks due within next N days (default: 30)
   */
  app.get("/fub/tasks", async (req, res) => {
    try {
      const allTasks = await fetchAllIncompleteTasks();

      let tasks = allTasks;

      // Filter by assigned agent name (case-insensitive partial match)
      if (req.query.agent) {
        const agentQ = req.query.agent.toLowerCase();
        tasks = tasks.filter(t => t.assignedTo?.name?.toLowerCase().includes(agentQ));
      }

      if (req.query.dueDate) {
        // Exact date filter
        tasks = tasks.filter(t => t.dueDate?.startsWith(req.query.dueDate));
      } else if (!req.query.all) {
        // Default: overdue tasks from last 90 days + tasks due within next N days.
        // The 90-day lookback avoids surfacing ancient forgotten tasks while still
        // catching genuinely recent overdue items.
        const days = parseInt(req.query.days || "30", 10);
        const from = new Date();
        from.setDate(from.getDate() - 90);
        from.setHours(0, 0, 0, 0);
        const to = new Date();
        to.setDate(to.getDate() + days);
        to.setHours(23, 59, 59, 999);

        tasks = allTasks.filter(t => {
          if (!t.dueDate) return false;
          const due = new Date(t.dueDate);
          return due >= from && due <= to;
        });
      }

      const result = tasks.slice(0, 50).map(t => ({
        id: t.id,
        description: t.description || t.name || "",
        dueDate: t.dueDate || null,
        isCompleted: t.isCompleted || false,
        contactName: t.person?.name || null,
        assignedTo: t.assignedTo?.name || null,
      }));

      // Log sample of raw tasks for debugging
      if (allTasks.length > 0) {
        const sample = allTasks.slice(0, 3).map(t => ({ id: t.id, dueDate: t.dueDate, isCompleted: t.isCompleted, name: t.name || t.description }));
        console.log(`[FUB] sample tasks:`, JSON.stringify(sample));
      }
      console.log(`[FUB] tasks: ${allTasks.length} total incomplete, ${tasks.length} in window, returning ${result.length}`);

      res.json({ ok: true, tasks: result, total: result.length });
    } catch (e) {
      console.error("[FUB] tasks error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });
}
