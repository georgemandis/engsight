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
git clone https://github.com/georgemandis/engsight.git
cd engsight
./install.sh
```

This creates `~/.engsight/`, initializes the database, and configures `init.templateDir`. New repos get hooks automatically after install.

For existing repos:

```bash
# Single repo
~/.engsight/engsight init

# All repos under a path
~/.engsight/engsight init-all ~/Projects
```

## Commands

```bash
engsight init          # Install hooks in the current repo
engsight init-all PATH # Install hooks in all git repos under PATH
engsight status        # Show hook status and event count for current repo
```

## Configuration

Edit `~/.engsight/config` to customize:

- **AI artifacts to scan** — add paths for new AI tools as they appear
- **Commit message patterns** — detect AI co-authorship signals
- **Process sniffing** — disabled by default, enable with `ENGSIGHT_PROCESS_SNIFF=true`
- **Excluded repos** — skip repos you don't want to track
- **Terminal/workdir/time capture** — all enabled by default

## Querying the data

Currently: direct SQLite queries. Some examples:

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
