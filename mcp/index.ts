import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { Database } from "bun:sqlite";
import { z } from "zod";
import { homedir } from "os";
import { existsSync } from "fs";

const DB_PATH = process.env.ENGSIGHT_DB || `${homedir()}/.engsight/engsight.db`;

function getDb(): Database {
  if (!existsSync(DB_PATH)) {
    throw new Error(`engsight database not found at ${DB_PATH}. Run install.sh first.`);
  }
  return new Database(DB_PATH, { readonly: true });
}

function dateAgo(days: number): string {
  const d = new Date();
  d.setDate(d.getDate() - days);
  return d.toISOString().slice(0, 10);
}

function resolveDateRange(params: {
  since?: string;
  until?: string;
  daily?: boolean;
  weekly?: boolean;
}): { since: string; until: string } {
  if (params.daily) return { since: dateAgo(0), until: dateAgo(0) };
  if (params.since) return { since: params.since, until: params.until || dateAgo(0) };
  return { since: dateAgo(7), until: dateAgo(0) };
}

function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return m > 0 ? `${h}h ${m}m` : `${h}h`;
}

const server = new McpServer({
  name: "engsight",
  version: "1.0.0",
});

// --- Tool: engsight_log ---
server.tool(
  "engsight_log",
  "Show recent git events across all repos. Returns timestamps, event types, repos, branches, and event details.",
  {
    repo: z.string().optional().describe("Filter by repo name"),
    type: z.string().optional().describe("Filter by event type (commit, checkout, push, merge, rewrite, pre_commit, rebase)"),
    since: z.string().optional().describe("Show events after this date (YYYY-MM-DD)"),
    limit: z.number().optional().describe("Max events to return (default: 20)"),
  },
  async ({ repo, type, since, limit }) => {
    const db = getDb();
    const conditions: string[] = ["1=1"];
    if (repo) conditions.push(`repo_name = '${repo}'`);
    if (type) conditions.push(`event_type = '${type}'`);
    if (since) conditions.push(`timestamp >= '${since}T00:00:00Z'`);
    const where = conditions.join(" AND ");
    const max = limit || 20;

    const count = db.query(`SELECT COUNT(*) as c FROM events WHERE ${where}`).get() as any;
    const rows = db.query(`
      SELECT timestamp, event_type, repo_name, branch,
        CASE event_type
          WHEN 'commit' THEN
            CASE WHEN INSTR(json_extract(payload, '$.message'), CHAR(10)) > 0
              THEN SUBSTR(json_extract(payload, '$.message'), 1, INSTR(json_extract(payload, '$.message'), CHAR(10)) - 1)
              ELSE json_extract(payload, '$.message')
            END
          WHEN 'checkout' THEN json_extract(payload, '$.previous_branch') || ' -> ' || json_extract(payload, '$.new_branch')
          WHEN 'push' THEN json_extract(payload, '$.commits_being_pushed') || ' commit(s) pushed'
          WHEN 'merge' THEN 'merged ' || json_extract(payload, '$.merged_branch')
          WHEN 'rewrite' THEN json_extract(payload, '$.action')
          ELSE ''
        END as detail
      FROM events WHERE ${where}
      ORDER BY timestamp DESC LIMIT ${max}
    `).all();

    db.close();

    return {
      content: [{
        type: "text" as const,
        text: JSON.stringify({ total: count.c, showing: rows.length, events: rows }, null, 2),
      }],
    };
  }
);

// --- Tool: engsight_repos ---
server.tool(
  "engsight_repos",
  "List repos with activity counts, commit counts, branch switches, and last active timestamp.",
  {
    since: z.string().optional().describe("Show repos with activity after this date (YYYY-MM-DD)"),
  },
  async ({ since }) => {
    const db = getDb();
    const where = since ? `timestamp >= '${since}T00:00:00Z'` : "1=1";

    const rows = db.query(`
      SELECT repo_name,
        COUNT(*) as event_count,
        SUM(CASE WHEN event_type='commit' THEN 1 ELSE 0 END) as commits,
        SUM(CASE WHEN event_type='checkout' THEN 1 ELSE 0 END) as checkouts,
        MAX(timestamp) as last_active
      FROM events WHERE ${where}
      GROUP BY repo_name ORDER BY event_count DESC
    `).all();

    db.close();

    return {
      content: [{
        type: "text" as const,
        text: JSON.stringify({ repos: rows }, null, 2),
      }],
    };
  }
);

// --- Tool: engsight_summary ---
server.tool(
  "engsight_summary",
  "Summarize engineering activity for a time period: repos, commits, pushes, merges, AI signatures (co-authorship + process presence + artifact presence), time patterns.",
  {
    daily: z.boolean().optional().describe("Summarize today"),
    weekly: z.boolean().optional().describe("Summarize last 7 days (default)"),
    since: z.string().optional().describe("Custom start date (YYYY-MM-DD)"),
    until: z.string().optional().describe("Custom end date (YYYY-MM-DD)"),
  },
  async (params) => {
    const db = getDb();
    const range = resolveDateRange(params);
    const tsStart = `${range.since}T00:00:00Z`;
    const tsEnd = `${range.until}T23:59:59Z`;
    const where = `timestamp >= '${tsStart}' AND timestamp <= '${tsEnd}'`;

    const overview = db.query(`
      SELECT
        COUNT(*) as total_events,
        COUNT(DISTINCT repo_name) as repos,
        SUM(CASE WHEN event_type='commit' THEN 1 ELSE 0 END) as commits,
        SUM(CASE WHEN event_type='checkout' THEN 1 ELSE 0 END) as checkouts,
        SUM(CASE WHEN event_type='push' THEN 1 ELSE 0 END) as pushes,
        SUM(CASE WHEN event_type='merge' THEN 1 ELSE 0 END) as merges
      FROM events WHERE ${where}
    `).get() as any;

    if (overview.total_events === 0) {
      db.close();
      return { content: [{ type: "text" as const, text: `No activity from ${range.since} to ${range.until}.` }] };
    }

    const repoBreakdown = db.query(`
      SELECT repo_name,
        SUM(CASE WHEN event_type='commit' THEN 1 ELSE 0 END) as commits,
        COUNT(*) as events
      FROM events WHERE ${where}
      GROUP BY repo_name ORDER BY 2 DESC
    `).all();

    // AI Signatures — three tiers
    const aiExplicit = db.query(`
      SELECT COUNT(*) as c FROM events
      WHERE ${where} AND event_type='commit'
      AND json_extract(payload, '$.ai_commit_signals.co_authored_by') != '[]'
    `).get() as any;

    const coauthors = db.query(`
      SELECT value, COUNT(*) as count
      FROM events, json_each(json_extract(payload, '$.ai_commit_signals.co_authored_by'))
      WHERE ${where} AND event_type='commit'
      AND json_extract(payload, '$.ai_commit_signals.co_authored_by') != '[]'
      GROUP BY value ORDER BY 2 DESC
    `).all();

    const aiProcess = db.query(`
      SELECT COUNT(*) as c FROM events
      WHERE ${where} AND event_type='commit'
      AND json_array_length(json_extract(payload, '$.process_context.active_ai_tools')) > 0
    `).get() as any;

    const aiToolBreakdown = db.query(`
      SELECT json_extract(value, '$.name') as tool, COUNT(*) as count
      FROM events, json_each(json_extract(payload, '$.process_context.active_ai_tools'))
      WHERE ${where} AND event_type='commit'
      GROUP BY 1 ORDER BY 2 DESC
    `).all();

    const aiArtifactRepos = db.query(`
      SELECT DISTINCT repo_name FROM events
      WHERE ${where} AND event_type='pre_commit'
      AND json_extract(payload, '$.ai_artifacts') != '{}'
    `).all();

    const aiCombined = db.query(`
      SELECT COUNT(*) as c FROM events
      WHERE ${where} AND event_type='commit' AND (
        json_extract(payload, '$.ai_commit_signals.co_authored_by') != '[]'
        OR json_array_length(json_extract(payload, '$.process_context.active_ai_tools')) > 0
        OR repo_name IN (
          SELECT DISTINCT repo_name FROM events
          WHERE ${where} AND event_type='pre_commit'
          AND json_extract(payload, '$.ai_artifacts') != '{}'
        )
      )
    `).get() as any;

    const timePatterns = db.query(`
      SELECT
        SUM(CASE WHEN CAST(json_extract(payload, '$.time_context.hour') AS INTEGER) BETWEEN 6 AND 11 THEN 1 ELSE 0 END) as morning,
        SUM(CASE WHEN CAST(json_extract(payload, '$.time_context.hour') AS INTEGER) BETWEEN 12 AND 17 THEN 1 ELSE 0 END) as afternoon,
        SUM(CASE WHEN CAST(json_extract(payload, '$.time_context.hour') AS INTEGER) BETWEEN 18 AND 22 THEN 1 ELSE 0 END) as evening,
        SUM(CASE WHEN CAST(json_extract(payload, '$.time_context.hour') AS INTEGER) >= 23 OR CAST(json_extract(payload, '$.time_context.hour') AS INTEGER) < 6 THEN 1 ELSE 0 END) as night,
        SUM(CASE WHEN json_extract(payload, '$.time_context.is_weekend') = 'true' THEN 1 ELSE 0 END) as weekend
      FROM events WHERE ${where} AND event_type='commit'
    `).get();

    db.close();

    const result = {
      period: { since: range.since, until: range.until },
      overview,
      repos: repoBreakdown,
      ai_signatures: {
        explicit_coauthorship: { commits: aiExplicit.c, coauthors },
        ai_tools_running: { commits: aiProcess.c, tools: aiToolBreakdown },
        ai_artifacts_present: { repos: aiArtifactRepos.map((r: any) => r.repo_name) },
        combined: {
          commits: aiCombined.c,
          total_commits: overview.commits,
          percentage: overview.commits > 0 ? Math.round((aiCombined.c / overview.commits) * 100) : 0,
        },
      },
      time_patterns: timePatterns,
    };

    return {
      content: [{ type: "text" as const, text: JSON.stringify(result, null, 2) }],
    };
  }
);

// --- Tool: engsight_sessions ---
server.tool(
  "engsight_sessions",
  "Reconstruct work sessions by clustering events with time gaps. Shows duration, commits, branch switches, AI usage, and repos per session.",
  {
    since: z.string().optional().describe("Start date (YYYY-MM-DD, default: 7 days ago)"),
    until: z.string().optional().describe("End date (YYYY-MM-DD, default: today)"),
    gap: z.number().optional().describe("Gap threshold in minutes for session boundary (default: 30)"),
    repo: z.string().optional().describe("Filter by repo name"),
    limit: z.number().optional().describe("Max sessions to return (default: 20)"),
  },
  async ({ since, until, gap, repo, limit: maxSessions }) => {
    const db = getDb();
    const s = since || dateAgo(7);
    const u = until || dateAgo(0);
    const gapSeconds = (gap || 30) * 60;
    const max = maxSessions || 20;

    let where = `timestamp >= '${s}T00:00:00Z' AND timestamp <= '${u}T23:59:59Z'`;
    if (repo) where += ` AND repo_name = '${repo}'`;

    // Build set of repos with AI artifacts
    const artifactRepoRows = db.query(`
      SELECT DISTINCT repo_name FROM events
      WHERE ${where} AND event_type='pre_commit'
      AND json_extract(payload, '$.ai_artifacts') != '{}'
    `).all() as any[];
    const artifactRepos = new Set(artifactRepoRows.map((r: any) => r.repo_name));

    const rows = db.query(`
      SELECT timestamp, event_type, repo_name, branch,
        json_extract(payload, '$.ai_commit_signals.co_authored_by') as ai_coauthors,
        json_array_length(json_extract(payload, '$.process_context.active_ai_tools')) as ai_tool_count
      FROM events WHERE ${where} ORDER BY timestamp ASC
    `).all() as any[];

    db.close();

    if (rows.length === 0) {
      return { content: [{ type: "text" as const, text: `No events from ${s} to ${u}.` }] };
    }

    interface Session {
      start: string;
      end: string;
      repos: Set<string>;
      branches: Set<string>;
      commits: number;
      checkouts: number;
      ai_commits: number;
      events: number;
      _lastEpoch: number;
    }

    const sessions: any[] = [];
    let session: Session | null = null;

    for (const row of rows) {
      const epoch = new Date(row.timestamp).getTime() / 1000;

      if (!session || (epoch - session._lastEpoch) > gapSeconds) {
        if (session) sessions.push(finishSession(session));
        session = {
          start: row.timestamp,
          end: row.timestamp,
          repos: new Set<string>(),
          branches: new Set<string>(),
          commits: 0,
          checkouts: 0,
          ai_commits: 0,
          events: 0,
          _lastEpoch: epoch,
        };
      }

      session.end = row.timestamp;
      session._lastEpoch = epoch;
      session.repos.add(row.repo_name);
      if (row.branch) session.branches.add(row.branch);
      session.events++;

      if (row.event_type === "commit") {
        session.commits++;
        // AI signature: any of co-authorship, process presence, or artifact presence
        const hasAi = (row.ai_coauthors && row.ai_coauthors !== "[]")
          || (row.ai_tool_count > 0)
          || artifactRepos.has(row.repo_name);
        if (hasAi) session.ai_commits++;
      }
      if (row.event_type === "checkout") session.checkouts++;
    }
    if (session) sessions.push(finishSession(session));

    function finishSession(s: Session) {
      const startEpoch = new Date(s.start).getTime() / 1000;
      const endEpoch = new Date(s.end).getTime() / 1000;
      const duration = Math.round(endEpoch - startEpoch);
      return {
        start: s.start,
        end: s.end,
        duration_seconds: duration,
        duration_human: formatDuration(duration),
        repos: [...s.repos],
        branches: [...s.branches],
        commits: s.commits,
        checkouts: s.checkouts,
        ai_commits: s.ai_commits,
        events: s.events,
      };
    }

    const result = sessions.reverse().slice(0, max);

    return {
      content: [{
        type: "text" as const,
        text: JSON.stringify({
          total_sessions: sessions.length,
          gap_minutes: gap || 30,
          period: { since: s, until: u },
          sessions: result,
        }, null, 2),
      }],
    };
  }
);

// --- Tool: engsight_patterns ---
server.tool(
  "engsight_patterns",
  "Surface working patterns: commit cadence, context switching, AI-assisted vs solo, commit granularity, file hotspots, branch lifecycle, push latency, rewrite rate, ownership concentration.",
  {
    daily: z.boolean().optional().describe("Analyze today"),
    weekly: z.boolean().optional().describe("Analyze last 7 days (default)"),
    since: z.string().optional().describe("Custom start date (YYYY-MM-DD)"),
    until: z.string().optional().describe("Custom end date (YYYY-MM-DD)"),
  },
  async (params) => {
    const db = getDb();
    const range = resolveDateRange(params);
    const tsStart = `${range.since}T00:00:00Z`;
    const tsEnd = `${range.until}T23:59:59Z`;
    const where = `timestamp >= '${tsStart}' AND timestamp <= '${tsEnd}'`;

    const overview = db.query(`
      SELECT COUNT(*) as total,
        SUM(CASE WHEN event_type='commit' THEN 1 ELSE 0 END) as commits,
        SUM(CASE WHEN event_type='checkout' THEN 1 ELSE 0 END) as checkouts,
        SUM(CASE WHEN event_type='push' THEN 1 ELSE 0 END) as pushes,
        SUM(CASE WHEN event_type='rewrite' THEN 1 ELSE 0 END) as rewrites,
        COUNT(DISTINCT repo_name) as repos
      FROM events WHERE ${where}
    `).get() as any;

    if (overview.total === 0) {
      db.close();
      return { content: [{ type: "text" as const, text: `No activity from ${range.since} to ${range.until}.` }] };
    }

    const granularity = db.query(`
      SELECT
        AVG(json_extract(payload, '$.files_changed')) as avg_files,
        AVG(COALESCE(json_extract(payload, '$.insertions'),0) + COALESCE(json_extract(payload, '$.deletions'),0)) as avg_lines
      FROM events WHERE ${where} AND event_type='commit'
    `).get() as any;

    const hotspots = db.query(`
      SELECT value as file, COUNT(*) as touches
      FROM events, json_each(json_extract(payload, '$.files'))
      WHERE ${where} AND event_type='commit'
      GROUP BY value HAVING touches > 1
      ORDER BY touches DESC LIMIT 10
    `).all();

    const pushLatency = db.query(`
      SELECT AVG(latency) as avg_latency FROM (
        SELECT CAST((julianday(p.timestamp) - julianday(
          (SELECT MAX(c.timestamp) FROM events c
           WHERE c.repo_name = p.repo_name AND c.event_type='commit'
           AND c.timestamp < p.timestamp)
        )) * 86400 AS INTEGER) as latency
        FROM events p
        WHERE p.event_type='push' AND p.timestamp >= '${tsStart}' AND p.timestamp <= '${tsEnd}'
      ) WHERE latency IS NOT NULL AND latency > 0
    `).get() as any;

    const aiCombined = db.query(`
      SELECT COUNT(*) as c FROM events
      WHERE ${where} AND event_type='commit' AND (
        json_extract(payload, '$.ai_commit_signals.co_authored_by') != '[]'
        OR json_array_length(json_extract(payload, '$.process_context.active_ai_tools')) > 0
        OR repo_name IN (
          SELECT DISTINCT repo_name FROM events
          WHERE ${where} AND event_type='pre_commit'
          AND json_extract(payload, '$.ai_artifacts') != '{}'
        )
      )
    `).get() as any;

    const topRepo = db.query(`
      SELECT repo_name, COUNT(*) as commits
      FROM events WHERE ${where} AND event_type='commit'
      GROUP BY repo_name ORDER BY 2 DESC LIMIT 1
    `).get() as any;

    const branchStats = db.query(`
      SELECT COUNT(DISTINCT repo_name || '/' || branch) as unique_branches
      FROM events WHERE ${where}
    `).get() as any;

    db.close();

    const result = {
      period: { since: range.since, until: range.until },
      overview,
      commit_granularity: {
        avg_files_per_commit: granularity?.avg_files ? Math.round(granularity.avg_files * 10) / 10 : 0,
        avg_lines_per_commit: granularity?.avg_lines ? Math.round(granularity.avg_lines) : 0,
      },
      file_hotspots: hotspots,
      push_latency: pushLatency?.avg_latency ? {
        avg_seconds: Math.round(pushLatency.avg_latency),
        avg_human: formatDuration(Math.round(pushLatency.avg_latency)),
      } : null,
      ai_signatures: {
        commits_with_ai: aiCombined.c,
        total_commits: overview.commits,
        percentage: overview.commits > 0 ? Math.round((aiCombined.c / overview.commits) * 100) : 0,
      },
      focus: topRepo ? {
        top_repo: topRepo.repo_name,
        top_repo_commits: topRepo.commits,
        focus_percentage: overview.commits > 0 ? Math.round((topRepo.commits / overview.commits) * 100) : 0,
      } : null,
      branches: {
        unique_branches: branchStats?.unique_branches || 0,
      },
      rewrite_rate: {
        rewrites: overview.rewrites,
        commits: overview.commits,
        rate_percentage: overview.commits > 0 ? Math.round((overview.rewrites / overview.commits) * 100) : 0,
      },
    };

    return {
      content: [{ type: "text" as const, text: JSON.stringify(result, null, 2) }],
    };
  }
);

// --- Tool: engsight_diff ---
server.tool(
  "engsight_diff",
  "Compare activity between two time periods side-by-side: commits, pushes, repos, AI co-author rate, new/dropped repos.",
  {
    weekly: z.boolean().optional().describe("Compare this week vs last week (default)"),
    monthly: z.boolean().optional().describe("Compare this month vs last month"),
    period_a: z.string().optional().describe("First period as YYYY-MM-DD..YYYY-MM-DD"),
    period_b: z.string().optional().describe("Second period as YYYY-MM-DD..YYYY-MM-DD"),
  },
  async ({ weekly, monthly, period_a, period_b }) => {
    const db = getDb();

    let aStart: string, aEnd: string, bStart: string, bEnd: string;

    if (period_a && period_b) {
      [aStart, aEnd] = period_a.split("..");
      [bStart, bEnd] = period_b.split("..");
    } else if (monthly) {
      const now = new Date();
      bStart = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-01`;
      bEnd = dateAgo(0);
      const prev = new Date(now.getFullYear(), now.getMonth() - 1, 1);
      const prevEnd = new Date(now.getFullYear(), now.getMonth(), 0);
      aStart = `${prev.getFullYear()}-${String(prev.getMonth() + 1).padStart(2, "0")}-01`;
      aEnd = `${prevEnd.getFullYear()}-${String(prevEnd.getMonth() + 1).padStart(2, "0")}-${String(prevEnd.getDate()).padStart(2, "0")}`;
    } else {
      bStart = dateAgo(7);
      bEnd = dateAgo(0);
      aStart = dateAgo(14);
      aEnd = dateAgo(7);
    }

    function getPeriodStats(start: string, end: string) {
      const w = `timestamp >= '${start}T00:00:00Z' AND timestamp <= '${end}T23:59:59Z'`;
      const stats = db.query(`
        SELECT
          COUNT(*) as total,
          SUM(CASE WHEN event_type='commit' THEN 1 ELSE 0 END) as commits,
          SUM(CASE WHEN event_type='push' THEN 1 ELSE 0 END) as pushes,
          SUM(CASE WHEN event_type='checkout' THEN 1 ELSE 0 END) as checkouts,
          SUM(CASE WHEN event_type='merge' THEN 1 ELSE 0 END) as merges,
          COUNT(DISTINCT repo_name) as repos,
          COUNT(DISTINCT branch) as branches
        FROM events WHERE ${w}
      `).get() as any;

      const aiSignatures = db.query(`
        SELECT COUNT(*) as c FROM events
        WHERE ${w} AND event_type='commit' AND (
          json_extract(payload, '$.ai_commit_signals.co_authored_by') != '[]'
          OR json_array_length(json_extract(payload, '$.process_context.active_ai_tools')) > 0
          OR repo_name IN (
            SELECT DISTINCT repo_name FROM events
            WHERE ${w} AND event_type='pre_commit'
            AND json_extract(payload, '$.ai_artifacts') != '{}'
          )
        )
      `).get() as any;

      const repoList = db.query(`
        SELECT DISTINCT repo_name FROM events WHERE ${w}
      `).all().map((r: any) => r.repo_name);

      return {
        period: { start, end },
        ...stats,
        ai_signature_commits: aiSignatures.c,
        ai_signature_percentage: stats.commits > 0 ? Math.round((aiSignatures.c / stats.commits) * 100) : 0,
        repo_list: repoList,
      };
    }

    const a = getPeriodStats(aStart, aEnd);
    const b = getPeriodStats(bStart, bEnd);

    const newRepos = b.repo_list.filter((r: string) => !a.repo_list.includes(r));
    const droppedRepos = a.repo_list.filter((r: string) => !b.repo_list.includes(r));

    db.close();

    return {
      content: [{
        type: "text" as const,
        text: JSON.stringify({
          period_a: a,
          period_b: b,
          changes: {
            commits_delta: b.commits - a.commits,
            pushes_delta: b.pushes - a.pushes,
            repos_delta: b.repos - a.repos,
            new_repos: newRepos,
            dropped_repos: droppedRepos,
          },
        }, null, 2),
      }],
    };
  }
);

// --- Tool: engsight_query ---
server.tool(
  "engsight_query",
  "Run a read-only SQL query against the engsight database. The events table has columns: id, timestamp, event_type, repo_path, repo_name, branch, author, payload (JSON). Use json_extract() for payload fields.",
  {
    sql: z.string().describe("SQL query to execute (read-only)"),
  },
  async ({ sql }) => {
    const normalized = sql.trim().toUpperCase();
    if (!normalized.startsWith("SELECT") && !normalized.startsWith("WITH")) {
      return {
        content: [{ type: "text" as const, text: "Error: Only SELECT queries are allowed." }],
      };
    }

    const db = getDb();
    try {
      const rows = db.query(sql).all();
      db.close();
      return {
        content: [{ type: "text" as const, text: JSON.stringify({ rows, count: rows.length }, null, 2) }],
      };
    } catch (e: any) {
      db.close();
      return {
        content: [{ type: "text" as const, text: `SQL Error: ${e.message}` }],
      };
    }
  }
);

// --- Start ---
const transport = new StdioServerTransport();
await server.connect(transport);
