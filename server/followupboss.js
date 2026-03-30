/**
 * Follow Up Boss CRM proxy routes.
 * Auth: API key via HTTP Basic Auth (key as username, blank password).
 * Docs: https://docs.followupboss.com/reference/common-filters
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
 * Fetch all FUB users and return a map of lowercase-name → { id, name }.
 * Cached in memory for 5 minutes.
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
  const map = {};
  for (const u of users) {
    if (u.name) map[u.name.toLowerCase()] = { id: u.id, name: u.name };
  }
  _usersCache = map;
  _usersCacheAt = Date.now();
  console.log(`[FUB] loaded ${users.length} users`);
  return map;
}

/**
 * Resolve a partial agent name to a FUB user ID.
 * Returns null if not found.
 */
async function resolveAgentId(agentQuery) {
  const users = await getFubUsers();
  const q = agentQuery.toLowerCase();
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
 *
 * Uses assignedUserId (correct FUB param) for agent filtering.
 * Uses dueDateFrom/dueDateTo for date filtering at the API level.
 * Falls back to no date filter for agent-specific queries (return all their tasks).
 */
async function fetchIncompleteTasks({ assignedUserId, dueDateFrom, dueDateTo } = {}) {
  const allTasks = [];
  let offset = 0;
  const limit = 100;

  while (true) {
    const params = new URLSearchParams({
      isCompleted: "false",
      limit: String(limit),
      offset: String(offset),
      sort: "dueDate",
      fields: "allFields",
    });
    if (assignedUserId) params.set("assignedUserId", String(assignedUserId));
    if (dueDateFrom) params.set("dueDateFrom", dueDateFrom);
    if (dueDateTo) params.set("dueDateTo", dueDateTo);

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
   * Returns list of FUB agents with their IDs and names.
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
   *
   * Query params:
   *   agent=NAME          filter by agent name (resolved to assignedUserId)
   *   dueDate=YYYY-MM-DD  exact due date filter
   *   all=true            skip date filter (return all incomplete tasks)
   *   days=N              tasks due within next N days (default: 30)
   */
  app.get("/fub/tasks", async (req, res) => {
    try {
      // Resolve agent name → assignedUserId
      let assignedUserId = null;
      if (req.query.agent) {
        assignedUserId = await resolveAgentId(req.query.agent);
        if (!assignedUserId) {
          return res.json({ ok: true, tasks: [], total: 0, warning: `No agent found matching "${req.query.agent}"` });
        }
        console.log(`[FUB] agent "${req.query.agent}" → assignedUserId ${assignedUserId}`);
      }

      let dueDateFrom, dueDateTo;

      if (req.query.dueDate) {
        // Exact date: set both from and to to the same date
        dueDateFrom = req.query.dueDate;
        dueDateTo = req.query.dueDate;
      } else if (!req.query.all && !assignedUserId) {
        // No agent filter: use date window to avoid fetching thousands of old tasks.
        // Overdue up to 90 days back + upcoming next N days.
        const days = parseInt(req.query.days || "30", 10);
        const from = new Date();
        from.setDate(from.getDate() - 90);
        dueDateFrom = from.toISOString().slice(0, 10);
        const to = new Date();
        to.setDate(to.getDate() + days);
        dueDateTo = to.toISOString().slice(0, 10);
      }
      // When agent is specified: no date filter — return all their incomplete tasks.

      const tasks = await fetchIncompleteTasks({ assignedUserId, dueDateFrom, dueDateTo });

      // Log first raw task to reveal actual field names
      if (tasks.length > 0) {
        console.log("[FUB] raw task sample:", JSON.stringify(tasks[0]));
      }

      const result = tasks.slice(0, 50).map(t => ({
        id: t.id,
        description: t.description || t.notes || t.type || "",
        dueDate: t.dueDate || null,
        isCompleted: t.isCompleted || false,
        contactName: t.person?.name || t.personName || null,
        assignedTo: t.assignedTo || t.assignedToName || null,
      }));

      console.log(`[FUB] tasks: ${tasks.length} fetched, returning ${result.length}`);

      res.json({ ok: true, tasks: result, total: result.length });
    } catch (e) {
      console.error("[FUB] tasks error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });
}
