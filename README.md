# engsight

Personal engineering metrics, collected passively via git hooks.

engsight installs lightweight hooks across your repos that silently record commit metadata, branch switching, AI tool usage, and process context into a central SQLite database. No workflow changes. No cloud services. Just local data about how you actually work.

It's the IC complement to [engleader.tools](https://engleader.tools) — where engleader gives managers DORA metrics via GitHub's API, engsight gives you the same class of insight from local git events: shipping cadence, iteration speed, recovery time, commit granularity, and AI collaboration patterns.

## Install

```bash
# macOS (Homebrew)
brew install georgemandis/tap/engsight

# Windows (Scoop)
scoop bucket add engsight https://github.com/georgemandis/scoop-bucket
scoop install engsight

# From source
git clone https://github.com/georgemandis/engsight.git
cd engsight
./engsight setup
```

After installing, set up the database and install hooks across your repos:

```bash
engsight setup                  # Creates ~/.engsight/ (database, config, hooks)
engsight init-all ~/Projects    # Install hooks in all repos under a path
engsight init                   # Or install in just the current repo
```

New repos get hooks automatically after setup.

## What it tracks

Every git event is recorded with a JSON payload:

| Hook | What it captures |
|------|-----------------|
| **post-commit** | SHA, message, diff stats, file list, file types, AI co-author detection, AI artifact state, process context, terminal, time-of-day |
| **pre-commit** | Staged files, AI artifact shadow index (`.claude/`, `.cursor/`, `AGENTS.md`, etc.) |
| **post-checkout** | Branch switches, new branch detection |
| **post-merge** | Merge type, merged branch, files changed |
| **pre-push** | Commits bundled between pushes |
| **pre-rebase** | Pre-squash state capture |
| **post-rewrite** | Amend/rebase tracking |

### AI awareness

engsight tracks AI involvement through three tiers, each weighted by signal strength:

- **Co-authorship** (strong) — detects `Co-authored-by: Claude` and similar commit message patterns
- **Process presence** (medium) — at commit time, checks if AI tools (Claude, Cursor, Copilot, Ollama, etc.) are running, with resource stats and uptime. Opt-in via config.
- **Artifact presence** (weak) — tracks `.claude/`, `.cursor/`, `AGENTS.md`, `CLAUDE.md` and other AI tool files in the repo

The combined AI confidence score weights these tiers (1.0 / 0.8 / 0.3) rather than treating them equally — a repo that merely contains a `CLAUDE.md` file isn't the same signal as a commit made while Claude was actively running.

## Commands

```
engsight setup              Set up ~/.engsight (database, config, hooks)
engsight init               Install hooks in the current repo
engsight init-all PATH      Install hooks in all repos under PATH
engsight status             Show hook status and event count for current repo
engsight log                Recent events across all repos
engsight repos              List repos ranked by activity
engsight summary            Activity summary for a time period
engsight sessions           Reconstruct work sessions from event clusters
engsight patterns           Working patterns, DORA-shaped IC metrics
engsight diff               Compare two time periods side-by-side
engsight narrate            LLM-generated narrative of your activity
engsight enrich             Correlate with GitHub PR data
```

### log

```bash
engsight log                          # Last 20 events across all repos
engsight log --repo myproject         # Filter by repo
engsight log --type commit            # Filter by event type
engsight log --since 2025-01-15       # Events after a date
engsight log --limit 50              # Show more events
```

### summary

```bash
engsight summary --daily              # Today's activity
engsight summary --weekly             # Last 7 days (default)
engsight summary --since 2025-01-01 --until 2025-01-31  # Custom range
```

Includes: repos touched, commit/push/merge counts, weighted AI signature breakdown (confirmed / likely / possible), and time-of-day patterns.

### sessions

```bash
engsight sessions                     # Sessions from last 7 days
engsight sessions --gap 60            # 60-minute gap threshold (default: 30)
engsight sessions --repo myproject    # Filter by repo
```

Reconstructs work sessions by clustering events with time gaps. Shows duration, commits, branch switches, AI usage, and repos per session.

### patterns

```bash
engsight patterns --daily             # Today's patterns
engsight patterns --weekly            # Last 7 days (default)
engsight patterns --since 2025-01-01  # Custom start date
```

This is the big one. Surfaces DORA-shaped metrics adapted for individual contributors:

| Section | What it measures | DORA analog |
|---------|-----------------|-------------|
| **Shipping Cadence** | Commits/day, pushes/day, commits/push, active day %, shipping style | Deployment Frequency |
| **Iteration Speed** | Median/avg/min/max gap between commits in the same repo, pace assessment | Lead Time for Changes |
| **Commit-to-Push Latency** | Time between commit and push (median, avg, min, max) | Lead Time for Changes |
| **Recovery Time** | Fix/revert commit detection, time-to-fix, correction rate | Mean Time to Recovery |
| **Rewrite Frequency** | Amend/rebase rate | Change Failure Rate |
| **Commit Granularity** | Files/lines per commit (avg, median, max) | PR Size |

Also includes: context switching frequency, session depth, AI correlation (AI vs solo sessions), breadth analysis, commit streaks, file hotspots with sole-author detection, branch lifecycle, repo ownership concentration, and session shape.

### diff

```bash
engsight diff --weekly                # This week vs last week (default)
engsight diff --monthly               # This month vs last month
engsight diff --period 2025-01-01..2025-01-31 2025-02-01..2025-02-28  # Custom
```

Side-by-side comparison with deltas: commits, pushes, repos, branches, AI signature rate, and repo changes (new/dropped).

### narrate

```bash
engsight narrate --weekly             # LLM narrative of the week (default)
engsight narrate --daily              # Today
engsight narrate --format standup     # Preset: standup update
engsight narrate --format review      # Preset: performance review material
engsight narrate --prompt "Summarize as bullet points"  # Custom prompt
engsight narrate --md                 # Raw markdown, no LLM
```

Builds a structured markdown summary of your activity and pipes it to an LLM for narrative generation.

**Requirements:** narrate uses Simon Willison's [llm](https://github.com/simonw/llm) CLI. Install it and configure any model:

```bash
# Install
brew install llm          # or: pip install llm

# Then pick a backend — any of these work:
llm keys set openai       # OpenAI (GPT-4, etc.)
llm install llm-claude-3  # Anthropic Claude
llm install llm-ollama    # Ollama (local, no API key needed)
```

Whatever model you have set as your `llm` default is what narrate uses. Use `--md` to skip the LLM step entirely and get raw markdown.

### enrich

```bash
engsight enrich                       # GitHub enrichment for last 7 days
engsight enrich --daily               # Today's GitHub activity
engsight enrich --repo myproject      # Filter by repo
```

Correlates local git activity with GitHub PR data: PRs authored, reviews given, commits-per-PR ratio. Requires [`gh`](https://cli.github.com/) CLI authenticated with GitHub.

## Configuration

Edit `~/.engsight/config` to customize:

```bash
ENGSIGHT_PROCESS_SNIFF=false    # Set to "true" or "deep" to detect AI tools at commit time
ENGSIGHT_EXCLUDE_REPOS=()      # Repos to skip
ENGSIGHT_CAPTURE_TERMINAL=true  # Record terminal app
ENGSIGHT_CAPTURE_WORKDIR_STATE=true
ENGSIGHT_CAPTURE_TIME=true
```

Process sniffing tiers:

| Value | What it does | Overhead |
|-------|-------------|----------|
| `false` | Disabled (default) | — |
| `true` | Detects AI tools via `pgrep`/`ps`, reports instances + CPU + memory + uptime | ~50ms |
| `deep` | Also scans open files and network connections via `lsof` | ~200ms |

## AI cost tracking

If you use [ccusage](https://github.com/yohasebe/ccusage), engsight queries it at report time to include token usage and cost data in `patterns` and `narrate` output — total cost, token breakdown, cost per commit, and model-level detail. No configuration needed; if `ccusage` (or `bunx ccusage`) is available, it's included automatically.

## MCP Server

engsight includes an MCP server that lets Claude Code query your engineering data conversationally.

### Setup

Requires [Bun](https://bun.sh).

```bash
cd /path/to/engsight/mcp
bun install
claude mcp add engsight -s user -- bun run /path/to/engsight/mcp/index.ts
```

### Available tools

| Tool | Description |
|------|-------------|
| `engsight_log` | Recent events across all repos |
| `engsight_repos` | Repos with activity counts |
| `engsight_summary` | Activity summary with weighted AI signatures |
| `engsight_sessions` | Work session reconstruction |
| `engsight_patterns` | Working patterns and DORA-shaped metrics |
| `engsight_diff` | Compare two time periods |
| `engsight_query` | Raw SQL against the events table |

## Querying directly

The SQLite database is yours to query:

```bash
# Repos active today
sqlite3 ~/.engsight/engsight.db \
  "SELECT DISTINCT repo_name FROM events WHERE date(timestamp) = date('now');"

# Commits per repo this week
sqlite3 ~/.engsight/engsight.db \
  "SELECT repo_name, COUNT(*) FROM events
   WHERE event_type='commit' AND timestamp > datetime('now', '-7 days')
   GROUP BY repo_name ORDER BY 2 DESC;"

# Commits with AI tools running
sqlite3 ~/.engsight/engsight.db \
  "SELECT repo_name, json_extract(payload, '$.message')
   FROM events WHERE event_type='commit'
   AND json_array_length(json_extract(payload, '$.process_context.active_ai_tools')) > 0;"
```

## The git hooks footgun

Git's `core.hooksPath` lets you set global hooks, but it **silently disables all local repo hooks**. engsight handles this by:

1. Using `init.templateDir` for new repos (hooks copied on `git init`/`git clone`)
2. Detecting `core.hooksPath` during install and placing hooks there too
3. Chaining to existing hooks via `<hookname>.local` — your repo-specific hooks still run

## Design principles

- **Never block git** — hooks fail silently, never interfere with your workflow
- **Store everything, refine later** — capture all data now, discover what's useful through dogfooding
- **Local-first** — no network calls, no cloud dependency, works offline
- **Weighted signals** — not all AI indicators are equal; score them accordingly
- **Opt-in for invasive features** — process sniffing is off by default

## Roadmap

See [ROADMAP.md](ROADMAP.md) for what's next, and [docs/DESIGN.md](docs/DESIGN.md) for the full design spec including all payload schemas.

## License

MIT
