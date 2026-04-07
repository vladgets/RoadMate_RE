/**
 * Follow Up Boss CRM proxy routes.
 * Auth: API key via HTTP Basic Auth (key as username, blank password).
 * Docs: https://docs.followupboss.com/reference/common-filters
 *
 * NOTE: FUB API ignores dueDateFrom/dueDateTo and isCompleted filters silently.
 * All date filtering and completion filtering is done server-side.
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
 * Fetch the authenticated user's profile from FUB (/me).
 * Cached in memory for 5 minutes.
 */
let _meCache = null;
let _meCacheAt = 0;

async function getFubMe() {
  if (_meCache && Date.now() - _meCacheAt < 5 * 60 * 1000) return _meCache;
  const r = await fetch(`${FUB_BASE}/me`, { headers: fubHeaders() });
  const data = await r.json();
  if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);
  _meCache = data;
  _meCacheAt = Date.now();
  return data;
}

/**
 * Resolve agent identity from a request.
 * Prefers agent_id (direct, unambiguous) over agent name resolution.
 * Works for both GET (query params) and POST (body) requests.
 * Returns null if agent=all or no identity provided.
 */
async function resolveAgentFromRequest(req) {
  // Check query params first, then body
  const agentId = req.query.agent_id ?? req.body?.agent_id;
  const agentName = req.query.agent ?? req.body?.agent;

  if (agentId) {
    const id = Number(agentId);
    if (!isNaN(id)) {
      console.log(`[FUB] agent resolved via ID: ${id}`);
      return id;
    }
  }

  if (!agentName || agentName === "all") return null;

  const id = await resolveAgentId(agentName);
  if (id) console.log(`[FUB] agent "${agentName}" resolved to ID: ${id}`);
  return id;
}

/**
 * Resolve a partial agent name to a FUB user ID.
 * Supports the special value "me" to resolve to the API key owner.
 * Returns null if not found.
 */
async function resolveAgentId(agentQuery) {
  if (agentQuery.toLowerCase() === "me") {
    const me = await getFubMe();
    return me.id;
  }
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
 * assignedUserId is the only API-level filter that actually works.
 * Everything else is filtered server-side.
 */
async function fetchIncompleteTasks({ assignedUserId } = {}) {
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
    if (assignedUserId) params.set("assignedUserId", String(assignedUserId));

    const r = await fetch(`${FUB_BASE}/tasks?${params}`, { headers: fubHeaders() });
    const data = await r.json();
    if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);

    const batch = data.tasks || [];
    // Filter completed tasks server-side (API ignores isCompleted param)
    allTasks.push(...batch.filter(t => !t.isCompleted));

    if (allTasks.length >= (data.total || 0) || batch.length < limit) break;
    offset += limit;
  }

  return allTasks;
}

export function registerFollowUpBossRoutes(app) {
  /**
   * GET /fub/person/:id
   * Fetch a single FUB contact by ID directly.
   */
  app.get("/fub/person/:id", async (req, res) => {
    try {
      const r = await fetch(`${FUB_BASE}/people/${req.params.id}`, { headers: fubHeaders() });
      const data = await r.json();
      if (!r.ok) return res.status(r.status).json({ ok: false, error: data?.message || `FUB error ${r.status}` });
      res.json({ ok: true, person: data });
    } catch (e) {
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * GET /fub/me
   * Returns the authenticated user's profile.
   */
  app.get("/fub/me", async (req, res) => {
    try {
      const me = await getFubMe();
      res.json({ ok: true, user: { id: me.id, name: me.name, email: me.email } });
    } catch (e) {
      console.error("[FUB] me error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * GET /fub/users
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
   *   all=true            skip date filter
   *   days=N              upcoming window in days (default: 30)
   *   overdueDays=N       overdue lookback in days (default: 90)
   */
  app.get("/fub/tasks", async (req, res) => {
    try {
      // Resolve agent name → assignedUserId.
      // Default to current agent when no identity provided.
      const assignedUserId = req.query.agent === "all"
        ? null
        : (await resolveAgentFromRequest(req) ?? await resolveAgentId("me"));
      if (!assignedUserId && req.query.agent !== "all") {
        return res.json({ ok: true, tasks: [], total: 0, warning: "Could not resolve agent identity" });
      }

      const allTasks = await fetchIncompleteTasks({ assignedUserId });

      // Server-side date filtering
      let tasks = allTasks;
      if (req.query.dueDate) {
        tasks = allTasks.filter(t => t.dueDate?.startsWith(req.query.dueDate));
      } else if (!req.query.all) {
        // Include all overdue tasks (no lower bound) + upcoming within N days.
        // Proximity sort below ensures most recent overdue + soonest upcoming appear first,
        // pushing ancient tasks to the bottom where they're cut by the 50-task cap.
        const futureDays = parseInt(req.query.days || "30", 10);
        const to = new Date();
        to.setDate(to.getDate() + futureDays);
        to.setHours(23, 59, 59, 999);

        tasks = allTasks.filter(t => {
          if (!t.dueDate) return false;
          return new Date(t.dueDate) <= to;
        });
      }

      // Sort by closest to today: recent overdue first, then upcoming
      const today = Date.now();
      tasks.sort((a, b) => {
        const distA = Math.abs(new Date(a.dueDate) - today);
        const distB = Math.abs(new Date(b.dueDate) - today);
        return distA - distB;
      });

      const page = tasks.slice(0, 10);

      // Batch-fetch full contact details for all unique personIds
      const personIds = [...new Set(page.map(t => t.personId).filter(Boolean))];
      const contacts = {}; // personId → { name, phone, email, address }
      if (personIds.length > 0) {
        try {
          const pr = await fetch(`${FUB_BASE}/people?ids=${personIds.join(",")}&limit=200`, { headers: fubHeaders() });
          const pd = await pr.json();
          for (const p of (pd.people || [])) {
            const phones = (p.phones || []).map(ph => ({ number: ph.value, type: ph.type }));
            const emails = (p.emails || []).map(em => ({ address: em.value, type: em.type }));
            const addr = p.addresses?.[0];
            contacts[p.id] = {
              name: p.name || null,
              phones,
              emails,
              address: addr ? [addr.street, addr.city, addr.state, addr.code].filter(Boolean).join(", ") : null,
            };
          }
        } catch (e) {
          console.warn("[FUB] person lookup failed:", e.message);
        }
      }

      const result = page.map(t => {
        const contact = contacts[t.personId] || {};
        return {
          id: t.id,
          type: t.type || "",
          description: t.name || "",
          dueDate: t.dueDate || null,
          isCompleted: !!t.isCompleted,
          assignedTo: t.AssignedTo || null,
          contact: t.personId ? {
            name: contact.name || null,
            phones: contact.phones || [],
            emails: contact.emails || [],
            address: contact.address || null,
          } : null,
        };
      });

      console.log(`[FUB] ${allTasks.length} fetched, ${tasks.length} in window, returning ${result.length}`);

      res.json({ ok: true, tasks: result, total: result.length });
    } catch (e) {
      console.error("[FUB] tasks error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * GET /fub/contacts/search
   *
   * Search contacts by partial name (case-insensitive), scoped to agent.
   *
   * Query params:
   *   agent=NAME   agent name (default: "me")
   *   q=QUERY      partial name to search (required)
   *   limit=N      max results (default: 10, max: 50)
   */
  app.get("/fub/contacts/search", async (req, res) => {
    try {
      const q = req.query.q?.trim();
      if (!q) {
        return res.status(400).json({ ok: false, error: "q (search query) is required" });
      }

      const limit = Math.min(parseInt(req.query.limit || "10", 10), 50);
      const assignedUserId = req.query.agent === "all" ? null : await resolveAgentFromRequest(req);

      // FUB does not support substring name search — fetch all agent contacts
      // and filter client-side (case-insensitive substring match on name).
      const qLower = q.toLowerCase();
      // Paginate through ALL agent contacts — no cap.
      // Sort by id desc (newest first) so recently created uncontacted leads
      // appear at the top and are found quickly even before a full scan.
      const allPeople = [];
      let offset = 0;
      const pageSize = 200;

      while (true) {
        const params = new URLSearchParams({
          sort: "id",
          direction: "desc",
          limit: String(pageSize),
          offset: String(offset),
        });
        if (assignedUserId) params.set("assignedUserId", String(assignedUserId));

        const r = await fetch(`${FUB_BASE}/people?${params}`, { headers: fubHeaders() });
        const data = await r.json();
        if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);

        const batch = data.people || [];
        const ids = batch.map(p => p.id);
        console.log(`[FUB] search page offset=${offset}: ${batch.length} people, ids ${ids[0]}..${ids[ids.length-1]}, total reported=${data.total}`);
        allPeople.push(...batch);

        if (batch.length < pageSize) break; // reached end
        offset += pageSize;
      }
      console.log(`[FUB] search total fetched: ${allPeople.length}, looking for "${q}" (id 113774 present: ${allPeople.some(p => p.id === 113774)})`);


      const qWords = qLower.split(/\s+/).filter(Boolean);
      const matched = allPeople.filter(p => {
        const name = (p.name || "").toLowerCase();
        return qWords.every(word => name.includes(word));
      });

      const contacts = matched.slice(0, limit).map(p => {
        const phones = (p.phones || []).map(ph => ({ number: ph.value, type: ph.type }));
        const emails = (p.emails || []).map(em => ({ address: em.value, type: em.type }));
        const addr = p.addresses?.[0];
        return {
          id: p.id,
          name: p.name || null,
          phones,
          emails,
          address: addr ? [addr.street, addr.city, addr.state, addr.code].filter(Boolean).join(", ") : null,
          lastActivityDate: p.lastActivityDate || null,
          stage: p.stage || null,
          created: p.created || null,
        };
      });

      console.log(`[FUB] contact search "${q}": scanned ${allPeople.length}, matched ${matched.length}, returning ${contacts.length}`);
      res.json({ ok: true, contacts, total: contacts.length });
    } catch (e) {
      console.error("[FUB] contact search error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * GET /fub/contacts/recent
   *
   * Returns the most recently contacted clients for an agent, sorted by
   * lastActivityDate descending.
   *
   * Query params:
   *   agent=NAME   agent name (default: "me")
   *   limit=N      number of contacts to return (default: 5, max: 50)
   *   days=N       only include contacts active within the last N days
   */
  app.get("/fub/contacts/recent", async (req, res) => {
    try {
      const limit = Math.min(parseInt(req.query.limit || "5", 10), 50);
      const days = req.query.days ? parseInt(req.query.days, 10) : null;
      const assignedUserId = req.query.agent === "all" ? null : await resolveAgentFromRequest(req);

      const params = new URLSearchParams({
        sort: "lastActivityDate",
        direction: "desc",
        limit: String(limit),
      });
      if (assignedUserId) params.set("assignedUserId", String(assignedUserId));

      const r = await fetch(`${FUB_BASE}/people?${params}`, { headers: fubHeaders() });
      const data = await r.json();
      if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);

      let people = data.people || [];

      // Filter by days if specified
      if (days !== null) {
        const cutoff = new Date();
        cutoff.setDate(cutoff.getDate() - days);
        people = people.filter(p => p.lastActivityDate && new Date(p.lastActivityDate) >= cutoff);
      }

      const contacts = people.map(p => {
        const phones = (p.phones || []).map(ph => ({ number: ph.value, type: ph.type }));
        const emails = (p.emails || []).map(em => ({ address: em.value, type: em.type }));
        const addr = p.addresses?.[0];
        return {
          id: p.id,
          name: p.name || null,
          phones,
          emails,
          address: addr ? [addr.street, addr.city, addr.state, addr.code].filter(Boolean).join(", ") : null,
          lastActivityDate: p.lastActivityDate || null,
          stage: p.stage || null,
        };
      });

      console.log(`[FUB] recent contacts: returning ${contacts.length}`);
      res.json({ ok: true, contacts, total: contacts.length });
    } catch (e) {
      console.error("[FUB] recent contacts error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * POST /fub/text
   *
   * Send a text message to a FUB contact on behalf of an agent.
   * Resolves client by name (scoped to agent's contacts) if person_id not provided.
   * When multiple name matches exist, picks the most recently active contact.
   *
   * Body: { agent, message, person_id?, client_name? }
   */
  app.post("/fub/text", async (req, res) => {
    try {
      const { message, person_id, client_name } = req.body || {};

      if (!message?.trim()) {
        return res.status(400).json({ ok: false, error: "message is required" });
      }

      const userId = await resolveAgentFromRequest(req);
      if (!userId) {
        return res.status(400).json({ ok: false, error: "Could not resolve agent identity" });
      }

      // Resolve personId — use directly if provided, otherwise search by name
      let personId = person_id ? Number(person_id) : null;
      let resolvedName = null;

      if (!personId) {
        if (!client_name?.trim()) {
          return res.status(400).json({ ok: false, error: "Either person_id or client_name is required" });
        }

        // Search people scoped to this agent, sorted by last activity
        const params = new URLSearchParams({
          name: client_name.trim(),
          assignedUserId: String(userId),
          sort: "lastActivityDate",
          direction: "desc",
          limit: "10",
        });
        const r = await fetch(`${FUB_BASE}/people?${params}`, { headers: fubHeaders() });
        const data = await r.json();
        if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);

        const matches = data.people || [];
        if (matches.length === 0) {
          return res.json({ ok: false, error: `No contact found matching "${client_name}" for this agent` });
        }

        // First result is most recently active (sorted by lastActivityDate desc)
        personId = matches[0].id;
        resolvedName = matches[0].name;
        if (matches.length > 1) {
          console.log(`[FUB] text: "${client_name}" matched ${matches.length} contacts, using most recent: ${resolvedName}`);
        }
      }

      // Send text message via FUB
      const payload = { userId, personId, message: message.trim() };
      const r = await fetch(`${FUB_BASE}/textMessages`, {
        method: "POST",
        headers: fubHeaders(),
        body: JSON.stringify(payload),
      });
      const data = await r.json();
      if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);

      console.log(`[FUB] text sent to personId=${personId} by userId=${userId}`);
      res.json({ ok: true, personId, resolvedName, messageId: data.id || null });
    } catch (e) {
      console.error("[FUB] text error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * POST /fub/note
   *
   * Create a note on a FUB contact on behalf of an agent.
   * Resolves client by name (scoped to agent's contacts) if person_id not provided.
   * When multiple name matches exist, picks the most recently active contact.
   *
   * Body: { agent, body, person_id?, client_name? }
   */
  app.post("/fub/note", async (req, res) => {
    try {
      const { body: noteBody, person_id, client_name } = req.body || {};

      if (!noteBody?.trim()) {
        return res.status(400).json({ ok: false, error: "body is required" });
      }

      const userId = await resolveAgentFromRequest(req);
      if (!userId) {
        return res.status(400).json({ ok: false, error: "Could not resolve agent identity" });
      }

      // Resolve personId — use directly if provided, otherwise search by name
      let personId = person_id ? Number(person_id) : null;
      let resolvedName = null;

      if (!personId) {
        if (!client_name?.trim()) {
          return res.status(400).json({ ok: false, error: "Either person_id or client_name is required" });
        }

        const params = new URLSearchParams({
          name: client_name.trim(),
          assignedUserId: String(userId),
          sort: "lastActivityDate",
          direction: "desc",
          limit: "10",
        });
        const r = await fetch(`${FUB_BASE}/people?${params}`, { headers: fubHeaders() });
        const data = await r.json();
        if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);

        const matches = data.people || [];
        if (matches.length === 0) {
          return res.json({ ok: false, error: `No contact found matching "${client_name}" for this agent` });
        }

        personId = matches[0].id;
        resolvedName = matches[0].name;
        if (matches.length > 1) {
          console.log(`[FUB] note: "${client_name}" matched ${matches.length} contacts, using most recent: ${resolvedName}`);
        }
      }

      // Create note via FUB
      const payload = { userId, personId, body: noteBody.trim() };
      const r = await fetch(`${FUB_BASE}/notes`, {
        method: "POST",
        headers: fubHeaders(),
        body: JSON.stringify(payload),
      });
      const data = await r.json();
      if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);

      console.log(`[FUB] note created for personId=${personId} by userId=${userId}`);
      res.json({ ok: true, personId, resolvedName, noteId: data.id || null });
    } catch (e) {
      console.error("[FUB] note error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });
}
