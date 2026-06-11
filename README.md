# engsight

Personal engineering metrics, collected passively via git hooks.

engsight installs lightweight hooks across your repos that silently record commit metadata, branch switching patterns, AI tool usage, and other signals into a central SQLite database. It's designed for individual contributors who want to understand their own working patterns and communicate their work more effectively.

Think of it as the IC complement to [engleader.tools](https://engleader.tools) — where engleader gives managers DORA metrics via GitHub's API, engsight gives you insight into your own process via local git events.

## What it tracks

Every git event is recorded with a JSON payload tailored to that event type:

| Hook | What it captures |
|------|-----------------|
| **post-commit** | SHA, message, diff stats, file list, file types, AI co-author detection, AI artifact state, terminal context, working directory state, time-of-day |
| **pre-commit** | Staged files, AI artifact shadow index (`.claude/`, `.cursor/`, `AGENTS.md`, etc.) |
| **post-checkout** | Branch switches, new branch detection, context-switching patterns |
| **post-merge** | Merge type, merged branch, files changed |
| **pre-push** | Session boundaries — commits bundled between pushes |
| **pre-rebase** | Pre-squash state capture (preserves commit granularity before history rewrite) |
| **post-rewrite** | Amend/rebase tracking |

All events include timestamps and repo identification, enabling cross-repo analysis.

### AI awareness

engsight treats AI tool usage as a first-class signal:

- **Commit message scanning** — detects `Co-authored-by: Claude` and similar patterns
- **Artifact shadow indexing** — tracks the state of `.claude/`, `.cursor/`, `AGENTS.md`, `CLAUDE.md`, and other AI tool files that live outside git history
- **Process sniffing** (opt-in) — at commit time, checks if AI tools are running, how long they've been active, what files they have open, and what network connections they hold

## How it works

```
~/.engsight/
├── config          # Settings (AI artifacts to scan, process sniffing toggle, etc.)
├── engsight.db     # Central SQLite database — all events across all repos
├── common.sh       # Shared functions sourced by every hook
└── templates/
    └── hooks/      # Hook scripts, copied to new repos via init.templateDir
```

All data lives in a single `events` table with a JSON `payload` column:

```sql
SELECT event_type, repo_name, branch,
       json_extract(payload, '$.files_changed') as files,
       json_extract(payload, '$.terminal') as terminal
FROM events
ORDER BY timestamp DESC
LIMIT 10;
```

### The git hooks footgun

Git's `core.hooksPath` setting lets you set global hooks, but it **silently disables all local repo hooks**. engsight handles this by:

1. Using `init.templateDir` for new repos (hooks are copied on `git init`/`git clone`)
2. Detecting `core.hooksPath` during install and placing hooks there too
3. Chaining to existing hooks via `<hookname>.local` — your repo-specific hooks still run

## Install

```bash
# Homebrew
brew install georgemandis/tap/engsight

# From source
git clone https://github.com/georgemandis/engsight.git
cd engsight
./engsight setup
```

Then set up `~/.engsight/` (database, config, hooks) and install hooks in your repos:

```bash
engsight setup
engsight init-all ~/Projects
```

New repos get hooks automatically after setup.

## Commands

```bash
engsight setup         # Set up ~/.engsight (database, config, hooks)
engsight init          # Install hooks in the current repo
engsight init-all PATH # Install hooks in all git repos under PATH
engsight status        # Show hook status and event count for current repo
engsight log           # Show recent events across all repos
engsight repos         # List repos with activity counts
engsight summary       # Summarize activity for a time period
engsight enrich        # Correlate local activity with GitHub PRs (requires gh)
```

### log

```bash
engsight log                          # Last 20 events across all repos
engsight log --repo myproject         # Filter by repo
engsight log --type commit            # Filter by event type
engsight log --since 2025-01-15       # Events after a date
engsight log --limit 50               # Show more events
```

### repos

```bash
engsight repos                        # All repos, sorted by event count
engsight repos --since 2025-01-01     # Repos active since a date
```

### summary

```bash
engsight summary --daily              # Today's activity
engsight summary --weekly             # Last 7 days (default)
engsight summary --since 2025-01-01   # Custom start date
engsight summary --since 2025-01-01 --until 2025-01-31  # Custom range
```

The summary includes: repos touched, commit/push/merge/checkout counts, AI co-authorship breakdown by tool and pattern, AI artifact presence, and time-of-day/weekday patterns.

### sessions

```bash
engsight sessions                     # Sessions from last 7 days
engsight sessions --since 2025-01-01  # Sessions after a date
engsight sessions --gap 60            # Use 60-minute gap threshold (default: 30)
engsight sessions --repo myproject    # Filter by repo
```

Reconstructs work sessions by clustering events with gaps shorter than the threshold. Shows duration, commit count, branch switches, AI usage, and repos involved.

### patterns

```bash
engsight patterns --daily             # Today's patterns
engsight patterns --weekly            # Last 7 days (default)
engsight patterns --since 2025-01-01  # Custom start date
```

Surfaces working patterns: context switching frequency, commit cadence (median/average gap between commits), session depth (deep work vs. shallow), AI-assisted vs. solo session comparison, breadth of work (focus ratio, file type diversity, daily repo spread), commit streaks, file hotspots (with sole-author detection), and branch lifecycle stats.

### diff

```bash
engsight diff --weekly                # This week vs last week (default)
engsight diff --monthly               # This month vs last month
engsight diff --period 2025-01-01..2025-01-31 2025-02-01..2025-02-28  # Custom
```

Side-by-side comparison of two time periods: commits, pushes, repos, branches, AI co-author rate, and repo changes (new/dropped).

### narrate

```bash
engsight narrate --daily              # LLM narrative of today
engsight narrate --weekly             # LLM narrative of the week (default)
engsight narrate --weekly --md        # Output raw markdown (no LLM needed)
engsight narrate --daily --prompt "Write this as a standup update"
engsight narrate --weekly --format standup   # Preset: standup update
engsight narrate --weekly --format review    # Preset: performance review material
```

Generates a structured markdown summary of your activity and pipes it to [llm](https://github.com/simonw/llm) for narrative generation. Use `--md` to get the raw markdown without the LLM step. Requires `llm` CLI unless using `--md`.

### enrich

```bash
engsight enrich                       # GitHub enrichment for last 7 days
engsight enrich --daily               # Today's GitHub activity
engsight enrich --repo myproject      # Filter by repo
```

Correlates local git activity with GitHub PR data: PRs authored, reviews given, commits-per-PR ratio. Requires `gh` CLI authenticated with GitHub.

## Configuration

Edit `~/.engsight/config` to customize:

- **AI artifacts to scan** — add paths for new AI tools as they appear
- **Commit message patterns** — detect AI co-authorship signals
- **Process sniffing** — disabled by default, enable with `ENGSIGHT_PROCESS_SNIFF=true`
- **Excluded repos** — skip repos you don't want to track
- **Terminal/workdir/time capture** — all enabled by default

## MCP Server

engsight includes an MCP (Model Context Protocol) server that lets Claude Code query your engineering data directly. This enables natural language queries like "what did I work on last Tuesday?" or "how does this week compare to last?".

### Setup

Requires [Bun](https://bun.sh).

```bash
cd mcp
bun install
```

Add to Claude Code with the CLI:

```bash
claude mcp add engsight -s user -- bun run /path/to/engsight/mcp/index.ts
```

The `-s user` flag makes it available globally across all projects. Use `-s project` instead to scope it to a single repo.

### Available tools

| Tool | Description |
|------|-------------|
| `engsight_log` | Recent events across all repos |
| `engsight_repos` | Repos with activity counts |
| `engsight_summary` | Activity summary for a time period |
| `engsight_sessions` | Work session reconstruction |
| `engsight_patterns` | Working patterns and insights |
| `engsight_diff` | Compare two time periods |
| `engsight_query` | Raw SQL escape hatch |

## Querying the data

You can also query the SQLite database directly:

```bash
# What repos have I been active in today?
sqlite3 ~/.engsight/engsight.db \
  "SELECT DISTINCT repo_name FROM events WHERE date(timestamp) = date('now');"

# How many commits per repo this week?
sqlite3 ~/.engsight/engsight.db \
  "SELECT repo_name, COUNT(*) FROM events
   WHERE event_type='commit' AND timestamp > datetime('now', '-7 days')
   GROUP BY repo_name ORDER BY 2 DESC;"

# Which commits had AI co-authors?
sqlite3 ~/.engsight/engsight.db \
  "SELECT repo_name, json_extract(payload, '$.message'), json_extract(payload, '$.ai_commit_signals.co_authored_by')
   FROM events WHERE event_type='commit'
   AND json_extract(payload, '$.ai_commit_signals.co_authored_by') != '[]';"

# Context switching: how many branch switches today?
sqlite3 ~/.engsight/engsight.db \
  "SELECT repo_name, json_extract(payload, '$.previous_branch'), json_extract(payload, '$.new_branch')
   FROM events WHERE event_type='checkout' AND date(timestamp) = date('now');"
```

## Design principles

- **Never block git** — hooks fail silently, never interfere with your workflow
- **Store everything, refine later** — capture all data now, discover what's useful through dogfooding
- **Local-first** — no network calls, no platform dependency, works offline
- **Configurable defaults** — ships with sensible AI artifact list, fully customizable
- **Opt-in for invasive features** — process sniffing is off by default

## Roadmap

See [ROADMAP.md](ROADMAP.md) for what's next: query CLI, MCP server, AI-powered summaries, GitHub enrichment, and more.

See [docs/DESIGN.md](docs/DESIGN.md) for the full design spec including all payload schemas.
