# engsight - Roadmap

## Phase 0: Foundation (Complete)

- [x] Design spec and payload definitions
- [x] `schema.sql` - database schema
- [x] `common.sh` - shared hook functions
- [x] `config.default` - default configuration
- [x] `install.sh` - setup script (with `core.hooksPath` detection)
- [x] Tier 1 hooks: `post-commit`, `post-checkout`, `post-merge`, `pre-push`
- [x] Tier 2 hooks: `post-rewrite`, `pre-commit`, `pre-rebase`
- [x] Local hook chaining (`<hookname>.local` pattern)
- [x] `engsight init` and `engsight init-all` commands
- [x] `engsight status` command
- [x] End-to-end smoke test (`test.sh`)
- [x] Dogfooding: installed across 95 Recurse Center repos

## Phase 1: Query & Explore (Complete)

- [x] Basic query scripts (`engsight log`, `engsight summary`, `engsight repos`)
- [x] Weekly/daily/custom summary generation
- [x] Simple report: "what did I work on this week?" (`engsight summary --weekly`)
- [x] Cross-repo activity timeline (`engsight log` spans all repos)
- [x] Markdown export for summaries (`engsight narrate --md`)

## Phase 2: AI Analysis (Complete)

- [x] Session reconstruction: group events into "work sessions" (`engsight sessions`)
- [x] Working patterns: context switching, commit cadence, session depth, breadth (`engsight patterns`)
- [x] AI correlation: AI-assisted vs solo session comparison
- [x] Period comparison: side-by-side diff of two time ranges (`engsight diff`)
- [x] Commit streaks and momentum tracking
- [x] File hotspots with sole-author detection
- [x] Branch lifecycle stats (lifespan, commits per branch)
- [x] Tiered process sniffing (true=fast pgrep/ps, deep=lsof)
- [x] Commit-to-push latency (IC view of lead time)
- [x] Rewrite frequency (amend/rebase rate — change failure rate analog)
- [x] Commit granularity (files/lines per commit — PR size analog)
- [x] Repo ownership concentration (specialist vs generalist)
- [x] Session shape analysis (front-loaded vs back-loaded)
- [x] AI tool presence tracking (tools running at commit time)
- [x] Pipe event data to LLM for narrative summaries (`engsight narrate`, via `llm` CLI)
- [x] Markdown export for summaries (`engsight narrate --md`)
- [x] ccusage integration — AI cost/token data queried at report time via `bunx ccusage` (`engsight narrate`, `engsight patterns`)

## Phase 3: MCP Server (Complete)

- [x] MCP server that reads from `engsight.db` (`mcp/index.ts`, Bun + @modelcontextprotocol/sdk)
- [x] Natural language queries about work patterns (7 tools: log, repos, summary, sessions, patterns, diff, query)
- [x] Integration with Claude Code for self-aware development assistance
- [x] Comparative analysis (`engsight_diff` tool — weekly, monthly, custom periods)

## Phase 4: Enrichment & Collaboration

- [x] GitHub enrichment via `gh` CLI (`engsight enrich` — PRs authored, reviews given, commits/PR ratio)
- [x] Export formats: `engsight narrate --format standup` and `--format review`
- [x] engleader.tools bridge: enrichment correlates local git data with same PR/review signals
- [ ] Multi-machine sync (if relevant — let dogfooding determine need)

## Blog Posts

- [ ] **Post 1** (standalone): The git hooks footgun - `core.hooksPath` vs template directories
- [ ] **Post 2** (after dogfooding): Introducing engsight - passive engineering self-awareness

## Open Questions

- What queries will actually be useful? (Let dogfooding answer this)
- Should `lsof` output be stored raw or parsed? (Try raw first)
- How noisy is `post-index-change` in practice? (Experiment in Phase 1)
- Does `post-checkout` fire reliably in worktree creation? (Test empirically)
