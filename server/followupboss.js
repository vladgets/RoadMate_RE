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
 * Fetch all FUB users and return a map of lowercase-name → userId.
 * Cached in memory for 5 minutes to avoid repeated API calls.
 */
let _usersCache = null;
let _usersCacheAt = 0;

async function getFubUsers() {
  if (_usersCache && Date.now() - _usersCacheAt < 5 * 60 * 1000) {
    return _usersCache;
  }
  const r = await fetch(`${FUB_BASE}/users?limit=200`, { headers: fubHeaders() });
  const data = await r.json();
  if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);

  const users = data.users || [];
  const map = {}; // name (lowercase) → { id, name }
  for (const u of users) {
    if (u.name) map[u.name.toLowerCase()] = { id: u.id, name: u.name };
  }
  _usersCache = map;
  _usersCacheAt = Date.now();
  console.log(`[FUB] loaded ${users.length} users`);
  return map;
}

/**
 * Resolve a partial agent name string to a FUB userId.
 * Returns null if not found.
 */
async function resolveAgentId(agentQuery) {
  const users = await getFubUsers();
  const q = agentQuery.toLowerCase();
  // Exact match first, then partial
  for (const [name, u] of Object.entries(users)) {
    if (name === q) return u.id;
  }
  for (const [name, u] of Object.entries(users)) {
    if (name.includes(q)) return u.id;
  }
  return null;
}

/**
 * Fetch all pages of incomplete tasks from FUB.
 * If userId is provided, FUB filters server-side (efficient).
 * Date filtering is done server-side since FUB API doesn't support it.
 */
async function fetchAllIncompleteTasks({ userId } = {}) {
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
    if (userId) params.set("userId", String(userId));

    const r = await fetch(`${FUB_BASE}/tasks?${params}`, { headers: fubHeaders() });
    const data = await r.json();
    if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);

    const batch = data.tasks || [];
    allTasks.push(...batch);

    if (allTasks.length >= (data.total || 0) || batch.length < limit) break;
    offset += limit;
  }

  return allTasks;
}

export function registerFollowUpBossRoutes(app) {
  /**
   * GET /fub/users
   * Returns list of FUB users (agents) with their IDs and names.
   */
  app.get("/fub/users", async (req, res) => {
    try {
      const users = await getFubUsers();
      res.json({ ok: true, users: Object.values(users) });
    } catch (e) {
      console.error("[FUB] users error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * GET /fub/tasks
   * Returns incomplete tasks in a relevant date window.
   *
   * Query params:
   *   agent=NAME          filter by agent name (resolved to userId for efficient API filtering)
   *   dueDate=YYYY-MM-DD  exact due date filter
   *   all=true            skip date filter
   *   days=N              tasks due within next N days (default: 30)
   */
  app.get("/fub/tasks", async (req, res) => {
    try {
      // Resolve agent name → userId for efficient server-side filtering
      let userId = null;
      if (req.query.agent) {
        userId = await resolveAgentId(req.query.agent);
        if (!userId) {
          return res.json({ ok: true, tasks: [], total: 0, warning: `No agent found matching "${req.query.agent}"` });
        }
        console.log(`[FUB] filtering by agent "${req.query.agent}" → userId ${userId}`);
      }

      const allTasks = await fetchAllIncompleteTasks({ userId });
      let tasks = allTasks;

      if (req.query.dueDate) {
        tasks = tasks.filter(t => t.dueDate?.startsWith(req.query.dueDate));
      } else if (!req.query.all) {
        // Overdue tasks from last 90 days + upcoming tasks within next N days
        const days = parseInt(req.query.days || "30", 10);
        const from = new Date();
        from.setDate(from.getDate() - 90);
        from.setHours(0, 0, 0, 0);
        const to = new Date();
        to.setDate(to.getDate() + days);
        to.setHours(23, 59, 59, 999);

        tasks = tasks.filter(t => {
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

      console.log(`[FUB] tasks: ${allTasks.length} fetched, ${tasks.length} in window, returning ${result.length}`);

      res.json({ ok: true, tasks: result, total: result.length });
    } catch (e) {
      console.error("[FUB] tasks error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });
}
