# engsight - Design Spec

## Overview

A collection of bash git hook scripts that passively collect engineering activity metadata across all your repos into a central SQLite database at `~/.engsight/engsight.db`. Designed for individual contributors who want to understand their own working patterns, communicate their work effectively, and optionally track AI tool usage as a first-class signal.

## Motivation

Git's `core.hooksPath` setting lets you configure global hooks, but it silently disables all local repo hooks unless you explicitly work around it. Git template directories (`~/.git-templates/hooks`) are a better mechanism for default hooks on new repos, but they still can't layer global behavior on top of local hooks.

engsight solves this by:
1. Using template directories so new repos get hooks automatically
2. Having each hook chain to a `<hookname>.local` script if present, preserving repo-specific hooks
3. Collecting cross-repo metadata into a central database for personal insight

## Architecture

### Directory Structure

```
# The project source
engsight/
├── README.md
├── install.sh              # Setup script
├── common.sh               # Shared functions sourced by all hooks
├── config.default          # Default config, copied to ~/.engsight/config
├── schema.sql              # Database schema
└── hooks/
    ├── post-commit
    ├── post-checkout
    ├── post-merge
    ├── pre-push
    ├── post-rewrite
    ├── pre-commit
    └── pre-rebase

# What gets created on the user's machine
~/.engsight/
├── config                  # User's config (copied from config.default)
├── engsight.db             # Central SQLite database
└── templates/
    └── hooks/              # Symlinks or copies of the hook scripts
```

### Database Schema

```sql
CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL,          -- ISO 8601
  event_type TEXT NOT NULL,         -- commit, checkout, merge, push, rewrite, pre_rebase, pre_commit
  repo_path TEXT NOT NULL,          -- /Users/george/Projects/engsight
  repo_name TEXT,                   -- engsight
  branch TEXT,
  author TEXT,
  payload JSON
);

CREATE INDEX idx_events_timestamp ON events(timestamp);
CREATE INDEX idx_events_event_type ON events(event_type);
CREATE INDEX idx_events_repo_name ON events(repo_name);
```

Single `events` table with a JSON `payload` column. Each hook writes a different event_type with hook-specific structured data in the payload. This is append-only, trivially extensible (new hook = new event_type, no migration), and SQLite's JSON support handles querying into the payload.

## Hook Inventory

### Tier 1 - Core (instrument now)

| Hook | Purpose | Key signal |
|------|---------|------------|
| **post-commit** | Core data collection | Commit metadata, diff stats, files, AI signals |
| **post-checkout** | Context switching | Branch switches, new branch creation |
| **post-merge** | Integration events | Merge type, files changed, branch merged |
| **pre-push** | Session boundaries | Commits bundled between pushes |

### Tier 2 - Valuable (instrument early)

| Hook | Purpose | Key signal |
|------|---------|------------|
| **post-rewrite** | Revision habits | Amend/rebase frequency, commit rewriting |
| **pre-commit** | AI artifact shadow indexing | State of AI tool files outside git |
| **pre-rebase** | Pre-squash state capture | Preserves granularity before history rewrite |

### Tier 3 - Maybe later

| Hook | Purpose | Notes |
|------|---------|-------|
| **commit-msg** | Message classification | post-commit can do this too |
| **post-index-change** | Staging habits | Potentially very noisy |

## Hook Payloads

### post-commit
```json
{
  "sha": "abc123",
  "message": "fix: resolve edge case in parser",
  "message_length": 38,
  "files_changed": 3,
  "insertions": 42,
  "deletions": 17,
  "files": ["src/parser.ts", "src/parser.test.ts", "README.md"],
  "file_types": {".ts": 2, ".md": 1},
  "is_merge": false,
  "is_amend": false,
  "diff_size_bytes": 1847,
  "time_since_last_commit_repo_seconds": 1823,
  "time_since_last_commit_global_seconds": 45,
  "ai_commit_signals": {
    "co_authored_by": ["Claude"],
    "pattern_matches": ["Co-authored-by:.*Claude"]
  },
  "ai_artifacts": {
    ".claude": {"exists": true, "file_count": 3, "total_size_bytes": 12400},
    "CLAUDE.md": {"exists": true, "file_count": 1, "total_size_bytes": 890}
  },
  "terminal": "iTerm2",
  "workdir_state": {
    "untracked_count": 4,
    "stash_depth": 1
  },
  "time_context": {
    "hour": 14,
    "day_of_week": "Tuesday",
    "is_weekend": false
  },
  "process_context": {
    "active_ai_tools": [
      {
        "name": "claude",
        "pid": 12345,
        "uptime_seconds": 3420,
        "cpu_percent": "2.1",
        "memory_mb": 145,
        "open_files_in_repo": ["src/parser.ts", ".claude/settings.json"],
        "open_ports": ["api.anthropic.com:443"]
      }
    ]
  }
}
```

### pre-commit
```json
{
  "staged_files": ["src/index.ts", "src/utils.ts"],
  "ai_artifacts": {
    ".claude": {"exists": true, "file_count": 3, "total_size_bytes": 12400, "files_modified_since_last_commit": 1},
    ".cursor": {"exists": false},
    "AGENTS.md": {"exists": true, "file_count": 1, "total_size_bytes": 450}
  }
}
```

### post-checkout
```json
{
  "previous_ref": "abc123",
  "new_ref": "def456",
  "previous_branch": "main",
  "new_branch": "feature/parser-rewrite",
  "is_branch_switch": true,
  "is_file_checkout": false,
  "is_new_branch": true,
  "terminal": "VS Code",
  "time_context": {
    "hour": 10,
    "day_of_week": "Monday",
    "is_weekend": false
  }
}
```

### post-merge
```json
{
  "is_fast_forward": false,
  "merged_branch": "feature/parser-rewrite",
  "commits_merged": 7,
  "files_changed": 12,
  "insertions": 340,
  "deletions": 89,
  "terminal": "iTerm2",
  "time_context": {
    "hour": 16,
    "day_of_week": "Wednesday",
    "is_weekend": false
  }
}
```

### pre-push
```json
{
  "remote": "origin",
  "remote_url": "git@github.com:georgemandis/engsight.git",
  "commits_being_pushed": 5,
  "branches": ["feature/parser-rewrite"],
  "time_since_last_push_seconds": 7200,
  "terminal": "iTerm2",
  "time_context": {
    "hour": 17,
    "day_of_week": "Wednesday",
    "is_weekend": false
  }
}
```

### pre-rebase
```json
{
  "upstream": "main",
  "branch": "feature/parser-rewrite",
  "commits_to_rebase": 8,
  "commit_shas": ["abc123", "def456", "ghi789"],
  "terminal": "iTerm2"
}
```

### post-rewrite
```json
{
  "cause": "amend",
  "rewritten_commits": [
    {"old_sha": "abc123", "new_sha": "xyz789"}
  ],
  "count": 1
}
```

## Contextual Data (Captured Across Hooks)

### Terminal Context
Captured via `$TERM_PROGRAM`. Tells you which environment the commit came from: VS Code, iTerm, Ghostty, Cursor's integrated terminal, etc.

### Working Directory State
Number of untracked files (`git ls-files --others --exclude-standard | wc -l`) and stash depth (`git stash list | wc -l`). A commit made with 40 untracked files and 5 stashes is a different signal than a clean working tree.

### Time Context
Explicit tagging of hour, day of week, and weekend flag. Already derivable from timestamp, but tagged explicitly for easier querying and analysis.

### Process Sniffing (Opt-in)
When `ENGSIGHT_PROCESS_SNIFF=true`, at commit time the hook checks for running AI tool processes:
- `pgrep` to find matching process names
- `ps -p <pid>` for uptime, CPU, memory
- `lsof -p <pid>` filtered to repo path for open files and network connections

This produces a rich snapshot: "At 2:34pm, George committed 3 files to engsight. Claude had been running for 57 minutes with 2 of those 3 files open."

**Default: disabled.** Must be explicitly opted in via config.

## Hook Execution Pattern

Every hook follows this sequence:

1. `source ~/.engsight/common.sh`
2. `engsight_check_excluded` - exit 0 if this repo is excluded
3. Gather hook-specific data via git commands
4. If `ENGSIGHT_PROCESS_SNIFF=true` - capture process context
5. If `ENGSIGHT_CAPTURE_TERMINAL=true` - capture `$TERM_PROGRAM`
6. If `ENGSIGHT_CAPTURE_WORKDIR_STATE=true` - capture untracked/stash
7. If `ENGSIGHT_TAG_TIME_CONTEXT=true` - tag hour/day/weekend
8. `engsight_log <event_type> <payload_json>` - INSERT INTO events
9. Chain to `<hookname>.local` if it exists

**Error policy:** Any failure in steps 1-8 is swallowed silently. Step 9 (local hook chaining) preserves exit codes. engsight never blocks your git workflow.

## common.sh Functions

| Function | Purpose |
|----------|---------|
| `engsight_load_config` | Sources `~/.engsight/config` |
| `engsight_check_excluded` | Checks repo against exclude list |
| `engsight_log` | Inserts event into SQLite |
| `engsight_time_since_last` | Queries DB for time delta (repo-scoped or global) |
| `engsight_scan_ai_artifacts` | Walks configured artifact paths, returns JSON |
| `engsight_scan_ai_commit_signals` | Matches commit message against AI patterns |
| `engsight_process_snapshot` | Runs pgrep/ps/lsof for configured process names |
| `engsight_terminal_context` | Captures `$TERM_PROGRAM` |
| `engsight_workdir_state` | Untracked file count + stash depth |
| `engsight_time_context` | Hour, day of week, is_weekend |
| `engsight_chain_local` | Runs `<hookname>.local` if executable |

## Config File (`~/.engsight/config`)

```bash
ENGSIGHT_DB="$HOME/.engsight/engsight.db"
ENGSIGHT_EXCLUDE_REPOS=""

ENGSIGHT_AI_ARTIFACTS=(
  .claude .cursor .cursorules .continue .continuerc.json
  .cline .clinerules .aider* .aider.conf.yml .windsurfrules
  .github/copilot-instructions.md
  CLAUDE.md AGENTS.md CODEX.md CRUSH.md
  docs/superpowers/specs
)

ENGSIGHT_AI_COMMIT_PATTERNS=(
  "Co-authored-by:.*Claude"
  "Co-authored-by:.*Copilot"
  "Co-authored-by:.*Cursor"
  "Generated by"
)

ENGSIGHT_PROCESS_SNIFF=false
ENGSIGHT_PROCESS_NAMES=(
  claude aider cursor copilot continue cline windsurf ollama
)

ENGSIGHT_CAPTURE_TERMINAL=true
ENGSIGHT_CAPTURE_WORKDIR_STATE=true
ENGSIGHT_TAG_TIME_CONTEXT=true
```

Bash-sourceable. Arrays work natively. No parsing library needed.

## Installation

```bash
./install.sh
# Creates ~/.engsight/ structure
# Copies hooks to ~/.engsight/templates/hooks/
# Initializes SQLite database
# Sets git config --global init.templateDir ~/.engsight/templates
# New repos get hooks automatically after this

# For existing repos:
engsight init
# Symlinks hooks, renames existing hooks to <hookname>.local
```

## Relationship to engleader.tools

engsight is the IC complement to engleader.tools:
- **engleader.tools** = manager looking at team output via GitHub API (PRs, reviews, deploys)
- **engsight** = IC looking at their own work via local git hooks (commits, patterns, process)

Same family, different audience, different data source. A good engineering leader might recommend engsight to their ICs. Long-term, they could share data or interface with each other, but they are independent tools.

## Design Principles

- **Never block git** - hooks fail silently, never interfere with workflow
- **Store everything, refine later** - capture all data now, figure out what's useful through dogfooding
- **Local-first** - no network calls, no platform dependency, works offline
- **Configurable, sensible defaults** - ship with known AI artifacts list, let users extend
- **Opt-in for invasive features** - process sniffing is off by default
