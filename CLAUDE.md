# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A distribution bundle, not an application. It packages two Claude Code skills (`/geo-audit` and `/geo-fix`) plus their supporting agents and helper script, and installs them globally into `~/.claude/` so they're available in any project. There is no build, no test suite, and no runtime in this repo itself — the artifacts execute inside Claude Code on the end user's machine after `install.sh` runs.

## Install / smoke test

```bash
# Install from this local checkout (script auto-detects local bundle vs. needing to clone)
./install.sh

# What it does:
#   1. Copies agents/*.md          → ~/.claude/agents/
#   2. Copies skills/*             → ~/.claude/skills/
#   3. Creates venv at             ~/.claude/skills/geo/.venv/  (prefers uv, falls back to python -m venv)
#   4. Installs skills/geo/requirements.txt into that venv
#   5. Rewrites shebangs in scripts/*.py to the venv interpreter (absolute path)
#   6. Substitutes __GEO_SCRIPTS__ and __GEO_VENV_PY__ placeholders in agent/skill .md files (tilde-form ~/.claude/...)

# Verify the helper script works after install:
~/.claude/skills/geo/.venv/bin/python3 ~/.claude/skills/geo/scripts/fetch_page.py https://example.com page
# Modes: page (default) | robots | llms | sitemap | blocks | full

# End-to-end: open Claude Code anywhere and run
#   /geo-audit https://example.com
# Output is written to GEO-AUDIT-REPORT.md in the user's CWD.
```

There is nothing to `npm test` or `pytest` — validate changes by re-running `install.sh` and exercising `/geo-audit` (and optionally `/geo-fix`) against a known URL or local project.

## Architecture: how `/geo-audit` actually runs

Three layers, with a deliberate split between orchestration and analysis:

1. **Orchestrator** — [skills/geo-audit/SKILL.md](skills/geo-audit/SKILL.md) is the user-callable skill. It runs Phase 1 (discovery: homepage fetch, business-type classification, sitemap crawl up to 50 pages) and Phase 3 (aggregation: weighted composite GEO Score, report generation).
2. **Five parallel subagents** — [agents/geo-ai-visibility.md](agents/geo-ai-visibility.md), [geo-platform-analysis.md](agents/geo-platform-analysis.md), [geo-technical.md](agents/geo-technical.md), [geo-content.md](agents/geo-content.md), [geo-schema.md](agents/geo-schema.md). Phase 2 spawns these in parallel; each returns a category score (0-100) + findings.
3. **Helper script** — [skills/geo/scripts/fetch_page.py](skills/geo/scripts/fetch_page.py) wraps `requests` + `BeautifulSoup` for richer HTML parsing than WebFetch provides. **Critical:** WebFetch converts HTML → markdown and drops `<head>`, which destroys JSON-LD blocks. Schema detection and any structured-data work MUST go through `fetch_page.py`, not WebFetch. The `geo-schema` and `geo-ai-visibility` agents are wired to call it; preserve that when editing.

### Composite score weighting

Defined in [skills/geo-audit/SKILL.md](skills/geo-audit/SKILL.md): Citability 25%, Brand 20%, E-E-A-T 20%, Technical 15%, Schema 10%, Platform 10%. If you change weights, change them in the SKILL.md table AND the formula line below it — they're stated twice.

## Placeholder substitution (do not break this)

Agent/skill markdown files reference the venv interpreter and scripts directory via two literal placeholder tokens:

- `__GEO_VENV_PY__` → expands to `~/.claude/skills/geo/.venv/bin/python3`
- `__GEO_SCRIPTS__` → expands to `~/.claude/skills/geo/scripts`

`install.sh` does the substitution with `sed` (see the `patch_md` function in [install.sh](install.sh)). Constraints when editing:

- Write the literal tokens in source — never the expanded paths. Source files in this repo should still contain `__GEO_VENV_PY__` / `__GEO_SCRIPTS__` after your edit.
- Use the **tilde form** (`~/.claude/...`), not `$HOME`. Claude Code's Bash expands `~` at command-execution time; this is intentional. Python shebangs are the exception — those get the absolute venv path because shebangs don't expand `~`.
- If you add a new agent or skill file that needs to invoke the helper script, use the placeholders and add the file to the `for f in ...` loop in `install.sh` step 5 if it isn't already covered by the existing globs (`agents/geo-*.md`, `skills/geo-audit/SKILL.md`).

Currently [agents/geo-ai-visibility.md](agents/geo-ai-visibility.md), [agents/geo-schema.md](agents/geo-schema.md), and [agents/geo-fix-qa.md](agents/geo-fix-qa.md) contain the placeholders — `grep -l '__GEO_SCRIPTS__\|__GEO_VENV_PY__'` to confirm.

## Relationship to upstream

`/geo-audit` started as a trimmed snapshot of [zubair-trabzada/geo-seo-claude](https://github.com/zubair-trabzada/geo-seo-claude) — upstream ships ~15 sub-skills, this bundle kept only what the audit needs end-to-end and dropped the standalone generator skills (`geo-citability`, `geo-llmstxt`, `geo-platform-optimizer`, `geo-schema`) since their scoring logic is duplicated inline in the audit agents. **However, the audit is no longer a pure snapshot.** Local additions in [skills/geo-audit/SKILL.md](skills/geo-audit/SKILL.md):

- **Phase 0 — URL Resolution + Auto-Preview Mode.** When invoked without a URL, the audit detects the framework (Next.js app/pages, Nuxt, Astro, SvelteKit, Vite+React, plain HTML), builds the project, starts a local preview server, and audits the rendered HTML. Lets users audit their local production build instead of a deployed URL.
- **Pre-build safety check.** Before running any build command, scans `package.json` scripts (transitively, depth ≤ 3) for risky verbs (`deploy`, `publish`, `upload`, `push`, `release`, `sync`, etc.) and tool patterns (`vercel deploy`, `netlify deploy`, `firebase deploy`, `npm publish`, `gh release`, etc.). Refuses unless `GEO_FIX_ALLOW_RISKY_BUILD=1` is set. Prevents accidentally deploying the user's project during an audit.

If you re-extract from upstream to pull in scoring/agent improvements, you MUST preserve Phase 0 and the safety check — a naive `cp -R` from upstream will silently delete them. Diff first, then port upstream changes section-by-section into the existing SKILL.md.

`/geo-fix` is custom to this repo — it has no upstream. The fix loop (skill + `geo-fix-triage` agent + `geo-fix-qa` agent) was built here to consume `GEO-AUDIT-REPORT.md` and apply framework-aware remediations with a render-verification QA gate. Edit it freely; no re-extraction concern.

The canonical remote that `install.sh` clones from (when run via `curl | bash`) is `https://github.com/fathanabds/geo-seo.git` — see `REPO_URL` in [install.sh](install.sh). Pushes to `main` on that repo are what end users actually pull.

## Python dependencies

[skills/geo/requirements.txt](skills/geo/requirements.txt) pins exactly the three packages [scripts/fetch_page.py](skills/geo/scripts/fetch_page.py) imports: `requests`, `beautifulsoup4`, and `lxml` (bs4's parser, named explicitly in `BeautifulSoup(text, "lxml")` calls). Upstream's requirements.txt carries 7 extra packages (playwright, Pillow, urllib3, validators, reportlab, flask, rich) used by sub-skills not shipped in this bundle — they were trimmed here to keep installs fast. Before adding any of them back, confirm an agent .md or script actually imports it.
