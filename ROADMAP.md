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

## Phase 1: Query & Explore

- [x] Basic query scripts (`engsight log`, `engsight summary`, `engsight repos`)
- [x] Weekly/daily/custom summary generation
- [x] Simple report: "what did I work on this week?" (`engsight summary --weekly`)
- [ ] Cross-repo activity timeline
- [ ] Markdown export for summaries

## Phase 2: AI Analysis

- [x] Session reconstruction: group events into "work sessions" (`engsight sessions`)
- [x] Working patterns: context switching, commit cadence, session depth, breadth (`engsight patterns`)
- [x] AI correlation: AI-assisted vs solo session comparison
- [x] Period comparison: side-by-side diff of two time ranges (`engsight diff`)
- [x] Commit streaks and momentum tracking
- [x] File hotspots with sole-author detection
- [x] Branch lifecycle stats (lifespan, commits per branch)
- [x] Tiered process sniffing (true=fast pgrep/ps, deep=lsof)
- [ ] Pipe event data to LLM for narrative summaries
- [ ] Process sniffing refinement based on dogfooding experience
- [ ] Explore ccusage (https://github.com/ryoppippi/ccusage) integration — reads local AI tool session logs for token counts, costs, model usage. Could correlate AI spend with git activity.

## Phase 3: MCP Server

- [ ] MCP server that reads from `engsight.db`
- [ ] Natural language queries about work patterns ("what did I do last Tuesday?")
- [ ] Integration with Claude Code for self-aware development assistance
- [ ] Comparative analysis ("how does this week compare to last?")

## Phase 4: Enrichment & Collaboration

- [ ] Optional GitHub/GitLab enrichment layer (PR data, reviews, CI status)
- [ ] Export formats for sharing (standup summaries, performance review material)
- [ ] Potential integration points with engleader.tools
- [ ] Multi-machine sync (if relevant)

## Blog Posts

- [ ] **Post 1** (standalone): The git hooks footgun - `core.hooksPath` vs template directories
- [ ] **Post 2** (after dogfooding): Introducing engsight - passive engineering self-awareness

## Open Questions

- What queries will actually be useful? (Let dogfooding answer this)
- Should `lsof` output be stored raw or parsed? (Try raw first)
- How noisy is `post-index-change` in practice? (Experiment in Phase 1)
- Does `post-checkout` fire reliably in worktree creation? (Test empirically)
