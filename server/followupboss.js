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
 * Resolve a person by partial name using client-side substring scan.
 * Scoped to the given agent (assignedUserId). Paginates all contacts.
 * Returns { id, name } of the most recently active match, or null.
 */
async function resolvePersonByName(name, assignedUserId) {
  const qWords = name.toLowerCase().split(/\s+/).filter(Boolean);
  const pageSize = 100;
  let offset = 0;
  let bestMatch = null;

  while (true) {
    const params = new URLSearchParams({
      sort: "lastActivityDate",
      direction: "desc",
      limit: String(pageSize),
      offset: String(offset),
    });
    if (assignedUserId) params.set("assignedUserId", String(assignedUserId));

    const r = await fetch(`${FUB_BASE}/people?${params}`, { headers: fubHeaders() });
    const data = await r.json();
    if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);

    const batch = data.people || [];
    for (const p of batch) {
      const pName = (p.name || "").toLowerCase();
      if (qWords.every(w => pName.includes(w))) {
        // First match is best (sorted by lastActivityDate desc)
        if (!bestMatch) bestMatch = { id: p.id, name: p.name };
      }
    }

    if (bestMatch || batch.length < pageSize) break;
    offset += pageSize;
  }

  return bestMatch;
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
   * GET /fub/contacts
   *
   * Returns all contacts for an agent, paginated.
   *
   * Query params:
   *   agent_id=N   agent user ID (preferred)
   *   agent=NAME   agent name (fallback)
   *   limit=N      max results (default: 50, max: 200)
   *   offset=N     pagination offset (default: 0)
   */
  app.get("/fub/contacts", async (req, res) => {
    try {
      const limit = Math.min(parseInt(req.query.limit || "50", 10), 200);
      const offset = parseInt(req.query.offset || "0", 10);
      const assignedUserId = req.query.agent === "all" ? null : await resolveAgentFromRequest(req);

      const params = new URLSearchParams({
        sort: "id",
        direction: "desc",
        limit: String(limit),
        offset: String(offset),
      });
      if (assignedUserId) params.set("assignedUserId", String(assignedUserId));

      const r = await fetch(`${FUB_BASE}/people?${params}`, { headers: fubHeaders() });
      const data = await r.json();
      if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);

      const contacts = (data.people || []).map(p => ({
        id: p.id,
        name: p.name || null,
        stage: p.stage || null,
        lastActivityDate: p.lastActivity || null,
        created: p.created || null,
        assignedUserId: p.assignedUserId || null,
        assignedTo: p.assignedTo || null,
      }));

      console.log(`[FUB] contacts: offset=${offset} limit=${limit} assignedUserId=${assignedUserId} → ${contacts.length} results (total=${data.total})`);
      res.json({ ok: true, contacts, total: data.total, returned: contacts.length, offset });
    } catch (e) {
      console.error("[FUB] contacts error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * GET /fub/contacts/search
   *
   * Search contacts by partial name (case-insensitive), scoped to agent.
   *
   * Query params:
   *   agent_id=N   agent user ID (preferred)
   *   agent=NAME   agent name (fallback)
   *   q=QUERY      partial name to search (required)
   *   limit=N      max results (default: 10, max: 50)
   *   mode=name    use FUB native name= param (fast, single request; may be prefix-only)
   *                omit or any other value = client-side scan (default, finds substrings)
   */
  app.get("/fub/contacts/search", async (req, res) => {
    try {
      const q = req.query.q?.trim();
      if (!q) {
        return res.status(400).json({ ok: false, error: "q (search query) is required" });
      }

      const limit = Math.min(parseInt(req.query.limit || "10", 10), 50);
      const assignedUserId = req.query.agent === "all" ? null : await resolveAgentFromRequest(req);
      const mode = req.query.mode;

      let people;

      if (mode === "name") {
        // Fast path: pass name= directly to FUB API (single request, but may be prefix-only)
        const params = new URLSearchParams({
          name: q,
          sort: "lastActivityDate",
          direction: "desc",
          limit: String(Math.min(limit, 50)),
        });
        if (assignedUserId) params.set("assignedUserId", String(assignedUserId));

        const r = await fetch(`${FUB_BASE}/people?${params}`, { headers: fubHeaders() });
        const data = await r.json();
        if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);
        people = data.people || [];
        console.log(`[FUB] contact search (mode=name) "${q}": FUB returned ${people.length}`);
      } else {
        // Default: paginate all agent contacts and filter client-side (substring match)
        const qLower = q.toLowerCase();
        const qWords = qLower.split(/\s+/).filter(Boolean);
        const allPeople = [];
        let offset = 0;
        const pageSize = 100; // FUB API max limit per request

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
          allPeople.push(...batch);

          if (batch.length < pageSize) break;
          offset += pageSize;
        }

        const matched = allPeople.filter(p => {
          const name = (p.name || "").toLowerCase();
          return qWords.every(word => name.includes(word));
        });
        console.log(`[FUB] contact search (scan) "${q}": scanned ${allPeople.length}, matched ${matched.length}`);
        people = matched.slice(0, limit);
      }

      const contacts = people.slice(0, limit).map(p => {
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

      res.json({ ok: true, contacts, total: contacts.length, mode: mode || "scan" });
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

      const agentId = await resolveAgentFromRequest(req);
      if (!agentId) {
        return res.status(400).json({ ok: false, error: "Could not resolve agent identity" });
      }

      // Resolve personId — use directly if provided, otherwise substring scan by name
      let personId = person_id ? Number(person_id) : null;
      let resolvedName = null;

      if (!personId) {
        if (!client_name?.trim()) {
          return res.status(400).json({ ok: false, error: "Either person_id or client_name is required" });
        }
        const match = await resolvePersonByName(client_name.trim(), agentId);
        if (!match) {
          return res.json({ ok: false, error: `No contact found matching "${client_name}" for this agent` });
        }
        personId = match.id;
        resolvedName = match.name;
        console.log(`[FUB] text: "${client_name}" resolved to ${resolvedName} (id=${personId})`);
      } else {
        if (personId === agentId) {
          console.warn(`[FUB] text WARNING: person_id=${personId} equals agentId=${agentId} — likely a model error`);
          return res.status(400).json({ ok: false, error: `person_id ${personId} matches the agent user ID — this is likely wrong. Search for the contact first.` });
        }
        console.log(`[FUB] text: using direct person_id=${personId}`);
      }

      // Send text message via FUB (omit agentId — API key owner's texting number is used)
      const payload = { personId, message: message.trim() };
      const r = await fetch(`${FUB_BASE}/textMessages`, {
        method: "POST",
        headers: fubHeaders(),
        body: JSON.stringify(payload),
      });
      const data = await r.json();
      if (!r.ok) {
        console.error(`[FUB] text API error ${r.status}:`, JSON.stringify(data));
        throw new Error(data?.message || data?.error || `FUB error ${r.status}`);
      }

      console.log(`[FUB] text sent to personId=${personId} by agentId=${agentId}`);
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

      const agentId = await resolveAgentFromRequest(req);
      if (!agentId) {
        return res.status(400).json({ ok: false, error: "Could not resolve agent identity" });
      }

      // Resolve personId — use directly if provided, otherwise substring scan by name
      let personId = person_id ? Number(person_id) : null;
      let resolvedName = null;

      if (!personId) {
        if (!client_name?.trim()) {
          return res.status(400).json({ ok: false, error: "Either person_id or client_name is required" });
        }
        const match = await resolvePersonByName(client_name.trim(), agentId);
        if (!match) {
          return res.json({ ok: false, error: `No contact found matching "${client_name}" for this agent` });
        }
        personId = match.id;
        resolvedName = match.name;
        console.log(`[FUB] note: "${client_name}" resolved to ${resolvedName} (id=${personId})`);
      } else {
        if (personId === agentId) {
          console.warn(`[FUB] note WARNING: person_id=${personId} equals agentId=${agentId} — likely a model error`);
          return res.status(400).json({ ok: false, error: `person_id ${personId} matches the agent user ID — this is likely wrong. Search for the contact first.` });
        }
        console.log(`[FUB] note: using direct person_id=${personId}`);
      }

      // Create note via FUB (agentId is optional — omit to avoid potential 400)
      const payload = { personId, body: noteBody.trim() };
      const r = await fetch(`${FUB_BASE}/notes`, {
        method: "POST",
        headers: fubHeaders(),
        body: JSON.stringify(payload),
      });
      const data = await r.json();
      if (!r.ok) {
        console.error(`[FUB] note API error ${r.status}:`, JSON.stringify(data));
        throw new Error(data?.message || data?.error || `FUB error ${r.status}`);
      }

      console.log(`[FUB] note created for personId=${personId} by agentId=${agentId}`);
      res.json({ ok: true, personId, resolvedName, noteId: data.id || null });
    } catch (e) {
      console.error("[FUB] note error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * POST /fub/contact/update
   *
   * Update one or more fields on a FUB contact in a single call.
   * Fetches current person data first for fields that require merge (tags, phones, emails, addresses).
   *
   * Body:
   *   person_id?        FUB person ID (preferred)
   *   client_name?      partial name to resolve (fallback)
   *   agent_id?         agent user ID (preferred)
   *   agent?            agent name (fallback)
   *   stage?            new stage string
   *   name?             full name string
   *   background_info?  background info / bio text
   *   tags?             { mode: "add"|"remove"|"set", values: string[] }
   *   phones?           [{ number, type, action? }]  action: "set" (default) | "remove"
   *   emails?           [{ address, type, action? }]
   *   address?          { street?, city?, state?, zip?, country?, type?, action? }
   */
  app.post("/fub/contact/update", async (req, res) => {
    try {
      const { person_id, client_name, stage, name, background_info, tags, phones, emails, address } = req.body || {};

      let personId = person_id ? Number(person_id) : null;
      let resolvedName = null;

      if (!personId) {
        if (!client_name?.trim()) {
          return res.status(400).json({ ok: false, error: "Either person_id or client_name is required" });
        }
        const assignedUserId = await resolveAgentFromRequest(req);
        const match = await resolvePersonByName(client_name.trim(), assignedUserId);
        if (!match) {
          return res.json({ ok: false, error: `No contact found matching "${client_name}"` });
        }
        personId = match.id;
        resolvedName = match.name;
        console.log(`[FUB] update: "${client_name}" resolved to ${resolvedName} (id=${personId})`);
      } else {
        // Guard: warn if person_id suspiciously matches the agent's own user ID
        const agentId = await resolveAgentFromRequest(req).catch(() => null);
        if (agentId && personId === agentId) {
          console.warn(`[FUB] update WARNING: person_id=${personId} equals agentId=${agentId} — likely a model error passing agent ID as contact ID`);
          return res.status(400).json({ ok: false, error: `person_id ${personId} matches the agent user ID — this is likely wrong. Search for the contact first using fub_search_contacts.` });
        }
        console.log(`[FUB] update: using direct person_id=${personId}`);
      }

      // Fetch current person data only when merge is needed
      const needsFetch = !!(tags || phones || emails || address);
      let current = null;
      if (needsFetch) {
        const pr = await fetch(`${FUB_BASE}/people/${personId}`, { headers: fubHeaders() });
        const pd = await pr.json();
        if (!pr.ok) throw new Error(pd?.message || `FUB error ${pr.status}`);
        current = pd;
        if (!resolvedName) resolvedName = pd.name || null;
      }

      const payload = {};

      if (stage) payload.stage = stage.trim();
      if (name) payload.name = name.trim();
      if (background_info) payload.backgroundInformation = background_info.trim();

      // Tags merge
      if (tags) {
        const { mode, values = [] } = tags;
        const currentTags = (current.tags || []).map(t => (typeof t === "string" ? t : t.name || String(t)));
        const incoming = values.map(t => String(t).trim()).filter(Boolean);
        if (mode === "set") {
          payload.tags = incoming;
        } else if (mode === "add") {
          const tagSet = new Set(currentTags);
          for (const t of incoming) tagSet.add(t);
          payload.tags = [...tagSet];
        } else if (mode === "remove") {
          const removeSet = new Set(incoming.map(t => t.toLowerCase()));
          payload.tags = currentTags.filter(t => !removeSet.has(t.toLowerCase()));
        }
      }

      // Phones merge (replace entire array)
      if (phones && phones.length > 0) {
        let curr = (current.phones || []).map(p => ({ value: p.value, type: p.type || "mobile" }));
        for (const ph of phones) {
          const type = ph.type || "mobile";
          if (ph.action === "remove") {
            curr = curr.filter(p => !(p.type === type || (ph.number && p.value === ph.number)));
          } else {
            const idx = curr.findIndex(p => p.type === type);
            if (idx >= 0) {
              curr[idx] = { value: ph.number, type };
            } else {
              curr.push({ value: ph.number, type });
            }
          }
        }
        payload.phones = curr;
      }

      // Emails merge (replace entire array)
      if (emails && emails.length > 0) {
        let curr = (current.emails || []).map(e => ({ value: e.value, type: e.type || "personal" }));
        for (const em of emails) {
          const type = em.type || "personal";
          if (em.action === "remove") {
            curr = curr.filter(e => !(e.type === type || (em.address && e.value === em.address)));
          } else {
            const idx = curr.findIndex(e => e.type === type);
            if (idx >= 0) {
              curr[idx] = { value: em.address, type };
            } else {
              curr.push({ value: em.address, type });
            }
          }
        }
        payload.emails = curr;
      }

      // Address merge (replace entire array)
      if (address) {
        const type = address.type || "home";
        let curr = (current.addresses || []).map(a => ({
          street: a.street, city: a.city, state: a.state,
          code: a.code, country: a.country, type: a.type || "home",
        }));
        if (address.action === "remove") {
          curr = curr.filter(a => a.type !== type);
        } else {
          const newAddr = {
            ...(address.street && { street: address.street }),
            ...(address.city && { city: address.city }),
            ...(address.state && { state: address.state }),
            ...(address.zip && { code: address.zip }),
            ...(address.country && { country: address.country }),
            type,
          };
          const idx = curr.findIndex(a => a.type === type);
          if (idx >= 0) {
            curr[idx] = { ...curr[idx], ...newAddr };
          } else {
            curr.push(newAddr);
          }
        }
        payload.addresses = curr;
      }

      if (Object.keys(payload).length === 0) {
        return res.status(400).json({ ok: false, error: "No fields to update provided" });
      }

      const r = await fetch(`${FUB_BASE}/people/${personId}`, {
        method: "PUT",
        headers: fubHeaders(),
        body: JSON.stringify(payload),
      });
      const data = await r.json();
      if (!r.ok) {
        console.error(`[FUB] update person API error ${r.status}:`, JSON.stringify(data));
        throw new Error(data?.message || data?.error || `FUB error ${r.status}`);
      }

      const updated = Object.keys(payload);
      console.log(`[FUB] person updated personId=${personId}: ${updated.join(", ")}`);
      res.json({ ok: true, personId, resolvedName: resolvedName || data.name || null, updated });
    } catch (e) {
      console.error("[FUB] update person error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * GET /fub/contact/tags
   *
   * Get tags for a FUB contact.
   * Resolves contact by name (substring scan) if person_id not provided.
   *
   * Query params:
   *   agent_id=N   agent user ID (preferred)
   *   agent=NAME   agent name (fallback)
   *   person_id=N  FUB person ID (preferred)
   *   client_name=NAME  partial name to look up (fallback)
   */
  app.get("/fub/contact/tags", async (req, res) => {
    try {
      let personId = req.query.person_id ? Number(req.query.person_id) : null;
      let resolvedName = null;

      if (!personId) {
        const clientName = req.query.client_name?.trim();
        if (!clientName) {
          return res.status(400).json({ ok: false, error: "Either person_id or client_name is required" });
        }
        const assignedUserId = await resolveAgentFromRequest(req);
        const match = await resolvePersonByName(clientName, assignedUserId);
        if (!match) {
          return res.json({ ok: false, error: `No contact found matching "${clientName}"` });
        }
        personId = match.id;
        resolvedName = match.name;
      }

      const r = await fetch(`${FUB_BASE}/people/${personId}`, { headers: fubHeaders() });
      const data = await r.json();
      if (!r.ok) return res.status(r.status).json({ ok: false, error: data?.message || `FUB error ${r.status}` });

      const tags = (data.tags || []).map(t => (typeof t === "string" ? t : t.name || String(t)));
      res.json({ ok: true, personId, resolvedName: resolvedName || data.name || null, tags });
    } catch (e) {
      console.error("[FUB] get tags error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * POST /fub/contact/tags
   *
   * Add, remove, or set tags on a FUB contact.
   * Resolves contact by name (substring scan) if person_id not provided.
   *
   * Body:
   *   person_id?    FUB person ID (preferred)
   *   client_name?  partial name to look up (fallback)
   *   agent_id?     agent user ID (preferred)
   *   agent?        agent name (fallback)
   *   mode          "add" | "remove" | "set"
   *   tags          array of tag strings to add/remove/set
   */
  app.post("/fub/contact/tags", async (req, res) => {
    try {
      const { person_id, client_name, mode, tags: incomingTags } = req.body || {};

      if (!mode || !["add", "remove", "set"].includes(mode)) {
        return res.status(400).json({ ok: false, error: "mode must be 'add', 'remove', or 'set'" });
      }
      if (!Array.isArray(incomingTags) || incomingTags.length === 0) {
        return res.status(400).json({ ok: false, error: "tags must be a non-empty array" });
      }

      const agentIdForTags = await resolveAgentFromRequest(req);
      let personId = person_id ? Number(person_id) : null;
      let resolvedName = null;

      if (!personId) {
        if (!client_name?.trim()) {
          return res.status(400).json({ ok: false, error: "Either person_id or client_name is required" });
        }
        const match = await resolvePersonByName(client_name.trim(), agentIdForTags);
        if (!match) {
          return res.json({ ok: false, error: `No contact found matching "${client_name}"` });
        }
        personId = match.id;
        resolvedName = match.name;
        console.log(`[FUB] tags: "${client_name}" resolved to ${resolvedName} (id=${personId})`);
      } else {
        if (agentIdForTags && personId === agentIdForTags) {
          console.warn(`[FUB] tags WARNING: person_id=${personId} equals agentId=${agentIdForTags} — likely a model error`);
          return res.status(400).json({ ok: false, error: `person_id ${personId} matches the agent user ID — this is likely wrong. Search for the contact first.` });
        }
        console.log(`[FUB] tags: using direct person_id=${personId}`);
      }

      // Fetch current tags unless mode is "set"
      let finalTags;
      if (mode === "set") {
        finalTags = incomingTags.map(t => String(t).trim()).filter(Boolean);
      } else {
        const pr = await fetch(`${FUB_BASE}/people/${personId}`, { headers: fubHeaders() });
        const pd = await pr.json();
        if (!pr.ok) throw new Error(pd?.message || `FUB error ${pr.status}`);
        if (!resolvedName) resolvedName = pd.name || null;

        const currentTags = (pd.tags || []).map(t => (typeof t === "string" ? t : t.name || String(t)));
        const incoming = incomingTags.map(t => String(t).trim()).filter(Boolean);

        if (mode === "add") {
          const tagSet = new Set(currentTags);
          for (const t of incoming) tagSet.add(t);
          finalTags = [...tagSet];
        } else {
          // remove
          const removeSet = new Set(incoming.map(t => t.toLowerCase()));
          finalTags = currentTags.filter(t => !removeSet.has(t.toLowerCase()));
        }
      }

      const r = await fetch(`${FUB_BASE}/people/${personId}`, {
        method: "PUT",
        headers: fubHeaders(),
        body: JSON.stringify({ tags: finalTags }),
      });
      const data = await r.json();
      if (!r.ok) {
        console.error(`[FUB] tags PUT error ${r.status}:`, JSON.stringify(data));
        throw new Error(data?.message || data?.error || `FUB error ${r.status}`);
      }

      const updatedTags = (data.tags || []).map(t => (typeof t === "string" ? t : t.name || String(t)));
      console.log(`[FUB] tags updated (${mode}) for personId=${personId}: ${updatedTags.join(", ")}`);
      res.json({ ok: true, personId, resolvedName: resolvedName || data.name || null, tags: updatedTags });
    } catch (e) {
      console.error("[FUB] update tags error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * GET /fub/stages
   *
   * Returns all available lead stages from FUB.
   */
  app.get("/fub/stages", async (req, res) => {
    try {
      const allStages = [];
      let offset = 0;
      const limit = 100;

      while (true) {
        const params = new URLSearchParams({ limit: String(limit), offset: String(offset) });
        const r = await fetch(`${FUB_BASE}/stages?${params}`, { headers: fubHeaders() });
        const data = await r.json();
        if (!r.ok) throw new Error(data?.message || `FUB error ${r.status}`);
        const batch = data.stages || [];
        allStages.push(...batch);
        if (batch.length < limit) break;
        offset += limit;
      }

      const stages = allStages.map(s => ({ id: s.id, name: s.name }));
      res.json({ ok: true, stages, total: stages.length });
    } catch (e) {
      console.error("[FUB] stages error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });

  /**
   * POST /fub/contact/stage
   *
   * Update the stage of a FUB contact.
   * Resolves contact by name (substring scan) if person_id not provided.
   *
   * Body: { agent_id?, agent?, person_id?, client_name?, stage }
   */
  app.post("/fub/contact/stage", async (req, res) => {
    try {
      const { person_id, client_name, stage } = req.body || {};

      if (!stage?.trim()) {
        return res.status(400).json({ ok: false, error: "stage is required" });
      }

      const agentId = await resolveAgentFromRequest(req);
      if (!agentId) {
        return res.status(400).json({ ok: false, error: "Could not resolve agent identity" });
      }

      // Resolve personId — use directly if provided, otherwise substring scan by name
      let personId = person_id ? Number(person_id) : null;
      let resolvedName = null;

      if (!personId) {
        if (!client_name?.trim()) {
          return res.status(400).json({ ok: false, error: "Either person_id or client_name is required" });
        }
        const match = await resolvePersonByName(client_name.trim(), agentId);
        if (!match) {
          return res.json({ ok: false, error: `No contact found matching "${client_name}" for this agent` });
        }
        personId = match.id;
        resolvedName = match.name;
        console.log(`[FUB] stage update: "${client_name}" resolved to ${resolvedName} (id=${personId})`);
      } else {
        if (personId === agentId) {
          console.warn(`[FUB] stage WARNING: person_id=${personId} equals agentId=${agentId} — likely a model error`);
          return res.status(400).json({ ok: false, error: `person_id ${personId} matches the agent user ID — this is likely wrong. Search for the contact first.` });
        }
        console.log(`[FUB] stage update: using direct person_id=${personId}`);
      }

      const r = await fetch(`${FUB_BASE}/people/${personId}`, {
        method: "PUT",
        headers: fubHeaders(),
        body: JSON.stringify({ stage: stage.trim() }),
      });
      const data = await r.json();
      if (!r.ok) {
        console.error(`[FUB] stage API error ${r.status}:`, JSON.stringify(data));
        throw new Error(data?.message || data?.error || `FUB error ${r.status}`);
      }

      console.log(`[FUB] stage updated for personId=${personId} to "${stage}"`);
      res.json({ ok: true, personId, resolvedName: resolvedName || data.name || null, stage: data.stage || stage });
    } catch (e) {
      console.error("[FUB] stage update error:", e);
      res.status(500).json({ ok: false, error: String(e) });
    }
  });
}
